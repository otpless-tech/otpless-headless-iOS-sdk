//
//  AppAttestTests.swift
//  OtplessBMTests
//
//  Covers the config-gated App Attest registration (ENG-519). Hermetic: Apple's service,
//  the backend, storage, telemetry and the clock are all fakes, so this runs on a simulator
//  (where DCAppAttestService is never supported) with no network.
//

import CryptoKit
import DeviceCheck
import XCTest
@testable import OtplessBM

// MARK: - Fakes

/// `NSLock.withLock` is iOS 16+, and this package supports iOS 13.
private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private final class FakePlatform: AppAttestPlatform, @unchecked Sendable {
    private let lock = NSLock()
    private var _supported = true
    private var _generated = 0
    private var _attested: [(keyId: String, hash: Data)] = []
    private var _generateError: Error?
    private var _attestError: Error?
    private var _suspendInGenerate = false
    private var _assertionCalls: [(keyId: String, hash: Data)] = []
    private var _assertionError: Error?
    private var _assertionDelayNs: UInt64 = 0
    private var _assertionOutput = Data("assertion-bytes".utf8)

    var assertionCalls: [(keyId: String, hash: Data)] { lock.locked { _assertionCalls } }
    func configureAssertion(error: Error? = nil, delaySeconds: Double = 0, output: Data? = nil) {
        lock.locked {
            _assertionError = error
            _assertionDelayNs = UInt64(delaySeconds * 1_000_000_000)
            if let output { _assertionOutput = output }
        }
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        let (err, delay, out): (Error?, UInt64, Data) = lock.locked {
            _assertionCalls.append((keyId, clientDataHash))
            return (_assertionError, _assertionDelayNs, _assertionOutput)
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if let err { throw err }
        return out
    }

    var isSupported: Bool { lock.locked { _supported } }
    var generateCalls: Int { lock.locked { _generated } }
    var attestCalls: [(keyId: String, hash: Data)] { lock.locked { _attested } }

    func configure(supported: Bool? = nil, generateError: Error? = nil,
                   attestError: Error? = nil, suspendInGenerate: Bool? = nil) {
        lock.locked {
            if let supported { _supported = supported }
            _generateError = generateError
            _attestError = attestError
            if let suspendInGenerate { _suspendInGenerate = suspendInGenerate }
        }
    }

    func generateKey() async throws -> String {
        let (n, err, suspend): (Int, Error?, Bool) = lock.locked {
            _generated += 1
            return (_generated, _generateError, _suspendInGenerate)
        }
        if suspend { await Task.yield(); await Task.yield() }
        if let err { throw err }
        return "key-\(n)"
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        let err: Error? = lock.locked {
            _attested.append((keyId, clientDataHash))
            return _attestError
        }
        if let err { throw err }
        return Data("attestation-for-\(keyId)".utf8)
    }
}

private final class FakeBackend: AppAttestBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: AppAttestRegistration = .accepted
    private var _calls: [(state: String, keyId: String, object: Data)] = []

    var calls: [(state: String, keyId: String, object: Data)] { lock.locked { _calls } }
    func set(_ result: AppAttestRegistration) { lock.locked { _result = result } }

    func register(state: String, keyId: String, attestationObject: Data) async -> AppAttestRegistration {
        lock.locked {
            _calls.append((state, keyId, attestationObject))
            return _result
        }
    }
}

private final class FakeStore: AppAttestStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _keys: [String: String] = [:]
    private var _marker = false

    /// Seeds `keyId` under the current scope, which is what a use case built with the default
    /// scope reads, so tests that do not care about scoping stay unchanged.
    init(keyId: String? = nil, marker: Bool = false) {
        if let keyId { _keys[AppAttestScope.current()] = keyId }
        _marker = marker
    }

    func keyId(scope: String) -> String? { lock.locked { _keys[scope] } }
    func saveKeyId(_ keyId: String, scope: String) { lock.locked { _keys[scope] = keyId } }
    func clearKeyId(scope: String) { lock.locked { _keys[scope] = nil } }
    var hasInstallMarker: Bool { lock.locked { _marker } }
    func setInstallMarker() { lock.locked { _marker = true } }

    /// The key under the current scope.
    func keyId() -> String? { keyId(scope: AppAttestScope.current()) }
}

/// A scope the test can change between calls, like a host app switching merchant app.
private final class ScopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String
    init(_ value: String) { _value = value }
    var value: String {
        get { lock.locked { _value } }
        set { lock.locked { _value = newValue } }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.locked { current } }
    func advance(_ seconds: TimeInterval) { lock.locked { current = current.addingTimeInterval(seconds) } }
}

private final class TelemetryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.locked { _events } }
    func add(_ e: String) { lock.locked { _events.append(e) } }
    var telemetry: AppAttestTelemetry {
        AppAttestTelemetry(
            success: { [self] in add("success") },
            failure: { [self] in add("failure:\($0)") },
            skipped: { [self] in add("skipped:\($0)") },
            assertionFailure: { [self] in add("assertionFailure:\($0)") },
            assertionSkipped: { [self] in add("assertionSkipped:\($0)") }
        )
    }
}

private struct BoomError: Error {}

// MARK: - Tests

