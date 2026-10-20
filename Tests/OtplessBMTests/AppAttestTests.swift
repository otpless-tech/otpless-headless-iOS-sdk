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
    private var _keyId: String?
    private var _marker = false

    init(keyId: String? = nil, marker: Bool = false) { _keyId = keyId; _marker = marker }

    func keyId() -> String? { lock.locked { _keyId } }
    func saveKeyId(_ keyId: String) { lock.locked { _keyId = keyId } }
    func clearKeyId() { lock.locked { _keyId = nil } }
    var hasInstallMarker: Bool { lock.locked { _marker } }
    func setInstallMarker() { lock.locked { _marker = true } }
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
        store.clearKeyId()
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


// MARK: - Assertion headers (ENG-521)

@available(iOS 14.0, *)
final class AppAttestAssertionTests: XCTestCase {

    private var platform: FakePlatform!
    private var store: FakeStore!
    private var log: TelemetryLog!

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

    func testRegisteredKeyProducesTheFourHeaders() async {
        platform.configureAssertion(output: Data("sig".utf8))

        let h = await makeUseCase().assertionHeaders(forBody: Data("{}".utf8), challenge: "ch-1")

        XCTAssertEqual(h[AppAttestHeader.status], "ok")
        XCTAssertEqual(h[AppAttestHeader.keyId], "registered-key")
        XCTAssertEqual(h[AppAttestHeader.assertion], Data("sig".utf8).base64EncodedString())
        XCTAssertEqual(h[AppAttestHeader.challenge], "ch-1")
        XCTAssertEqual(h.count, 4)
        XCTAssertTrue(log.events.isEmpty, "the happy path must not generate telemetry on every intent")
    }

