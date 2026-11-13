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

    private let rulesSample = """
    { "config_version": 12, "rules_hash": "r_9c41e0", "sms_template": "{token}",
      "rules": { "token_ttl": {"enabled": true, "seconds": 45},
                 "min_os": {"enabled": true, "android_api": 23, "ios": "17.0"},
                 "ios_upi_entitlement": {"enabled": true},
                 "ios_composer_return": {"enabled": true, "max_seconds": 30},
                 "ios_iccid_token": {"enabled": true} } }
    """

    private let startSample = """
    { "attempt_id": "att_7Qm2", "token": "k#7Qv:2Lm_9Xa+Rt=eP1.wZ*8sN-4bYh3uGcFdJ",
      "sms_body": "k#7Qv:2Lm_9Xa+Rt=eP1.wZ*8sN-4bYh3uGcFdJ", "vmn": "+919000000007",
      "issued_at": "2026-11-13T10:14:20.100Z", "expires_at": "2026-11-13T10:15:05.100Z",
      "server_time": "2026-11-13T10:14:20.103Z", "ttl_seconds": 45, "config_version": 12, "rules_hash": "r_9c41e0" }
    """

    private func request(_ rules: SmsBindingRules) -> SmsBindingStartRequest {
        SmsBindingStartRequest(
            msisdn: "+919812345621", osVersion: "26.7", appVersion: "3.2.0", sdkVersion: "3.2.0",
            deviceFingerprintHash: "fp", rules: rules, previousAttemptId: "att_0",
            upiEntitlementDeclared: true, iccidTokenSupported: true
        )
    }

    func testRulesSampleFromTheContractDecodes() async throws {
        SmsStubProtocol.reset(["/binding/sms/rules/s1": (200, rulesSample)])
        let rules = try await backend().fetchRules(state: "s1")
        XCTAssertEqual(rules.configVersion, 12)
        XCTAssertEqual(rules.composerReturnLimit, 30)
        XCTAssertTrue(rules.requiresIccidToken)
        XCTAssertEqual(SmsStubProtocol.recorded.first?.method, "GET")
        XCTAssertEqual(SmsStubProtocol.recorded.first?.path, "/v3/lp/user/binding/sms/rules/s1")
    }

    func testStartSampleFromTheContractDecodesAndTheRequestCarriesTheContractFields() async throws {
        SmsStubProtocol.reset(["/binding/sms/attempts/s1": (200, startSample)])
        let rules = try XCTUnwrap(SmsBindingRules.decode(Data(rulesSample.utf8)))

        let issued = try await backend().startAttempt(state: "s1", request: request(rules))

        XCTAssertEqual(issued.attemptId, "att_7Qm2")
        XCTAssertEqual(issued.vmn, "+919000000007")
        XCTAssertEqual(issued.ttlSeconds, 45)
        XCTAssertEqual(issued.smsBody, "k#7Qv:2Lm_9Xa+Rt=eP1.wZ*8sN-4bYh3uGcFdJ")

        let sent = try XCTUnwrap(SmsStubProtocol.recorded.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/v3/lp/user/binding/sms/attempts/s1")
        let body = try XCTUnwrap(sent.body)
        XCTAssertEqual(body["msisdn"] as? String, "+919812345621")
        XCTAssertEqual(body["device_platform"] as? String, "ios")
        XCTAssertEqual(body["platform"] as? String, "HEADLESS", "the standard SDK parameter must not be overwritten")
        XCTAssertEqual(body["previous_attempt_id"] as? String, "att_0")
        XCTAssertEqual(body["config_version"] as? Int, 12)
        XCTAssertEqual((body["capabilities"] as? [String: Any])?["upi_entitlement"] as? Bool, true)
        XCTAssertNotNil(body["appId"], "the standard SDK body parameters must still be sent")
    }

    func testReportGoesToTheAttemptPathWithTheContractShape() async throws {
        SmsStubProtocol.reset(["/report/s1": (200, "{}")])
        let report = SmsBindingReport(
            event: .sent, at: Date(timeIntervalSince1970: 1_800_000_000), reason: nil,
            ios: .init(composerResult: "sent", sendCompletion: true,
                       composerPresentedAt: Date(timeIntervalSince1970: 1_799_999_995),
                       appRegainedControlAt: Date(timeIntervalSince1970: 1_800_000_000),
                       returnSeconds: 5, iccidToken: "tok", iccidTokenStatus: "OK")
        )

        try await backend().report(state: "s1", attemptId: "att_7Qm2", report: report)

        let sent = try XCTUnwrap(SmsStubProtocol.recorded.first)
        XCTAssertEqual(sent.path, "/v3/lp/user/binding/sms/attempts/att_7Qm2/report/s1")
        XCTAssertEqual(sent.body?["event"] as? String, "SENT")
        let ios = try XCTUnwrap(sent.body?["ios"] as? [String: Any])
        XCTAssertEqual(ios["composer_result"] as? String, "sent")
        XCTAssertEqual(ios["send_completion"] as? Bool, true)
        XCTAssertEqual(ios["iccid_token"] as? String, "tok")
        XCTAssertEqual(ios["iccid_token_status"] as? String, "OK")
        XCTAssertEqual(ios["return_seconds"] as? Double, 5)
    }

    func testVerdictSampleDecodesAndTheQueryCarriesWaitAndSince() async throws {
        SmsStubProtocol.reset(["/result/s1": (200, #"{"attempt_id":"att_7Qm2","state":"VERIFIED","reason":null,"binding_id":"bnd_31Ke","state_version":4}"#)])

        let verdict = try await backend().verdict(state: "s1", attemptId: "att_7Qm2", sinceVersion: 3, waitSeconds: 20)

        XCTAssertEqual(verdict, SmsBindingVerdict(state: .verified, reason: nil, bindingId: "bnd_31Ke", stateVersion: 4))
        let sent = try XCTUnwrap(SmsStubProtocol.recorded.first)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.path, "/v3/lp/user/binding/sms/attempts/att_7Qm2/result/s1")
        XCTAssertTrue(sent.query.contains("wait=20"), sent.query)
        XCTAssertTrue(sent.query.contains("since=3"), sent.query)
    }

    func testABackendRefusalWithAReasonIsSurfacedWithItsRetryAfter() async throws {
        SmsStubProtocol.reset(["/attempts/s1": (403, #"{"message":"Blocked","errorCode":"7100","reason":"DEVICE_BLOCKED","retry_after_seconds":3600}"#)])
        let rules = try XCTUnwrap(SmsBindingRules.decode(Data(rulesSample.utf8)))
        do {
            _ = try await backend().startAttempt(state: "s1", request: request(rules))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SmsBindingBackendError, .rejected(.deviceBlocked, retryAfterSeconds: 3600))
        }
    }

    func testServerErrorsAndReasonlessFourHundredsAreTransport() async throws {
        let rules = try XCTUnwrap(SmsBindingRules.decode(Data(rulesSample.utf8)))
        for (status, body) in [(500, "{}"), (502, "oops"), (400, #"{"message":"Invalid Request","errorCode":"7006"}"#)] {
            SmsStubProtocol.reset(["/attempts/s1": (status, body)])
            do {
                _ = try await backend().startAttempt(state: "s1", request: request(rules))
                XCTFail("expected an error for \(status)")
            } catch {
                XCTAssertEqual(error as? SmsBindingBackendError, .transport, "status \(status)")
            }
        }
    }

    func testAnUndecodableSuccessIsTransportNotACrash() async throws {
        SmsStubProtocol.reset(["/attempts/s1": (200, #"{"unexpected":true}"#)])
        let rules = try XCTUnwrap(SmsBindingRules.decode(Data(rulesSample.utf8)))
        do {
            _ = try await backend().startAttempt(state: "s1", request: request(rules))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SmsBindingBackendError, .transport)
        }
    }
}
#endif