@available(iOS 14.0, *)
final class AppAttestTests: XCTestCase {

    private var platform: FakePlatform!
    private var backend: FakeBackend!
    private var store: FakeStore!
    private var clock: Clock!
    private var log: TelemetryLog!

    override func setUp() {
        super.setUp()
        platform = FakePlatform()
        backend = FakeBackend()
        store = FakeStore()
        clock = Clock()
        log = TelemetryLog()
    }

    private func makeUseCase() -> AppAttestUseCase {
        AppAttestUseCase(
            platform: platform,
            backend: backend,
            store: store,
            telemetry: log.telemetry,
            now: { [clock] in clock!.now() }
        )
    }

    // MARK: Success path

    func testSuccessPersistsKeyAndMarkerAndReportsSuccess() async {
        let outcome = await makeUseCase().attestIfNeeded(state: "state-1")

        XCTAssertEqual(outcome, .attested)
        XCTAssertEqual(store.keyId(), "key-1")
        XCTAssertTrue(store.hasInstallMarker)
        XCTAssertEqual(log.events, ["success"])
    }

    /// The server checks nonce == SHA256(authData || SHA256(state)), so the hash handed to
    /// Apple must be exactly SHA256(utf8(state)). This is the contract with ENG-516.
    func testClientDataHashIsSha256OfStateBytes() async {
        _ = await makeUseCase().attestIfNeeded(state: "the-transaction-state")

        let expected = Data(SHA256.hash(data: Data("the-transaction-state".utf8)))
        XCTAssertEqual(platform.attestCalls.count, 1)
        XCTAssertEqual(platform.attestCalls.first?.hash, expected)
    }

    func testBackendReceivesStateKeyIdAndTheAttestationObject() async {
        _ = await makeUseCase().attestIfNeeded(state: "state-xyz")

        XCTAssertEqual(backend.calls.count, 1)
        XCTAssertEqual(backend.calls.first?.state, "state-xyz")
        XCTAssertEqual(backend.calls.first?.keyId, "key-1")
        XCTAssertEqual(backend.calls.first?.object, Data("attestation-for-key-1".utf8))
    }

    func testOnceAttestedLaterCallsDoNothing() async {
        let useCase = makeUseCase()
        _ = await useCase.attestIfNeeded(state: "s1")
        let second = await useCase.attestIfNeeded(state: "s2")

        XCTAssertEqual(second, .alreadyAttested)
        XCTAssertEqual(platform.generateCalls, 1, "must not mint a second key")
        XCTAssertEqual(backend.calls.count, 1, "must not re-register")
        XCTAssertEqual(log.events, ["success"], "the steady state must not spam telemetry")
    }

    // MARK: Persist only on SUCCESS

    func testRejectedByBackendPersistsNothing() async {
        backend.set(.rejected(reason: "status_failed"))

        let outcome = await makeUseCase().attestIfNeeded(state: "s")

        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(store.keyId(), "a key the backend did not accept must never be kept")
        XCTAssertFalse(store.hasInstallMarker)
        XCTAssertEqual(log.events, ["failure:status_failed"])
    }

    func testTransientBackendFailurePersistsNothing() async {
        backend.set(.failed(reason: "network"))

        let outcome = await makeUseCase().attestIfNeeded(state: "s")

        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(store.keyId())
        XCTAssertEqual(log.events, ["failure:network"])
    }

    func testGenerateKeyFailureSkipsAttestAndBackend() async {
        platform.configure(generateError: BoomError())

        let outcome = await makeUseCase().attestIfNeeded(state: "s")

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(platform.attestCalls.isEmpty)
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertNil(store.keyId())
    }

    func testAttestKeyFailureSkipsBackend() async {
        platform.configure(attestError: BoomError())

        let outcome = await makeUseCase().attestIfNeeded(state: "s")

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertNil(store.keyId())
        XCTAssertEqual(log.events, ["failure:error"])
    }

    // MARK: Unsupported

    func testUnsupportedDeviceSkipsEverything() async {
        platform.configure(supported: false)

        let outcome = await makeUseCase().attestIfNeeded(state: "s")

        XCTAssertEqual(outcome, .unsupported)
        XCTAssertEqual(platform.generateCalls, 0)
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertEqual(log.events, ["skipped:unsupported"])
    }

    // MARK: Backoff

    func testBackoffBlocksImmediateRetryThenAllowsItAfterTheWindow() async {
        backend.set(.failed(reason: "network"))
        let useCase = makeUseCase()

        _ = await useCase.attestIfNeeded(state: "s")
        XCTAssertEqual(platform.generateCalls, 1)

        let blocked = await useCase.attestIfNeeded(state: "s")
        XCTAssertEqual(blocked, .backingOff)
        XCTAssertEqual(platform.generateCalls, 1, "no Apple round trip while backing off")

        clock.advance(AppAttestUseCase.baseBackoff + 1)
        backend.set(.accepted)
        let retried = await useCase.attestIfNeeded(state: "s")
        XCTAssertEqual(retried, .attested)
        XCTAssertEqual(platform.generateCalls, 2)
    }

