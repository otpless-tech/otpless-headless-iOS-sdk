//
//  SmsBindingMockTests.swift
//  OtplessBMTests
//
//  Plays every mock scenario through the real orchestrator, and proves the live backend client
//  reads exactly the response shapes the mock returns (so going live is only a backend swap).
//

#if DEBUG
import XCTest
@testable import OtplessBM

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

// MARK: - Small fakes (the device side; the backend under test is the real mock)

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.locked { date } }
    func advance(_ seconds: TimeInterval) { lock.locked { date = date.addingTimeInterval(seconds) } }
}

private struct HealthyDevice: SmsBindingDevice {
    var osVersion = "26.7"
    var appVersion = "3.2.0"
    var hasCellularRadio = true
    var canSendText = true
}

private final class ScriptedComposer: SmsBindingComposer, @unchecked Sendable {
    private let clock: Clock
    var returnSeconds: TimeInterval
    var sendCompletion: Bool?
    private(set) var recipients: [String] = []
    private(set) var upiFlags: [Bool] = []
    private let lock = NSLock()

    init(clock: Clock, returnSeconds: TimeInterval, sendCompletion: Bool?) {
        self.clock = clock
        self.returnSeconds = returnSeconds
        self.sendCompletion = sendCompletion
    }

    func present(recipient: String, body: String, upiValidation: Bool) async -> SmsComposerOutcome {
        lock.locked { recipients.append(recipient); upiFlags.append(upiValidation) }
        let presented = clock.now
        clock.advance(returnSeconds)
        return SmsComposerOutcome(result: .sent, sendCompletion: sendCompletion, presentedAt: presented, returnedAt: clock.now)
    }
}

private struct TokenOK: IccidTokenProvider {
    func fetch() async -> IccidTokenResult { .token("t") }
}

// MARK: - Scenario table

final class SmsBindingMockScenarioTests: XCTestCase {

    private struct Expectation {
        let outcome: SmsBindingOutcome
        /// Seconds the user spends in the composer. Most scenarios use a quick send.
        var composerSeconds: TimeInterval = 3
        /// Whether the device is expected to reach the composer at all.
        var reachesComposer = true
    }

    private static let expectations: [OtplessSmsBindingMockScenario: Expectation] = [
        .verifiedNpci: Expectation(outcome: .verified(bindingId: "bnd_mock_npci")),
        .verifiedStandard: Expectation(outcome: .verified(bindingId: "bnd_mock_standard")),
        .slowVerdict: Expectation(outcome: .verified(bindingId: "bnd_mock_slow")),
        .reportFails: Expectation(outcome: .verified(bindingId: "bnd_mock_report")),
        .pollFlaky: Expectation(outcome: .verified(bindingId: "bnd_mock_flaky")),

        .upgradeRequired: Expectation(outcome: .failed(.upgradeRequired), reachesComposer: false),
        .osTooOld: Expectation(outcome: .failed(.upgradeRequired), reachesComposer: false),

        .deviceBlockedAtStart: Expectation(outcome: .failed(.deviceBlocked), reachesComposer: false),
        .vmnPoolUnavailable: Expectation(outcome: .failed(.vmnPoolUnavailable), reachesComposer: false),
        .rulesUnavailable: Expectation(outcome: .failed(.internalError), reachesComposer: false),
        .startTransportError: Expectation(outcome: .failed(.internalError), reachesComposer: false),

        .numberMismatch: Expectation(outcome: .failed(.numberMismatch)),
        .rejectedUnknownReason: Expectation(outcome: .failed(.verificationFailed)),
        .tokenExpiredVerdict: Expectation(outcome: .failed(.tokenExpired)),
        .abortedVerdict: Expectation(outcome: .failed(.sessionInterrupted)),
        .neverCompletes: Expectation(outcome: .failed(.tokenExpired)),

        .shortTtl: Expectation(outcome: .failed(.tokenExpired), composerSeconds: 10),
        .strictComposerReturn: Expectation(outcome: .failed(.tokenExpired), composerSeconds: 10)
    ]

