//
//  AppAttestTests.swift
//  OtplessBMTests
//
//  Covers App Attest's config gate, the registration request shape, and the per-intent
//  assertion (ENG-519, ENG-521). Hermetic: Apple's service and storage are fakes and the
//  network is a URL stub, so this runs on a simulator with no network.
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

    func generateAssertion(id keyId: String, data clientDataHash: Data) async throws -> Data {
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

    func attestKey(id keyId: String, data clientDataHash: Data) async throws -> Data {
        let err: Error? = lock.locked {
            _attested.append((keyId, clientDataHash))
            return _attestError
        }
        if let err { throw err }
        return Data("attestation-for-\(keyId)".utf8)
    }
}

/// URLProtocol receives a POST body as a stream, not as `httpBody`.
private func bodyData(of request: URLRequest) -> Data {
    guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
    var body = Data()
    stream.open()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate(); stream.close() }
    while stream.hasBytesAvailable {
        let n = stream.read(buffer, maxLength: 4096)
        if n <= 0 { break }
        body.append(buffer, count: n)
    }
    return body
}

private final class FakeStore: AppAttestStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _keyId: String?
    private var _marker = false
    private var _readable = true

    func setReadable(_ value: Bool) { lock.locked { _readable = value } }
    func isReadable() -> Bool { lock.locked { _readable } }

    init(keyId: String? = nil, marker: Bool = false) {
        _keyId = keyId
        _marker = marker
    }

    func keyId() -> String? { lock.locked { _keyId } }
    func saveKeyId(_ keyId: String) { lock.locked { _keyId = keyId } }
    func clearKeyId() { lock.locked { _keyId = nil } }
    var hasInstallMarker: Bool { lock.locked { _marker } }
    func setInstallMarker() { lock.locked { _marker = true } }
}