    func testBackoffDoublesPerConsecutiveFailureAndIsCapped() async {
        backend.set(.failed(reason: "network"))
        let useCase = makeUseCase()
        let base = AppAttestUseCase.baseBackoff

        _ = await useCase.attestIfNeeded(state: "s")                 // fail 1 -> wait base
        clock.advance(base - 1)
        let still1 = await useCase.attestIfNeeded(state: "s")
        XCTAssertEqual(still1, .backingOff)
        clock.advance(2)
        _ = await useCase.attestIfNeeded(state: "s")                 // fail 2 -> wait 2*base

        clock.advance(2 * base - 1)
        let still2 = await useCase.attestIfNeeded(state: "s")
        XCTAssertEqual(still2, .backingOff, "second window must be twice the first")

        // Many more failures must never exceed the cap.
        for _ in 0..<20 {
            clock.advance(AppAttestUseCase.maxBackoff + 1)
            _ = await useCase.attestIfNeeded(state: "s")
        }
        clock.advance(AppAttestUseCase.maxBackoff - 1)
        let capped = await useCase.attestIfNeeded(state: "s")
        XCTAssertEqual(capped, .backingOff)
        clock.advance(2)
        backend.set(.accepted)
        let recovered = await useCase.attestIfNeeded(state: "s")
        XCTAssertEqual(recovered, .attested, "the cap must bound the wait at maxBackoff")
    }

    func testSuccessResetsBackoff() async {
        backend.set(.failed(reason: "network"))
        let useCase = makeUseCase()
        _ = await useCase.attestIfNeeded(state: "s")
        clock.advance(AppAttestUseCase.baseBackoff + 1)
        backend.set(.accepted)
        _ = await useCase.attestIfNeeded(state: "s")
        XCTAssertEqual(store.keyId(), "key-2")

        // Simulate a later reinstall: fresh process state would also reset, but this proves
        // a success clears the failure counter rather than leaving a stale delay behind.
        store.clearKeyId(scope: AppAttestScope.current())
        let again = await useCase.attestIfNeeded(state: "s")
        XCTAssertEqual(again, .attested, "no leftover backoff after a success")
    }

    // MARK: Reinstall safety

    func testKeyWithoutInstallMarkerIsTreatedAsStaleAndReattested() async {
        store = FakeStore(keyId: "key-from-previous-install", marker: false)

        let outcome = await makeUseCase().attestIfNeeded(state: "s")

        XCTAssertEqual(outcome, .attested)
        XCTAssertEqual(store.keyId(), "key-1", "stale key replaced by a freshly attested one")
        XCTAssertEqual(platform.generateCalls, 1)
    }

    func testKeyWithInstallMarkerIsTrusted() async {
        store = FakeStore(keyId: "genuine-key", marker: true)

        let outcome = await makeUseCase().attestIfNeeded(state: "s")

        XCTAssertEqual(outcome, .alreadyAttested)
        XCTAssertEqual(store.keyId(), "genuine-key")
        XCTAssertEqual(platform.generateCalls, 0)
    }

    func testHasAttestedKeyIgnoresAStaleKey() async {
        store = FakeStore(keyId: "stale", marker: false)

        let has = await makeUseCase().hasAttestedKey()

        XCTAssertFalse(has)
        XCTAssertNil(store.keyId())
    }

    // MARK: Concurrency

    func testConcurrentCallsShareOneAttempt() async {
        platform.configure(suspendInGenerate: true)
        let useCase = makeUseCase()

        async let a = useCase.attestIfNeeded(state: "s")
        async let b = useCase.attestIfNeeded(state: "s")
        async let c = useCase.attestIfNeeded(state: "s")
        let outcomes = await [a, b, c]

        XCTAssertEqual(platform.generateCalls, 1, "one Apple round trip, not three")
        XCTAssertEqual(backend.calls.count, 1)
        XCTAssertEqual(outcomes, [.attested, .attested, .attested])
    }

    // MARK: Registration mapping

    func testRegistrationMapping() {
        func ok(_ status: String?) -> Result<AppAttestResponse, Error> {
            .success(AppAttestResponse(keyId: "k", status: status))
        }
        func http(_ code: Int) -> Result<AppAttestResponse, Error> {
            .failure(ApiError(message: "m", statusCode: code))
        }

        XCTAssertEqual(AppAttestRegistration.from(ok("SUCCESS")), .accepted)
        XCTAssertEqual(AppAttestRegistration.from(ok("success")), .accepted, "case-insensitive")
        XCTAssertEqual(AppAttestRegistration.from(ok("FAILED")), .rejected(reason: "status_failed"))
        XCTAssertEqual(AppAttestRegistration.from(ok(nil)), .rejected(reason: "status_missing"))

        XCTAssertEqual(AppAttestRegistration.from(http(400)), .rejected(reason: "http_400"))
        XCTAssertEqual(AppAttestRegistration.from(http(403)), .rejected(reason: "http_403"))
        XCTAssertEqual(AppAttestRegistration.from(http(408)), .failed(reason: "http_408"), "retryable")
        XCTAssertEqual(AppAttestRegistration.from(http(429)), .failed(reason: "http_429"), "retryable")
        XCTAssertEqual(AppAttestRegistration.from(http(500)), .failed(reason: "http_500"))
        XCTAssertEqual(AppAttestRegistration.from(http(503)), .failed(reason: "http_503"))
        XCTAssertEqual(AppAttestRegistration.from(.failure(URLError(.notConnectedToInternet))),
                       .failed(reason: "network"))
    }
}