    func testEveryScenarioHasAnExpectation() {
        let missing = OtplessSmsBindingMockScenario.allCases.filter { Self.expectations[$0] == nil }
        XCTAssertTrue(missing.isEmpty, "add an expectation for: \(missing.map(\.rawValue))")
    }

    func testEveryScenarioPlaysOutAsScripted() async {
        for scenario in OtplessSmsBindingMockScenario.allCases {
            let expected = try! XCTUnwrap(Self.expectations[scenario])
            let clock = Clock()
            let backend = MockSmsBindingBackend(
                scenario: scenario, vmn: "+910000000001",
                sleep: { seconds in clock.advance(seconds) }
            )
            // NPCI scenarios use the entitlement composer, whose completion Apple fires with true.
            let composer = ScriptedComposer(
                clock: clock, returnSeconds: expected.composerSeconds,
                sendCompletion: scenario == .verifiedNpci ? true : nil
            )
            let useCase = SmsBindingUseCase(
                backend: backend, composer: composer, iccid: TokenOK(), device: HealthyDevice(),
                sdkVersion: "3.2.0", now: { clock.now }, sleep: { clock.advance($0) }
            )

            let outcome = await useCase.run(
                state: "state-1", msisdn: "+919812345621",
                upiEntitlementDeclared: scenario == .verifiedNpci
            )

            XCTAssertEqual(outcome, expected.outcome, "scenario \(scenario.rawValue)")
            XCTAssertEqual(
                composer.recipients.isEmpty, !expected.reachesComposer,
                "scenario \(scenario.rawValue): composer reached = \(!composer.recipients.isEmpty)"
            )
            if expected.reachesComposer {
                XCTAssertEqual(composer.recipients, ["+910000000001"], "the SMS goes to the configured number")
            }
        }
    }

    func testNpciScenarioUsesTheEntitlementComposerAndStandardDoesNot() async {
        for (scenario, upi) in [(OtplessSmsBindingMockScenario.verifiedNpci, true), (.verifiedStandard, false)] {
            let clock = Clock()
            let composer = ScriptedComposer(clock: clock, returnSeconds: 3, sendCompletion: upi ? true : nil)
            let useCase = SmsBindingUseCase(
                backend: MockSmsBindingBackend(scenario: scenario, vmn: "+910000000001", sleep: { clock.advance($0) }),
                composer: composer, iccid: TokenOK(), device: HealthyDevice(),
                now: { clock.now }, sleep: { clock.advance($0) }
            )
            _ = await useCase.run(state: "s", msisdn: "+919812345621", upiEntitlementDeclared: upi)
            XCTAssertEqual(composer.upiFlags, [upi], "\(scenario.rawValue)")
        }
    }
}

// MARK: - Live client reads the shapes the mock returns

private final class SmsStubProtocol: URLProtocol {
    struct Recorded { let method: String; let path: String; let query: String; let body: [String: Any]? }
    private static let lock = NSLock()
    private static var _responses: [String: (Int, String)] = [:]
    private static var _recorded: [Recorded] = []

