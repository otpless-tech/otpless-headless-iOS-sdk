//
//  SmsBindingLiveContractTests.swift
//  OtplessBMTests
//
//  The live backend client against the backend's own sample responses (served by a stub URL
//  protocol): the intent, the report and the status poll. The device and the network are not involved.
//

import XCTest
@testable import OtplessBM

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

// MARK: - The live client against the backend's responses

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
        XCTAssertEqual(body["mobile"] as? String, "919812345621", "country code and number: staging rejected the national number alone (7102)")
        XCTAssertEqual(body["sdkPlatform"] as? String, "IOS")
        XCTAssertEqual(body["silentAuthEnabled"] as? Bool, false, "this is not a silent-auth attempt")
        XCTAssertNotNil(body["appId"], "the standard SDK body parameters must still be sent")

        let sim = try XCTUnwrap(body["simBinding"] as? [String: Any])
        XCTAssertEqual(sim["platform"] as? String, "IOS")
        XCTAssertEqual(sim["osVersion"] as? String, "26.7")
        XCTAssertEqual(sim["appVersion"] as? String, "3.2.0")
        XCTAssertEqual(sim["deviceFingerprint"] as? String, "fp")
        XCTAssertEqual(Set(sim.keys), ["platform", "osVersion", "appVersion", "deviceFingerprint"],
                       "only the fields the backend defines for iOS")
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
            // The backend's own numeric codes (otpless-common ErrorConstant), with no reason name.
            (429, #"{"message":"SIM binding attempt limit reached for this device. Please try again later.","errorCode":"7184"}"#,
             .rejected(.deviceBlocked, retryAfterSeconds: nil)),
            (400, #"{"message":"Request error: No eligible number available for SIM binding.","errorCode":"7185"}"#,
             .rejected(.vmnPoolUnavailable, retryAfterSeconds: nil)),
            (400, #"{"message":"Request error: App version is below the minimum required for SIM binding.","errorCode":7186}"#,
             .rejected(.upgradeRequired, retryAfterSeconds: nil)),
            (400, #"{"message":"Invalid Request","errorCode":"7102","description":"Request error: Invalid phone number"}"#,
             .rejected(.invalidPhoneNumber, retryAfterSeconds: nil)),
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
        XCTAssertEqual(Set(sim.keys), ["sentAt", "composerReturnedAt"], "the backend's iOS shape, nothing more")
        XCTAssertEqual(sim["sentAt"] as? Int, 1_799_999_995_000, "when the composer went up, in milliseconds")
        XCTAssertEqual(sim["composerReturnedAt"] as? Int, 1_800_000_000_000, "when the app got control back")
        XCTAssertNil(sim["sentAck"], "Android only")
    }

    func testAnEndReportHasAReasonAndNoSentAck() throws {
        let dict = SmsBindingReport(event: .aborted, at: Date(timeIntervalSince1970: 1), reason: .sessionInterrupted, ios: nil).toDict()
        XCTAssertEqual(dict.keys.sorted(), ["aborted"])
        XCTAssertEqual(dict["aborted"] as? Bool, true)
        for event in [SmsBindingReport.Event.failed, .cancelled] {
            let other = SmsBindingReport(event: event, at: Date(timeIntervalSince1970: 1), reason: .smsSendFailed, ios: nil).toDict()
            XCTAssertEqual(other.keys.sorted(), ["aborted"], "\(event) ends the attempt the same way")
        }
    }

    // MARK: Status poll

    func testStatusPendingMeansWaiting() async throws {
        SmsStubProtocol.reset(["/status/s1": (200, #"{"authDetail":{"status":"PENDING"}}"#)])
        let verdict = try await backend().verdict(state: "s1", attemptId: "tok", sinceVersion: nil, waitSeconds: 20)
        XCTAssertEqual(verdict.state, .sent)
        let sent = try XCTUnwrap(SmsStubProtocol.recorded.first)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.path, "/v3/lp/user/transaction/status/s1", "the general status API")
        XCTAssertTrue(sent.query.contains("token=tok"), "the token is a query parameter: \(sent.query)")
    }

    func testStatusSuccessIsVerifiedAndCarriesTheAuthToken() async throws {
        let success = #"{"authDetail":{"status":"SUCCESS","token":"auth-token","channel":"SIM_BINDING","asId":"a","user":{"mobile":"919812345621","uid":"u-1"}},"config":{},"oneTap":{}}"#
        SmsStubProtocol.reset(["/status/s1": (200, success)])
        let verdict = try await backend().verdict(state: "s1", attemptId: "tok", sinceVersion: nil, waitSeconds: 20)
        XCTAssertEqual(verdict.state, .verified)
        XCTAssertEqual(verdict.bindingId, "auth-token")
        XCTAssertEqual(verdict.mobile, "919812345621", "who was verified")
        XCTAssertEqual(verdict.userId, "u-1")
    }

    func testStatusFailedCarriesTheErrorCodeAsTheReason() async throws {
        let failed = #"{"authDetail":{"status":"FAILED","channel":"SIM_BINDING","errorCode":"NUMBER_MISMATCH","errorDetails":"NUMBER_MISMATCH"}}"#
        SmsStubProtocol.reset(["/status/s1": (200, failed)])
        let verdict = try await backend().verdict(state: "s1", attemptId: "tok", sinceVersion: nil, waitSeconds: 20)
        XCTAssertEqual(verdict.state, .rejected)
        XCTAssertEqual(verdict.reason, "NUMBER_MISMATCH")
        XCTAssertEqual(SmsBindingFailure(backendReason: verdict.reason), .numberMismatch)
    }

    func testAnExpiredAttemptAnswersWithAnErrorAndIsReadAsExpired() async throws {
        SmsStubProtocol.reset(["/status/s1": (400, #"{"errorCode":"7011","message":"Transaction expired"}"#)])
        let verdict = try await backend().verdict(state: "s1", attemptId: "tok", sinceVersion: nil, waitSeconds: 20)
        XCTAssertEqual(verdict.state, .expired)
    }

    func testAServerErrorOrAnUnknownStatusIsTransportSoThePollCarriesOn() async throws {
        for (status, body) in [(500, "{}"), (200, #"{"authDetail":{"status":"SOMETHING_NEW"}}"#), (200, #"{"x":1}"#)] {
            SmsStubProtocol.reset(["/status/s1": (status, body)])
            do {
                _ = try await backend().verdict(state: "s1", attemptId: "tok", sinceVersion: nil, waitSeconds: 20)
                XCTFail("expected an error for \(status) \(body)")
            } catch {
                XCTAssertEqual(error as? SmsBindingBackendError, .transport)
            }
        }
    }
}