// MARK: - A key belongs to one merchant app and environment

@available(iOS 14.0, *)
final class AppAttestScopingTests: XCTestCase {

    private var platform: FakePlatform!
    private var backend: FakeBackend!
    private var store: FakeStore!
    private var box: ScopeBox!

    override func setUp() {
        super.setUp()
        platform = FakePlatform(); backend = FakeBackend(); store = FakeStore(); box = ScopeBox("0.APP_A")
    }

    private func makeUseCase() -> AppAttestUseCase {
        AppAttestUseCase(platform: platform, backend: backend, store: store,
                         telemetry: TelemetryLog().telemetry, scope: { [box] in box!.value })
    }

    /// The bug found on a device: a key registered for one merchant app was reused for another,
    /// so the second app never got registered and the backend never knew its key.
    func testAKeyRegisteredForOneAppIsNotReusedForAnotherApp() async {
        let useCase = makeUseCase()

        let first = await useCase.attestIfNeeded(state: "s")
        XCTAssertEqual(first, .attested)

        box.value = "0.APP_B"
        let second = await useCase.attestIfNeeded(state: "s")

        XCTAssertEqual(second, .attested, "app B has no key of its own, so it must register one")
        XCTAssertEqual(platform.generateCalls, 2)
        XCTAssertEqual(backend.calls.count, 2, "the backend must be told about app B's key too")
        XCTAssertEqual(store.keyId(scope: "0.APP_A"), "key-1")
        XCTAssertEqual(store.keyId(scope: "0.APP_B"), "key-2")
    }

    func testSwitchingBackFindsTheOriginalAppsKeyAndDoesNotReRegister() async {
        let useCase = makeUseCase()
        _ = await useCase.attestIfNeeded(state: "s")
        box.value = "0.APP_B"; _ = await useCase.attestIfNeeded(state: "s")
        box.value = "0.APP_A"

        let outcome = await useCase.attestIfNeeded(state: "s")

        XCTAssertEqual(outcome, .alreadyAttested)
        XCTAssertEqual(platform.generateCalls, 2, "no third key")
    }

    /// Staging and production are different databases: a key known to one is unknown to the other.
    func testTheSameAppOnAnotherEnvironmentNeedsItsOwnKey() async {
        let useCase = makeUseCase()
        box.value = "1.APP_A"            // 1 = staging
        _ = await useCase.attestIfNeeded(state: "s")
        box.value = "0.APP_A"            // 0 = production
        let onProduction = await useCase.attestIfNeeded(state: "s")

        XCTAssertEqual(onProduction, .attested)
        XCTAssertEqual(platform.generateCalls, 2)
    }

    func testABackoffEarnedByOneAppDoesNotBlockAnother() async {
        backend.set(.failed(reason: "network"))
        let useCase = makeUseCase()
        let failed = await useCase.attestIfNeeded(state: "s")
        XCTAssertEqual(failed, .failed)

        box.value = "0.APP_B"
        backend.set(.accepted)
        let other = await useCase.attestIfNeeded(state: "s")

        XCTAssertEqual(other, .attested, "app B must not wait out app A's backoff")
    }

    func testAnUninstalledInstallDiscardsOnlyTheKeyOfTheScopeInUse() async {
        store = FakeStore(marker: false)
        store.saveKeyId("old-A", scope: "0.APP_A")
        store.saveKeyId("old-B", scope: "0.APP_B")

        let outcome = await makeUseCase().attestIfNeeded(state: "s")   // scope A

        XCTAssertEqual(outcome, .attested)
        XCTAssertEqual(store.keyId(scope: "0.APP_A"), "key-1", "A's stale key is replaced")
    }

    func testLiveStoreKeepsOneKeychainItemPerScope() {
        XCTAssertEqual(LiveAppAttestStore.keyName(scope: "0.MICKEY"), "otpless_bm_attest_key_id.0.MICKEY")
        XCTAssertNotEqual(LiveAppAttestStore.keyName(scope: "0.MICKEY"), LiveAppAttestStore.keyName(scope: "1.MICKEY"))
        XCTAssertNotEqual(LiveAppAttestStore.keyName(scope: "0.MICKEY"), LiveAppAttestStore.keyName(scope: "0.OTHER"))
        XCTAssertNotEqual(LiveAppAttestStore.keyName(scope: "0.MICKEY"), "otpless_bm_attest_key_id",
                          "must no longer be the single unscoped item")
    }

    func testScopeIsEnvironmentThenAppId() {
        XCTAssertEqual(AppAttestScope.current(),
                       "\(Otpless.shared.environment.rawValue).\(Otpless.shared.merchantAppId)")
    }
}

// MARK: - Config gate (no availability requirement)

final class AppAttestConfigGateTests: XCTestCase {

    private func decode(_ json: String) throws -> MerchantConfigResponse {
        try JSONDecoder().decode(MerchantConfigResponse.self, from: Data(json.utf8))
    }