    /// The server recomputes this from the raw request bytes, so the formula is the contract.
    func testClientDataHashIsSha256OfChallengeThenBodyBytes() async {
        let body = Data(#"{"a":1,"b":"two"}"#.utf8)

        _ = await makeUseCase().assertionHeaders(forBody: body, challenge: "ch-xyz")

        XCTAssertEqual(platform.assertionCalls.count, 1)
        XCTAssertEqual(platform.assertionCalls.first?.keyId, "registered-key")
        XCTAssertEqual(platform.assertionCalls.first?.hash, Data(SHA256.hash(data: Data("ch-xyz".utf8) + body)))
    }

    func testHashDependsOnBothBodyAndChallenge() async {
        let useCase = makeUseCase()
        _ = await useCase.assertionHeaders(forBody: Data("A".utf8), challenge: "c")
        _ = await useCase.assertionHeaders(forBody: Data("B".utf8), challenge: "c")
        _ = await useCase.assertionHeaders(forBody: Data("A".utf8), challenge: "d")

        let hashes = platform.assertionCalls.map { $0.hash }
        XCTAssertEqual(Set(hashes).count, 3, "changing the body or the challenge must change what is signed")
    }

    func testUnsupportedDeviceReportsStatusOnly() async {
        platform.configure(supported: false)

        let h = await makeUseCase().assertionHeaders(forBody: Data(), challenge: "c")

        XCTAssertEqual(h, [AppAttestHeader.status: "unsupported"])
        XCTAssertTrue(platform.assertionCalls.isEmpty)
        XCTAssertEqual(log.events, ["assertionSkipped:unsupported"])
    }

    func testNoRegisteredKeyReportsNoKey() async {
        store = FakeStore()

        let h = await makeUseCase().assertionHeaders(forBody: Data(), challenge: "c")

        XCTAssertEqual(h, [AppAttestHeader.status: "no_key"])
        XCTAssertTrue(platform.assertionCalls.isEmpty, "must not ask Apple to sign with a key we never registered")
        XCTAssertEqual(log.events, ["assertionSkipped:no_key"])
    }

    func testStaleKeyFromAPreviousInstallIsNotUsed() async {
        store = FakeStore(keyId: "from-previous-install", marker: false)

        let h = await makeUseCase().assertionHeaders(forBody: Data(), challenge: "c")

        XCTAssertEqual(h[AppAttestHeader.status], "no_key")
        XCTAssertTrue(platform.assertionCalls.isEmpty)
        XCTAssertNil(store.keyId(), "the stale key must be discarded")
    }

    func testInvalidKeyClearsTheStoredKeySoTheNextInitReattests() async {
        platform.configureAssertion(error: DCError(.invalidKey))

        let h = await makeUseCase().assertionHeaders(forBody: Data(), challenge: "c")

        XCTAssertEqual(h, [AppAttestHeader.status: "invalid_key"])
        XCTAssertNil(store.keyId(), "a key Apple no longer knows must not be kept")
        XCTAssertEqual(log.events, ["assertionFailure:invalid_key"])
    }

    func testOtherAppleErrorsKeepTheKeyAndReportACode() async {
        platform.configureAssertion(error: DCError(.serverUnavailable))

        let h = await makeUseCase().assertionHeaders(forBody: Data(), challenge: "c")

        XCTAssertEqual(h[AppAttestHeader.status], "dcerror_\(DCError.Code.serverUnavailable.rawValue)")
        XCTAssertEqual(store.keyId(), "registered-key", "a transient Apple error must not throw the key away")
        XCTAssertNil(h[AppAttestHeader.assertion])
    }

    func testUnknownErrorReportsGenericReason() async {
        platform.configureAssertion(error: BoomError())

        let h = await makeUseCase().assertionHeaders(forBody: Data(), challenge: "c")

        XCTAssertEqual(h, [AppAttestHeader.status: "error"])
        XCTAssertEqual(store.keyId(), "registered-key")
    }

    /// A hung Apple call must not hang the merchant's request.
    func testSlowAssertionTimesOutAndReturnsPromptly() async {
        platform.configureAssertion(delaySeconds: 2.0)
        let started = Date()

        let h = await makeUseCase(timeout: 0.05).assertionHeaders(forBody: Data(), challenge: "c")

        XCTAssertEqual(h, [AppAttestHeader.status: "timeout"])
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

    private func headers() throws -> [String: String] {
        try XCTUnwrap(StubURLProtocol.lastRequest, "no request reached the stub").allHTTPHeaderFields ?? [:]
    }

    /// The point of the whole feature: what Apple signed must be exactly what the server will
    /// hash, i.e. SHA256(challenge || the bytes that actually went over the wire).
    func testSignedHashMatchesTheExactBytesThatWereSent() async throws {
        StubURLProtocol.reset(responseJSON: "{}")
        let useCase = AppAttestUseCase(platform: platform, backend: FakeBackend(), store: store,
                                       telemetry: TelemetryLog().telemetry)

        _ = await makeRepository().postIntent(state: "st-123", body: makeBody(), requestSigner: { bytes in
            await useCase.assertionHeaders(forBody: bytes, challenge: "st-123")
        })

        let sent = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertFalse(sent.isEmpty)
        let signed = try XCTUnwrap(platform.assertionCalls.first?.hash)
        XCTAssertEqual(signed, Data(SHA256.hash(data: Data("st-123".utf8) + sent)),
                       "the signed hash must be over the exact body bytes on the wire")
    }

    func testIntentCarriesTheHeaders() async throws {
        StubURLProtocol.reset(responseJSON: "{}")
        let useCase = AppAttestUseCase(platform: platform, backend: FakeBackend(), store: store,
                                       telemetry: TelemetryLog().telemetry)

        _ = await makeRepository().postIntent(state: "st-9", body: makeBody(), requestSigner: { bytes in
            await useCase.assertionHeaders(forBody: bytes, challenge: "st-9")
        })

        let h = try headers()
        XCTAssertEqual(h[AppAttestHeader.status], "ok")
        XCTAssertEqual(h[AppAttestHeader.keyId], "registered-key")
        XCTAssertEqual(h[AppAttestHeader.assertion], Data("the-assertion".utf8).base64EncodedString())
        XCTAssertEqual(h[AppAttestHeader.challenge], "st-9")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v3/lp/user/transaction/intent/st-9")
    }

    /// Merchants without attestation must see an unchanged request. `merchantConfig` is nil in
    /// a unit test, which is exactly "attestation not enabled".
    func testNoAttestationHeadersWhenAttestationIsNotEnabled() async throws {
        StubURLProtocol.reset(responseJSON: "{}")

        _ = await makeRepository().postIntent(state: "st-1", body: makeBody())

        let h = try headers()
        for name in [AppAttestHeader.status, AppAttestHeader.keyId, AppAttestHeader.assertion, AppAttestHeader.challenge] {
            XCTAssertNil(h[name], "\(name) must not be sent when attestation is not enabled")
        }
        XCTAssertNil(ApiRepository.defaultAppAttestSigner(state: "st-1"))
    }

    /// Fail open: no assertion available still sends the intent, with a reason.
    func testIntentIsStillSentWhenNoAssertionCanBeProduced() async throws {
        StubURLProtocol.reset(responseJSON: "{}")
        store = FakeStore()                                        // nothing registered yet
        let useCase = AppAttestUseCase(platform: platform, backend: FakeBackend(), store: store,
                                       telemetry: TelemetryLog().telemetry)

        _ = await makeRepository().postIntent(state: "st-2", body: makeBody(), requestSigner: { bytes in
            await useCase.assertionHeaders(forBody: bytes, challenge: "st-2")
        })

        XCTAssertNotNil(StubURLProtocol.lastRequest, "the intent must still go out")
        let h = try headers()
        XCTAssertEqual(h[AppAttestHeader.status], "no_key")
        XCTAssertNil(h[AppAttestHeader.assertion])
        XCTAssertNil(h[AppAttestHeader.keyId])
    }
}