    static func reset(_ responses: [String: (Int, String)]) {
        lock.locked { _responses = responses; _recorded = [] }
    }
    static var recorded: [Recorded] { lock.locked { _recorded } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body: [String: Any]?
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else if let data = request.httpBody {
            body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let path = request.url?.path ?? ""
        let answer: (Int, String) = SmsStubProtocol.lock.locked {
            SmsStubProtocol._recorded.append(Recorded(
                method: request.httpMethod ?? "", path: path, query: request.url?.query ?? "", body: body
            ))
            return SmsStubProtocol._responses.first { path.hasSuffix($0.key) }?.value ?? (404, "{}")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SmsBindingLiveContractTests: XCTestCase {

    private func backend() -> LiveSmsBindingBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SmsStubProtocol.self]
        return LiveSmsBindingBackend(apiManager: ApiManager(
            userAuthTimeout: 5, snaTimeout: 5, enableLogging: false, session: URLSession(configuration: configuration)
        ))
    }

    /// The backend's own sample of the intent response, with the iOS rules added (the sample
    /// listed only the Android ones; the iOS rule names are the PRD's and still to be confirmed).
    private let intentSample = """
    { "quantumLeap": {
        "state": "s1", "channelAuthToken": "5f535be8f72a4a96ac08542d5dc462c8",
        "uid": "C0AD4A1514C54377AA7CCC1DFDC2D3D0", "channel": "SIM_BINDING", "channels": ["SIM_BINDING"],
        "asId": "6582052C63164E7F8DB2CF74A2F4D523", "communicationMode": "OUTBOUND_SMS,SMS",
        "status": "PENDING", "timerSettings": { "interval": 1500, "timeout": 120000 }, "pollingRequired": true,
        "simBinding": {
          "token": "5f535be8f72a4a96ac08542d5dc462c8", "vmn": "+919000000007",
          "smsBody": "k#7Qv:2Lm_9Xa+Rt=eP1.wZ*8sN-4bYh3uGcFdJ",
          "expiresAt": 1763436122, "expiresInSeconds": 120, "rulesHash": "8f3a1c",
          "rules": { "token_ttl": {"enabled": true, "seconds": 120},
                     "android_silent_send": {"enabled": true},
                     "ios_upi_entitlement": {"enabled": true},
                     "ios_composer_return": {"enabled": true, "max_seconds": 30},
                     "ios_iccid_token": {"enabled": true} } } } }
    """

    private func request() -> SmsBindingStartRequest {
        SmsBindingStartRequest(
            msisdn: "+919812345621", countryCode: "+91", osVersion: "26.7", appVersion: "3.2.0", sdkVersion: "3.2.0",
            deviceFingerprintHash: "fp", previousAttemptId: "att_0",
            upiEntitlementDeclared: true, iccidTokenSupported: true, planStatusSupported: false
        )
    }

    // MARK: Start (the intent call)

    func testIntentResponseGivesTheTokenTheNumberTheMessageAndTheRules() async throws {
        SmsStubProtocol.reset(["/intent/s1": (200, intentSample)])

        let started = try await backend().startAttempt(state: "s1", request: request())

        XCTAssertEqual(started.issued.attemptId, "5f535be8f72a4a96ac08542d5dc462c8", "the token identifies the attempt")
        XCTAssertEqual(started.issued.vmn, "+919000000007")
        XCTAssertEqual(started.issued.smsBody, "k#7Qv:2Lm_9Xa+Rt=eP1.wZ*8sN-4bYh3uGcFdJ")
        XCTAssertEqual(started.issued.ttlSeconds, 120)
        XCTAssertEqual(started.rules.rulesHash, "8f3a1c")
        XCTAssertTrue(started.rules.isOn(.tokenTTL))
        XCTAssertEqual(started.rules.int(.tokenTTL, "seconds"), 120)
        XCTAssertTrue(started.rules.requiresUpiEntitlement)
        XCTAssertEqual(started.rules.composerReturnLimit, 30)
        XCTAssertTrue(started.rules.requiresIccidToken)
    }

    func testTheIntentRequestIsAPhoneIntentCarryingTheSimBindingBlock() async throws {
        SmsStubProtocol.reset(["/intent/s1": (200, intentSample)])
        _ = try await backend().startAttempt(state: "s1", request: request())

        let sent = try XCTUnwrap(SmsStubProtocol.recorded.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/v3/lp/user/transaction/intent/s1")
        let body = try XCTUnwrap(sent.body)
        XCTAssertEqual(body["channel"] as? String, "OTP")
        XCTAssertEqual(body["type"] as? String, "INPUT")
        XCTAssertEqual(body["identifierType"] as? String, "MOBILE")
        XCTAssertEqual(body["value"] as? String, "9812345621", "the national number")
        XCTAssertEqual(body["selectedCountryCode"] as? String, "+91")
        XCTAssertEqual(body["mobile"] as? String, "919812345621", "country code and number, as every other phone intent sends it")
        XCTAssertEqual(body["silentAuthEnabled"] as? Bool, false, "this is not a silent-auth attempt")
        XCTAssertNotNil(body["appId"], "the standard SDK body parameters must still be sent")

        let sim = try XCTUnwrap(body["simBinding"] as? [String: Any])
        XCTAssertEqual(sim["platform"] as? String, "IOS")
        XCTAssertEqual(sim["osVersion"] as? String, "26.7")
        XCTAssertEqual(sim["appVersion"] as? String, "3.2.0")
        XCTAssertEqual(sim["deviceFingerprint"] as? String, "fp")
        XCTAssertEqual(sim["upiEntitlement"] as? Bool, true)
        XCTAssertEqual(sim["iccidTokenSupported"] as? Bool, true)
        XCTAssertEqual(sim["planStatusSupported"] as? Bool, false)
        XCTAssertEqual(sim["previousAttemptId"] as? String, "att_0")
        XCTAssertNil(sim["apiLevel"], "Android only")
        XCTAssertNil(sim["sim"], "Android only")
    }

    func testAnIntentThatDidNotBecomeSimBindingIsNotAvailable() async throws {
        let otpOnly = #"{"quantumLeap":{"state":"s1","channelAuthToken":"t","channel":"OTP","channels":["OTP"],"asId":"a","status":"PENDING","timerSettings":{},"pollingRequired":true}}"#
        SmsStubProtocol.reset(["/intent/s1": (200, otpOnly)])
        do {
            _ = try await backend().startAttempt(state: "s1", request: request())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SmsBindingBackendError, .rejected(.notAvailable, retryAfterSeconds: nil))
        }
    }

    func testStartRefusalsAndFailures() async throws {
        let cases: [(Int, String, SmsBindingBackendError)] = [
            (403, #"{"message":"Blocked","errorCode":"7100","reason":"DEVICE_BLOCKED","retry_after_seconds":3600}"#,
             .rejected(.deviceBlocked, retryAfterSeconds: 3600)),
            (403, #"{"message":"No number","errorCode":"7101","errorDetails":"VMN_POOL_UNAVAILABLE"}"#,
             .rejected(.vmnPoolUnavailable, retryAfterSeconds: nil)),
            (500, "{}", .transport),
            (502, "oops", .transport),
            (400, #"{"message":"Invalid Request","errorCode":"7006"}"#, .transport)
        ]
        for (status, body, expected) in cases {
            SmsStubProtocol.reset(["/intent/s1": (status, body)])
            do {
                _ = try await backend().startAttempt(state: "s1", request: request())
                XCTFail("expected an error for \(status)")
            } catch {
                XCTAssertEqual(error as? SmsBindingBackendError, expected, "status \(status)")
            }
        }
    }

    func testAnUndecodableOrIncompleteSuccessIsTransportNotACrash() async throws {
        for body in [#"{"unexpected":true}"#, #"{"quantumLeap":{"channel":"SIM_BINDING","simBinding":{"token":"t"}}}"#] {
            SmsStubProtocol.reset(["/intent/s1": (200, body)])
            do {
                _ = try await backend().startAttempt(state: "s1", request: request())
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? SmsBindingBackendError, .transport)
            }
        }
    }

    // MARK: Report

    func testReportCarriesTheTokenAndTheSimBindingBlock() async throws {
        SmsStubProtocol.reset(["/sim-binding-report/s1": (200, #"{"status":"SENT","expiresAt":1763436122,"platform":"IOS"}"#)])
        let report = SmsBindingReport(
            event: .sent, at: Date(timeIntervalSince1970: 1_800_000_000), reason: nil,
            ios: .init(composerResult: "sent", sendCompletion: true,
                       composerPresentedAt: Date(timeIntervalSince1970: 1_799_999_995),
                       appRegainedControlAt: Date(timeIntervalSince1970: 1_800_000_000),
                       returnSeconds: 5, iccidToken: "tok", iccidTokenStatus: "OK")
        )

        try await backend().report(state: "s1", attemptId: "5f535be8", report: report)

        let sent = try XCTUnwrap(SmsStubProtocol.recorded.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/v3/lp/user/transaction/sim-binding-report/s1")
        XCTAssertEqual(sent.body?["token"] as? String, "5f535be8")
        let sim = try XCTUnwrap(sent.body?["simBinding"] as? [String: Any])
        XCTAssertEqual(sim["event"] as? String, "SENT")
        XCTAssertEqual(sim["sentAck"] as? String, "RESULT_OK")
        XCTAssertEqual(sim["sentAt"] as? Int, 1_800_000_000_000, "milliseconds, as Android sends it")
        let ios = try XCTUnwrap(sim["ios"] as? [String: Any])
        XCTAssertEqual(ios["composerResult"] as? String, "sent")
        XCTAssertEqual(ios["sendCompletion"] as? Bool, true)
        XCTAssertEqual(ios["iccidToken"] as? String, "tok")
        XCTAssertEqual(ios["iccidTokenStatus"] as? String, "OK")
        XCTAssertEqual(ios["returnSeconds"] as? Double, 5)
    }

    func testAnEndReportHasAReasonAndNoSentAck() throws {
        let dict = SmsBindingReport(event: .aborted, at: Date(timeIntervalSince1970: 1), reason: .sessionInterrupted, ios: nil).toDict()
        XCTAssertEqual(dict["event"] as? String, "ABORTED")
        XCTAssertEqual(dict["reason"] as? String, "SESSION_INTERRUPTED")
        XCTAssertNil(dict["sentAck"], "nothing was sent")
        XCTAssertNil(dict["ios"])
    }

    // MARK: Status poll

    func testStatusPendingMeansWaiting() async throws {
        SmsStubProtocol.reset(["/sim-binding-status/s1/tok": (200, #"{"authDetail":{"status":"PENDING"}}"#)])
        let verdict = try await backend().verdict(state: "s1", attemptId: "tok", sinceVersion: nil, waitSeconds: 20)
        XCTAssertEqual(verdict.state, .sent)
        let sent = try XCTUnwrap(SmsStubProtocol.recorded.first)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.path, "/v3/lp/user/transaction/sim-binding-status/s1/tok")
    }

    func testStatusSuccessIsVerifiedAndCarriesTheAuthToken() async throws {
        let success = #"{"authDetail":{"status":"SUCCESS","token":"auth-token","channel":"SIM_BINDING","asId":"a"},"config":{},"oneTap":{}}"#
        SmsStubProtocol.reset(["/sim-binding-status/s1/tok": (200, success)])
        let verdict = try await backend().verdict(state: "s1", attemptId: "tok", sinceVersion: nil, waitSeconds: 20)
        XCTAssertEqual(verdict.state, .verified)
        XCTAssertEqual(verdict.bindingId, "auth-token")
    }

    func testStatusFailedCarriesTheErrorCodeAsTheReason() async throws {
        let failed = #"{"authDetail":{"status":"FAILED","channel":"SIM_BINDING","errorCode":"NUMBER_MISMATCH","errorDetails":"NUMBER_MISMATCH"}}"#
        SmsStubProtocol.reset(["/sim-binding-status/s1/tok": (200, failed)])
        let verdict = try await backend().verdict(state: "s1", attemptId: "tok", sinceVersion: nil, waitSeconds: 20)
        XCTAssertEqual(verdict.state, .rejected)
        XCTAssertEqual(verdict.reason, "NUMBER_MISMATCH")
        XCTAssertEqual(SmsBindingFailure(backendReason: verdict.reason), .numberMismatch)
    }

    func testAnExpiredAttemptAnswersWithAnErrorAndIsReadAsExpired() async throws {
        SmsStubProtocol.reset(["/sim-binding-status/s1/tok": (400, #"{"errorCode":"7011","message":"Transaction expired"}"#)])
        let verdict = try await backend().verdict(state: "s1", attemptId: "tok", sinceVersion: nil, waitSeconds: 20)
        XCTAssertEqual(verdict.state, .expired)
    }

    func testAServerErrorOrAnUnknownStatusIsTransportSoThePollCarriesOn() async throws {
        for (status, body) in [(500, "{}"), (200, #"{"authDetail":{"status":"SOMETHING_NEW"}}"#), (200, #"{"x":1}"#)] {
            SmsStubProtocol.reset(["/sim-binding-status/s1/tok": (status, body)])
            do {
                _ = try await backend().verdict(state: "s1", attemptId: "tok", sinceVersion: nil, waitSeconds: 20)
                XCTFail("expected an error for \(status) \(body)")
            } catch {
                XCTAssertEqual(error as? SmsBindingBackendError, .transport)
            }
        }
    }
}
#endif