    /// An older backend that has never heard of the flag must leave attestation off.
    func testAbsentFlagMeansDisabled() throws {
        XCTAssertFalse(try decode("{}").isAppAttestEnabled)
        XCTAssertFalse(try decode(#"{"authType":"OTP"}"#).isAppAttestEnabled)
    }

    func testEmptyOrNullConfigObjectMeansDisabled() throws {
        XCTAssertFalse(try decode(#"{"appAttestConfig":{}}"#).isAppAttestEnabled)
        XCTAssertFalse(try decode(#"{"appAttestConfig":null}"#).isAppAttestEnabled)
        XCTAssertFalse(try decode(#"{"appAttestConfig":{"isAppAttestEnabled":null}}"#).isAppAttestEnabled)
    }

    func testFalseMeansDisabledAndTrueMeansEnabled() throws {
        XCTAssertFalse(try decode(#"{"appAttestConfig":{"isAppAttestEnabled":false}}"#).isAppAttestEnabled)
        XCTAssertTrue(try decode(#"{"appAttestConfig":{"isAppAttestEnabled":true}}"#).isAppAttestEnabled)
    }

    /// The flag must not be disturbed by neighbouring fields, in either direction.
    func testUnrelatedFieldsDoNotAffectTheFlag() throws {
        let on = try decode(#"{"isMFAEnabled":true,"appAttestConfig":{"isAppAttestEnabled":true,"future":1},"x":2}"#)
        XCTAssertTrue(on.isAppAttestEnabled)
        XCTAssertEqual(on.isMFAEnabled, true)

        let off = try decode(#"{"isMFAEnabled":true,"metaData":{"deviceIntelligence":{"type":"SYNC"}}}"#)
        XCTAssertFalse(off.isAppAttestEnabled)
    }

    // MARK: Endpoint contract (ENG-516)

    func testAttestationPathMatchesTheBackendContract() {
        XCTAssertEqual(ApiManager.POST_DEVICE_ATTESTATION_PATH, "/v3/lp/user/device/attestation/{state}")
    }

    // MARK: Logging

    func testAttestationBlobIsRedactedForLogging() {
        let body: [String: Any] = ["keyId": "abc", "attestationObject": String(repeating: "A", count: 5000)]

        let redacted = ApiManager.redactedForLogging(body)

        XCTAssertEqual(redacted["keyId"] as? String, "abc")
        XCTAssertEqual(redacted["attestationObject"] as? String, "<redacted 5000 chars>")
        XCTAssertFalse(String(describing: redacted).contains("AAAAAAAAAA"))
    }

    func testRedactionLeavesOtherBodiesUntouched() {
        let body: [String: Any] = ["channel": "PHONE", "mobile": "123"]
        let redacted = ApiManager.redactedForLogging(body)
        XCTAssertEqual(redacted["channel"] as? String, "PHONE")
        XCTAssertEqual(redacted["mobile"] as? String, "123")
        XCTAssertEqual(redacted.count, 2)
    }
}

// MARK: - Request shape (what the backend actually receives)

private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _lastRequest: URLRequest?
    private static var _lastBody: Data?
    private static var _responseJSON = "{}"

    static var lastRequest: URLRequest? { lock.locked { _lastRequest } }
    static var lastBody: Data? { lock.locked { _lastBody } }
    static func reset(responseJSON: String) {
        lock.locked { _lastRequest = nil; _lastBody = nil; _responseJSON = responseJSON }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol receives the body as a stream, not as `httpBody`.
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: 4096)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
        } else if let direct = request.httpBody {
            body = direct
        }
        let json = StubURLProtocol.lock.locked { () -> String in
            StubURLProtocol._lastRequest = request
            StubURLProtocol._lastBody = body
            return StubURLProtocol._responseJSON
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AppAttestRequestShapeTests: XCTestCase {

    private func makeRepository() -> ApiRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let manager = ApiManager(userAuthTimeout: 5, snaTimeout: 5, enableLogging: false,
                                 session: URLSession(configuration: configuration))
        return ApiRepository(apiManager: manager)
    }

    private func sentBody() throws -> [String: Any] {
        let data = try XCTUnwrap(StubURLProtocol.lastBody, "no request reached the stub")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPostsToTheContractPathWithStateInTheUrl() async throws {
        StubURLProtocol.reset(responseJSON: #"{"keyId":"k1","status":"SUCCESS"}"#)

        let result = await makeRepository().postDeviceAttestation(state: "st-123", keyId: "k1", attestationObject: "QUJD")

        guard case .success(let response) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(response.status, "SUCCESS")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v3/lp/user/device/attestation/st-123")
    }

    func testBodyCarriesKeyIdAndAttestationObject() async throws {
        StubURLProtocol.reset(responseJSON: #"{"keyId":"k1","status":"SUCCESS"}"#)

        _ = await makeRepository().postDeviceAttestation(state: "s", keyId: "key-abc", attestationObject: "QUJDREVG")

        let body = try sentBody()
        XCTAssertEqual(body["keyId"] as? String, "key-abc")
        XCTAssertEqual(body["attestationObject"] as? String, "QUJDREVG")
    }

    /// Regression: the backend's state interceptor builds its AuthDTO from the POST body and
    /// resolves the merchant app from `appId` (and `loginUri` / `packageName`). A bare
    /// `{keyId, attestationObject}` body is rejected before it reaches the controller, so
    /// these standard parameters must be present, exactly as for the intent request.
    func testBodyKeepsTheStandardParamsTheServerNeedsToIdentifyTheApp() async throws {
        StubURLProtocol.reset(responseJSON: #"{"keyId":"k1","status":"SUCCESS"}"#)

        _ = await makeRepository().postDeviceAttestation(state: "s", keyId: "k", attestationObject: "QQ==")

        let body = try sentBody()
        for key in ["appId", "loginUri", "packageName"] {
            XCTAssertNotNil(body[key], "POST body is missing `\(key)`; the server cannot resolve the app without it")
        }
    }
}


// MARK: - Assertion in the body (ENG-521)

@available(iOS 14.0, *)
final class AppAttestAssertionTests: XCTestCase {

    private var platform: FakePlatform!
    private var store: FakeStore!
    private var log: TelemetryLog!

    /// The body fields the server will read, as the SDK sends them for a phone intent.
    private let fields: [String: String] = [
        "appId": "APP1", "tsId": "TS1", "channel": "PHONE", "identifierType": "MOBILE", "value": "919999999999",
        "loginUri": "otpless.app1://otpless", "packageName": "com.example", "uid": "U", "deviceInfo": "{...}"
    ]

    override func setUp() {
        super.setUp()
        platform = FakePlatform()
        store = FakeStore(keyId: "registered-key", marker: true)
        log = TelemetryLog()
    }

    private func makeUseCase(timeout: TimeInterval = 1.0) -> AppAttestUseCase {
        AppAttestUseCase(platform: platform, backend: FakeBackend(), store: store,
                         telemetry: log.telemetry, assertionTimeout: timeout)
    }

    private func signedHash(_ fields: [String: String], challenge: String = "ch") async -> Data? {
        platform = FakePlatform()
        _ = await makeUseCase().assertionInfo(forFields: fields, challenge: challenge)
        return platform.assertionCalls.first?.hash
    }

    // MARK: The info object

    func testRegisteredKeyProducesTheFourMembers() async {
        platform.configureAssertion(output: Data("sig".utf8))

        let info = await makeUseCase().assertionInfo(forFields: fields, challenge: "ch-1")

        XCTAssertEqual(info[AppAttestInfo.status], "ok")
        XCTAssertEqual(info[AppAttestInfo.keyId], "registered-key")
        XCTAssertEqual(info[AppAttestInfo.assertion], Data("sig".utf8).base64EncodedString())
        XCTAssertEqual(info[AppAttestInfo.challenge], "ch-1")
        XCTAssertEqual(info.count, 4)
        XCTAssertTrue(log.events.isEmpty, "the happy path must not generate telemetry on every intent")
    }

    // MARK: What is hashed (the contract with the backend)

    /// Pinned literally: the backend implements exactly this string.
    func testCanonicalStringFormat() {
        XCTAssertEqual(AppAttestInfo.canonicalString(challenge: "ch", fields: fields),
                       "v1|ch|APP1|TS1|PHONE|MOBILE|919999999999")
    }

    func testMissingFieldsBecomeEmptyStrings() {
        XCTAssertEqual(AppAttestInfo.canonicalString(challenge: "ch", fields: ["appId": "A"]),
                       "v1|ch|A||||")
    }

    func testClientDataHashIsSha256OfTheCanonicalString() async {
        let h = await signedHash(fields, challenge: "ch-xyz")

        let expected = Data(SHA256.hash(data: Data("v1|ch-xyz|APP1|TS1|PHONE|MOBILE|919999999999".utf8)))
        XCTAssertEqual(h, expected)
        XCTAssertEqual(platform.assertionCalls.first?.keyId, "registered-key")
    }

    /// Each signed field must matter: changing the destination, the app, the session or the
    /// challenge has to change what is signed, or an assertion could be reused.
    func testEverySignedFieldAndTheChallengeChangeTheHash() async {
        let base = await signedHash(fields)
        for name in AppAttestInfo.signedFields {
            var changed = fields; changed[name] = (changed[name] ?? "") + "x"
            let h = await signedHash(changed)
            XCTAssertNotEqual(h, base, "changing `\(name)` must change the signed hash")
        }
        let otherChallenge = await signedHash(fields, challenge: "other")
        XCTAssertNotEqual(otherChallenge, base, "changing the challenge must change the signed hash")
    }

    /// The flip side: fields the backend rewrites or that are free-form must NOT matter, or the
    /// two sides would disagree and every assertion would fail verification.
    func testFieldsOutsideTheListDoNotChangeTheHash() async {
        let base = await signedHash(fields)
        for name in ["loginUri", "packageName", "uid", "deviceInfo", "metadata", "somethingNew"] {
            var changed = fields; changed[name] = "different"
            let h = await signedHash(changed)
            XCTAssertEqual(h, base, "`\(name)` is not signed and must not affect the hash")
        }
    }

    // MARK: Failure modes

    func testUnsupportedDeviceReportsStatusOnly() async {
        platform.configure(supported: false)

        let info = await makeUseCase().assertionInfo(forFields: fields, challenge: "c")

        XCTAssertEqual(info, [AppAttestInfo.status: "unsupported"])
        XCTAssertTrue(platform.assertionCalls.isEmpty)
        XCTAssertEqual(log.events, ["assertionSkipped:unsupported"])
    }

    func testNoRegisteredKeyReportsNoKey() async {
        store = FakeStore()

        let info = await makeUseCase().assertionInfo(forFields: fields, challenge: "c")

        XCTAssertEqual(info, [AppAttestInfo.status: "no_key"])
        XCTAssertTrue(platform.assertionCalls.isEmpty, "must not ask Apple to sign with a key we never registered")
        XCTAssertEqual(log.events, ["assertionSkipped:no_key"])
    }

    func testStaleKeyFromAPreviousInstallIsNotUsed() async {
        store = FakeStore(keyId: "from-previous-install", marker: false)

        let info = await makeUseCase().assertionInfo(forFields: fields, challenge: "c")

        XCTAssertEqual(info[AppAttestInfo.status], "no_key")
        XCTAssertTrue(platform.assertionCalls.isEmpty)
        XCTAssertNil(store.keyId(), "the stale key must be discarded")
    }

    /// The device finding in the assertion path: signing with a key that was registered for a
    /// different merchant app would produce an assertion the backend cannot match to any key.
    func testAKeyRegisteredForAnotherAppIsNotUsedToSign() async {
        let box = ScopeBox("0.APP_A")
        store = FakeStore(marker: true)
        store.saveKeyId("key-of-A", scope: "0.APP_A")
        let useCase = AppAttestUseCase(platform: platform, backend: FakeBackend(), store: store,
                                       telemetry: log.telemetry, scope: { box.value })

        box.value = "0.APP_B"
        let forB = await useCase.assertionInfo(forFields: fields, challenge: "c")
        XCTAssertEqual(forB, [AppAttestInfo.status: "no_key"], "app B has no key of its own")
        XCTAssertTrue(platform.assertionCalls.isEmpty, "must not sign with app A's key")

        box.value = "0.APP_A"
        let forA = await useCase.assertionInfo(forFields: fields, challenge: "c")
        XCTAssertEqual(forA[AppAttestInfo.status], "ok")
        XCTAssertEqual(forA[AppAttestInfo.keyId], "key-of-A")
    }

    func testInvalidKeyClearsTheStoredKeySoTheNextInitReattests() async {
        platform.configureAssertion(error: DCError(.invalidKey))

        let info = await makeUseCase().assertionInfo(forFields: fields, challenge: "c")

        XCTAssertEqual(info, [AppAttestInfo.status: "invalid_key"])
        XCTAssertNil(store.keyId(), "a key Apple no longer knows must not be kept")
        XCTAssertEqual(log.events, ["assertionFailure:invalid_key"])
    }

    func testOtherAppleErrorsKeepTheKeyAndReportACode() async {
        platform.configureAssertion(error: DCError(.serverUnavailable))

        let info = await makeUseCase().assertionInfo(forFields: fields, challenge: "c")

        XCTAssertEqual(info[AppAttestInfo.status], "dcerror_\(DCError.Code.serverUnavailable.rawValue)")
        XCTAssertEqual(store.keyId(), "registered-key", "a transient Apple error must not throw the key away")
        XCTAssertNil(info[AppAttestInfo.assertion])
    }

    func testUnknownErrorReportsGenericReason() async {
        platform.configureAssertion(error: BoomError())

        let info = await makeUseCase().assertionInfo(forFields: fields, challenge: "c")

        XCTAssertEqual(info, [AppAttestInfo.status: "error"])
        XCTAssertEqual(store.keyId(), "registered-key")
    }

    /// A hung Apple call must not hang the merchant's request.
    func testSlowAssertionTimesOutAndReturnsPromptly() async {
        platform.configureAssertion(delaySeconds: 2.0)
        let started = Date()

        let info = await makeUseCase(timeout: 0.05).assertionInfo(forFields: fields, challenge: "c")

        XCTAssertEqual(info, [AppAttestInfo.status: "timeout"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "must return at the budget, not wait for Apple")
        XCTAssertEqual(store.keyId(), "registered-key")
        XCTAssertEqual(log.events, ["assertionFailure:timeout"])
    }
}

// MARK: - Intent request on the wire (ENG-521)

@available(iOS 14.0, *)
final class AppAttestIntentRequestTests: XCTestCase {

    private var platform: FakePlatform!
    private var store: FakeStore!

    override func setUp() {
        super.setUp()
        platform = FakePlatform()
        store = FakeStore(keyId: "registered-key", marker: true)
        platform.configureAssertion(output: Data("the-assertion".utf8))
    }

    private func makeRepository() -> ApiRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let manager = ApiManager(userAuthTimeout: 5, snaTimeout: 5, enableLogging: false,
                                 session: URLSession(configuration: configuration))
        return ApiRepository(apiManager: manager)
    }

    private func makeBody() -> PostIntentRequestBody {
        PostIntentRequestBody(
            channel: "PHONE", email: nil, hasWhatsapp: "false", identifierType: "MOBILE",
            mobile: "9999999999", selectedCountryCode: "91", silentAuthEnabled: false,
            triggerWebauthn: false, type: "INTENT", uid: nil, value: "919999999999", expiry: nil,
            deliveryMethod: nil, otpLength: nil, uiIds: nil, fireIntent: nil, requestId: nil,
            clientMetaData: nil, asId: nil
        )
    }

    private func realSigner(state: String) -> ApiManager.BodySigner {
        let useCase = AppAttestUseCase(platform: platform, backend: FakeBackend(), store: store,
                                       telemetry: TelemetryLog().telemetry)
        return { fields in [AppAttestInfo.bodyKey: await useCase.assertionInfo(forFields: fields, challenge: state)] }
    }

    private func sentJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(StubURLProtocol.lastBody, "no request reached the stub")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// What the server will do: parse the body it received, rebuild the canonical string from the
    /// fields it read, hash it. That must equal what Apple was asked to sign.
    func testSignedHashMatchesWhatTheServerRebuildsFromTheReceivedBody() async throws {
        StubURLProtocol.reset(responseJSON: "{}")

        _ = await makeRepository().postIntent(state: "st-123", body: makeBody(), bodySigner: realSigner(state: "st-123"))

        let json = try sentJSON()
        let info = try XCTUnwrap(json[AppAttestInfo.bodyKey] as? [String: String])
        let serverFields = json.compactMapValues { $0 as? String }
        let canonical = AppAttestInfo.canonicalString(challenge: info[AppAttestInfo.challenge] ?? "", fields: serverFields)
        XCTAssertEqual(try XCTUnwrap(platform.assertionCalls.first?.hash),
                       Data(SHA256.hash(data: Data(canonical.utf8))),
                       "the signed hash must equal SHA256 of the string rebuilt from the received body")
        XCTAssertTrue(canonical.hasPrefix("v1|st-123|"), canonical)
        XCTAssertTrue(canonical.hasSuffix("|PHONE|MOBILE|919999999999"), canonical)
    }

    func testIntentBodyCarriesTheInfoObject() async throws {
        StubURLProtocol.reset(responseJSON: "{}")

        _ = await makeRepository().postIntent(state: "st-9", body: makeBody(), bodySigner: realSigner(state: "st-9"))

        let json = try sentJSON()
        let info = try XCTUnwrap(json[AppAttestInfo.bodyKey] as? [String: String])
        XCTAssertEqual(info[AppAttestInfo.status], "ok")
        XCTAssertEqual(info[AppAttestInfo.keyId], "registered-key")
        XCTAssertEqual(info[AppAttestInfo.assertion], Data("the-assertion".utf8).base64EncodedString())
        XCTAssertEqual(info[AppAttestInfo.challenge], "st-9")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v3/lp/user/transaction/intent/st-9")
    }

    /// No headers any more: the whole thing lives in the body.
    func testNothingIsSentInHeaders() async throws {
        StubURLProtocol.reset(responseJSON: "{}")

        _ = await makeRepository().postIntent(state: "st-9", body: makeBody(), bodySigner: realSigner(state: "st-9"))

        let headers = try XCTUnwrap(StubURLProtocol.lastRequest).allHTTPHeaderFields ?? [:]
        XCTAssertTrue(headers.keys.allSatisfy { !$0.lowercased().contains("attest") }, "\(headers)")
    }

    /// Adding the object must not disturb any existing member of the intent body.
    func testExistingBodyMembersAreUntouched() async throws {
        StubURLProtocol.reset(responseJSON: "{}")
        _ = await makeRepository().postIntent(state: "st-1", body: makeBody())
        let without = try sentJSON()

        StubURLProtocol.reset(responseJSON: "{}")
        _ = await makeRepository().postIntent(state: "st-1", body: makeBody(), bodySigner: realSigner(state: "st-1"))
        let with = try sentJSON()

        XCTAssertEqual(Set(with.keys), Set(without.keys).union([AppAttestInfo.bodyKey]))
        for (key, value) in without {
            XCTAssertEqual(String(describing: with[key] ?? "<missing>"), String(describing: value), "`\(key)` changed")
        }
    }

    /// Merchants without attestation must send the same body as before. `merchantConfig` is nil
    /// in a unit test, which is exactly "attestation not enabled".
    func testNoInfoObjectWhenAttestationIsNotEnabled() async throws {
        StubURLProtocol.reset(responseJSON: "{}")

        _ = await makeRepository().postIntent(state: "st-1", body: makeBody())

        XCTAssertNil(try sentJSON()[AppAttestInfo.bodyKey])
        XCTAssertNil(ApiRepository.defaultAppAttestSigner(state: "st-1"))
    }

    /// Fail open: no assertion available still sends the intent, with a reason.
    func testIntentIsStillSentWhenNoAssertionCanBeProduced() async throws {
        StubURLProtocol.reset(responseJSON: "{}")
        store = FakeStore()                                        // nothing registered yet

        _ = await makeRepository().postIntent(state: "st-2", body: makeBody(), bodySigner: realSigner(state: "st-2"))

        XCTAssertNotNil(StubURLProtocol.lastRequest, "the intent must still go out")
        let info = try XCTUnwrap(try sentJSON()[AppAttestInfo.bodyKey] as? [String: String])
        XCTAssertEqual(info, [AppAttestInfo.status: "no_key"])
    }
}