private struct BoomError: Error {}

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
        XCTAssertFalse(try decode(#"{"merchant":{}}"#).isAppAttestEnabled)
        XCTAssertFalse(try decode(#"{"merchant":{"config":null}}"#).isAppAttestEnabled)
        XCTAssertFalse(try decode(#"{"merchant":{"config":{"isAttestationEnabled":null}}}"#).isAppAttestEnabled)
    }

    func testFalseMeansDisabledAndTrueMeansEnabled() throws {
        XCTAssertFalse(try decode(#"{"merchant":{"config":{"isAttestationEnabled":false}}}"#).isAppAttestEnabled)
        XCTAssertTrue(try decode(#"{"merchant":{"config":{"isAttestationEnabled":true}}}"#).isAppAttestEnabled)
    }

    /// The flag must not be disturbed by neighbouring fields, in either direction.
    func testUnrelatedFieldsDoNotAffectTheFlag() throws {
        let on = try decode(#"{"isMFAEnabled":true,"merchant":{"config":{"isAttestationEnabled":true,"lang":"en","future":1}},"x":2}"#)
        XCTAssertTrue(on.isAppAttestEnabled)
        XCTAssertEqual(on.isMFAEnabled, true)

        let off = try decode(#"{"isMFAEnabled":true,"metaData":{"deviceIntelligence":{"type":"SYNC"}}}"#)
        XCTAssertFalse(off.isAppAttestEnabled)
    }

    // MARK: Endpoint contract (ENG-516)

    func testAttestationPathMatchesTheBackendContract() {
        XCTAssertEqual(ApiManager.POST_DEVICE_ATTESTATION_PATH, "/v3/device/attestation/{state}")
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
        let body = bodyData(of: request)
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
        XCTAssertEqual(request.url?.path, "/v3/device/attestation/st-123")
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

    override func setUp() {
        super.setUp()
        platform = FakePlatform()
        store = FakeStore(keyId: "registered-key", marker: true)
    }

    private func makeUseCase() -> AppAttestUseCase {
        AppAttestUseCase(platform: platform, store: store)
    }

    // MARK: The info object

    func testRegisteredKeyProducesTheFourMembers() async {
        platform.configureAssertion(output: Data("sig".utf8))

        let info = await makeUseCase().assertionInfo(challenge: "ch-1", state: "st")

        XCTAssertEqual(info["status"], "ok")
        XCTAssertEqual(info["keyId"], "registered-key")
        XCTAssertEqual(info["assertion"], Data("sig".utf8).base64EncodedString())
        XCTAssertEqual(info["challenge"], "st")
        XCTAssertEqual(info.count, 4)
    }

    /// Non-ASCII is hashed as UTF-8, the same bytes a server decoding the JSON sees.
    func testClientDataHashIsSha256OfTheChallenge() async {
        let challenge = "v1|st|TS1|EMAIL|ñandú@例え.jp"

        _ = await makeUseCase().assertionInfo(challenge: challenge, state: "st")

        XCTAssertEqual(platform.assertionCalls.first?.hash, Data(SHA256.hash(data: Data(challenge.utf8))))
        XCTAssertEqual(platform.assertionCalls.first?.keyId, "registered-key")
    }

    // MARK: Failure modes

    func testUnsupportedDeviceReportsStatusOnly() async {
        platform.configure(supported: false)

        let info = await makeUseCase().assertionInfo(challenge: "c", state: "st")

        XCTAssertEqual(info, ["status": "unsupported"])
        XCTAssertTrue(platform.assertionCalls.isEmpty)
    }

    /// No key: it tries to register one before giving up. Apple's key generation fails here, so
    /// the attempt never reaches the backend and the request goes out with `no_key`.
    func testNoRegisteredKeyTriesToRegisterThenReportsNoKey() async {
        store = FakeStore()
        platform.configure(generateError: BoomError())

        let info = await makeUseCase().assertionInfo(challenge: "c", state: "st")

        XCTAssertEqual(info, ["status": "no_key"])
        XCTAssertEqual(platform.generateCalls, 1, "must try to register a key before giving up")
        XCTAssertTrue(platform.assertionCalls.isEmpty, "must not ask Apple to sign with a key we never registered")
    }

    /// A failed registration backs off, so the next request does not retry it straight away.
    func testAFailedRegistrationIsNotRetriedOnEveryRequest() async {
        store = FakeStore()
        platform.configure(generateError: BoomError())
        let useCase = makeUseCase()

        _ = await useCase.assertionInfo(challenge: "c", state: "st")
        let second = await useCase.assertionInfo(challenge: "c", state: "st")

        XCTAssertEqual(second, ["status": "no_key"])
        XCTAssertEqual(platform.generateCalls, 1, "the backoff must hold the second attempt")
    }

    /// A key that survived a reinstall is discarded, and a new one is registered in its place.
    func testStaleKeyFromAPreviousInstallIsDiscardedAndReRegistered() async {
        store = FakeStore(keyId: "from-previous-install", marker: false)
        platform.configure(generateError: BoomError())

        let info = await makeUseCase().assertionInfo(challenge: "c", state: "st")

        XCTAssertEqual(info["status"], "no_key")
        XCTAssertTrue(platform.assertionCalls.isEmpty)
        XCTAssertNil(store.keyId(), "the stale key must be discarded")
        XCTAssertEqual(platform.generateCalls, 1, "a new key must be registered in its place")
    }

    func testInvalidKeyClearsTheStoredKeySoTheNextInitReattests() async {
        platform.configureAssertion(error: DCError(.invalidKey))

        let info = await makeUseCase().assertionInfo(challenge: "c", state: "st")

        XCTAssertEqual(info, ["status": "invalid_key"])
        XCTAssertNil(store.keyId(), "a key Apple no longer knows must not be kept")
    }

    func testOtherAppleErrorsKeepTheKeyAndReportACode() async {
        platform.configureAssertion(error: DCError(.serverUnavailable))

        let info = await makeUseCase().assertionInfo(challenge: "c", state: "st")

        XCTAssertEqual(info["status"], "dcerror_\(DCError.Code.serverUnavailable.rawValue)")
        XCTAssertEqual(store.keyId(), "registered-key", "a transient Apple error must not throw the key away")
        XCTAssertNil(info["assertion"])
    }

    func testUnknownErrorReportsGenericReason() async {
        platform.configureAssertion(error: BoomError())

        let info = await makeUseCase().assertionInfo(challenge: "c", state: "st")

        XCTAssertEqual(info, ["status": "error"])
        XCTAssertEqual(store.keyId(), "registered-key")
    }

    /// A hung Apple call must not hang the merchant's request.
    func testSlowAssertionTimesOutAndReturnsPromptly() async {
        platform.configureAssertion(delaySeconds: 3.0)
        let started = Date()

        let info = await makeUseCase().assertionInfo(challenge: "c", state: "st")

        XCTAssertEqual(info, ["status": "timeout"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "must return at the 1 s budget, not wait for Apple")
        XCTAssertEqual(store.keyId(), "registered-key")
    }
}

// MARK: - Assertion challenge built by the intent (ENG-521)

final class AppAttestChallengeTests: XCTestCase {

    private func body(channel: String, value: String?) -> PostIntentRequestBody {
        PostIntentRequestBody(
            channel: channel, email: nil, hasWhatsapp: "false", identifierType: "MOBILE",
            mobile: nil, selectedCountryCode: nil, silentAuthEnabled: false, triggerWebauthn: false,
            type: "INPUT", uid: nil, value: value, expiry: nil, deliveryMethod: nil, otpLength: nil,
            uiIds: nil, fireIntent: nil, requestId: nil, clientMetaData: nil, asId: nil
        )
    }

    private func challenge(channel: String, value: String?) -> String {
        PostIntentUseCase.appAttestChallenge(challenge: "st", tsId: "TS1", requestBody: body(channel: channel, value: value))
    }

    private var appId: String { Otpless.shared.merchantAppId }

    /// Pinned literally: the backend rebuilds exactly this string.
    func testPhoneChallenge() {
        XCTAssertEqual(challenge(channel: "PHONE", value: "919999999999"), "v1|st|\(appId)|TS1|PHONE|MOBILE|919999999999")
    }

    func testEmailChallenge() {
        XCTAssertEqual(challenge(channel: "EMAIL", value: "user@example.com"), "v1|st|\(appId)|TS1|EMAIL|MOBILE|user@example.com")
    }

    /// An SSO intent sends an empty `value`; the provider is the channel.
    func testSsoChallengeHasAnEmptyValue() {
        XCTAssertEqual(challenge(channel: "GMAIL", value: ""), "v1|st|\(appId)|TS1|GMAIL|MOBILE|")
        XCTAssertEqual(challenge(channel: "GMAIL", value: nil), "v1|st|\(appId)|TS1|GMAIL|MOBILE|")
    }

    /// `value` is last, so a `|` inside it cannot shift the fields in front of it.
    func testPipeInsideValueCannotShiftTheEarlierFields() {
        let parts = challenge(channel: "PHONE", value: "ab|cd").split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(parts, ["v1", "st", appId, "TS1", "PHONE", "MOBILE", "ab|cd"])
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

    /// What `PostIntentUseCase` attaches when attestation is enabled.
    private func appAttestInfo(state: String) async -> [String: String] {
        let challenge = PostIntentUseCase.appAttestChallenge(challenge: state, tsId: Otpless.shared.tsid, requestBody: makeBody())
        return await AppAttestUseCase(platform: platform, store: store).assertionInfo(challenge: challenge, state: state)
    }

    private func sentJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(StubURLProtocol.lastBody, "no request reached the stub")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// What the server will do: parse the body it received, rebuild the canonical string from the
    /// fields it read, hash it. That must equal what Apple was asked to sign.
    func testSignedHashMatchesWhatTheServerRebuildsFromTheReceivedBody() async throws {
        StubURLProtocol.reset(responseJSON: "{}")

        _ = await makeRepository().postIntent(state: "st-123", body: makeBody(), appAttestInfo: await appAttestInfo(state: "st-123"))

        let json = try sentJSON()
        let rebuilt = ["v1", "st-123", json["appId"] as? String ?? "", json["tsId"] as? String ?? "",
                       json["channel"] as? String ?? "", json["identifierType"] as? String ?? "",
                       json["value"] as? String ?? ""].joined(separator: "|")
        XCTAssertEqual(try XCTUnwrap(platform.assertionCalls.first?.hash),
                       Data(SHA256.hash(data: Data(rebuilt.utf8))),
                       "the signed hash must equal SHA256 of the challenge rebuilt from the received body")
        XCTAssertTrue(rebuilt.hasSuffix("|PHONE|MOBILE|919999999999"), rebuilt)
    }

    func testIntentBodyCarriesTheInfoObject() async throws {
        StubURLProtocol.reset(responseJSON: "{}")

        _ = await makeRepository().postIntent(state: "st-9", body: makeBody(), appAttestInfo: await appAttestInfo(state: "st-9"))

        let json = try sentJSON()
        let info = try XCTUnwrap(json["appAttestInfo"] as? [String: String])
        XCTAssertEqual(info["status"], "ok")
        XCTAssertEqual(info["keyId"], "registered-key")
        XCTAssertEqual(info["assertion"], Data("the-assertion".utf8).base64EncodedString())
        XCTAssertEqual(info["challenge"], "st-9")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v3/lp/user/transaction/intent/st-9")
    }

    /// No headers any more: the whole thing lives in the body.
    func testNothingIsSentInHeaders() async throws {
        StubURLProtocol.reset(responseJSON: "{}")

        _ = await makeRepository().postIntent(state: "st-9", body: makeBody(), appAttestInfo: await appAttestInfo(state: "st-9"))

        let headers = try XCTUnwrap(StubURLProtocol.lastRequest).allHTTPHeaderFields ?? [:]
        XCTAssertTrue(headers.keys.allSatisfy { !$0.lowercased().contains("attest") }, "\(headers)")
    }

    /// Adding the object must not disturb any existing member of the intent body.
    func testExistingBodyMembersAreUntouched() async throws {
        StubURLProtocol.reset(responseJSON: "{}")
        _ = await makeRepository().postIntent(state: "st-1", body: makeBody())
        let without = try sentJSON()

        StubURLProtocol.reset(responseJSON: "{}")
        _ = await makeRepository().postIntent(state: "st-1", body: makeBody(), appAttestInfo: await appAttestInfo(state: "st-1"))
        let with = try sentJSON()

        XCTAssertEqual(Set(with.keys), Set(without.keys).union(["appAttestInfo"]))
        for (key, value) in without {
            XCTAssertEqual(comparable(with[key] ?? "<missing>"), comparable(value), "`\(key)` changed")
        }
    }

    /// A member can be a JSON document in a string (e.g. `metadata`) whose key order is not stable
    /// from one serialisation to the next; compare those by content, not by text.
    private func comparable(_ value: Any) -> String {
        guard let text = value as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return String(describing: value) }
        return String(decoding: canonical, as: UTF8.self)
    }

    /// Merchants without attestation must send the same body as before.
    func testNoInfoObjectWhenAttestationIsNotEnabled() async throws {
        StubURLProtocol.reset(responseJSON: "{}")

        _ = await makeRepository().postIntent(state: "st-1", body: makeBody())

        XCTAssertNil(try sentJSON()["appAttestInfo"])
    }

    /// Fail open: no assertion available still sends the intent, with a reason.
    func testIntentIsStillSentWhenNoAssertionCanBeProduced() async throws {
        StubURLProtocol.reset(responseJSON: "{}")
        store = FakeStore()                                        // nothing registered yet
        platform.configure(generateError: BoomError())             // and registering fails

        _ = await makeRepository().postIntent(state: "st-2", body: makeBody(), appAttestInfo: await appAttestInfo(state: "st-2"))

        XCTAssertNotNil(StubURLProtocol.lastRequest, "the intent must still go out")
        let info = try XCTUnwrap(try sentJSON()["appAttestInfo"] as? [String: String])
        XCTAssertEqual(info, ["status": "no_key"])
    }
}
