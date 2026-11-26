//
//  SmsBindingMainFlowTests.swift
//  OtplessBMTests
//
//  SMS binding inside the normal login flow: the backend answers a normal intent as SIM_BINDING.
//  Found on a device: the main flow did not know the channel, read the timer (milliseconds) as seconds,
//  polled nothing and opened no message screen, so the login hung.
//

import XCTest
@testable import OtplessBM

/// A real SIM_BINDING intent response, as staging sent it (token shortened, rules trimmed).
private let simBindingIntent = """
{"quantumLeap":{"state":"s1","channelAuthToken":"c8826741741c44bf973ab8764c899451","uid":"U1","channel":"SIM_BINDING",
 "channels":["SIM_BINDING"],"asId":"A1","communicationMode":"OUTBOUND_SMS","status":"PENDING",
 "timerSettings":{"interval":1500,"timeout":120000},"pollingRequired":true,
 "simBinding":{"token":"c8826741741c44bf973ab8764c899451","vmn":"+917065888859",
   "smsBody":"please send the message p.9vxGXL3V7#Tr7M","expiresAt":1795106489,"expiresInSeconds":120,"rulesHash":"67ce9f",
   "rules":{"token_ttl":{"enabled":true,"seconds":120},"ios_composer_return":{"enabled":true,"max_seconds":30},
            "single_session":{"enabled":false},"attempt_limit":{"enabled":true,"max":5,"window_h":24,"block_h":6},
            "ios_upi_entitlement":{"enabled":false}}}}}
"""

private let otpIntent = """
{"quantumLeap":{"otpLength":4,"state":"s1","channelAuthToken":"t","uid":"U1","channel":"OTP","channels":["OTP"],"asId":"A1",
 "status":"PENDING","timerSettings":{"interval":3,"timeout":60},"pollingRequired":true,"communicationMode":"WHATSAPP"}}
"""

final class SmsBindingMainFlowParsingTests: XCTestCase {

    private func intent(_ json: String) throws -> IntentResponse {
        try JSONDecoder().decode(IntentResponse.self, from: Data(json.utf8))
    }

    func testASimBindingIntentCarriesTheTokenTheNumberTheMessageAndTheRules() throws {
        let response = try intent(simBindingIntent)
        XCTAssertEqual(response.quantumLeap.channel, "SIM_BINDING")
        guard case .started(let started) = SmsBindingStarted.parse(quantumLeap: response.quantumLeap.simBindingDictionary()) else {
            return XCTFail("expected a started attempt")
        }
        XCTAssertEqual(started.issued.attemptId, "c8826741741c44bf973ab8764c899451")
        XCTAssertEqual(started.issued.vmn, "+917065888859")
        XCTAssertEqual(started.issued.smsBody, "please send the message p.9vxGXL3V7#Tr7M")
        XCTAssertEqual(started.issued.ttlSeconds, 120)
        // Whole numbers in the rules read as integers, whatever the JSON decoder made of them.
        XCTAssertEqual(started.rules.int(.tokenTTL, "seconds"), 120)
        XCTAssertEqual(started.rules.composerReturnLimit, 30)
        XCTAssertEqual(started.rules.attemptBlockHours, 6)
        XCTAssertFalse(started.rules.isOn(.singleSession))
        XCTAssertFalse(started.rules.requiresUpiEntitlement)
    }

    func testAnOtpIntentIsNotSimBindingAndStillDecodes() throws {
        let response = try intent(otpIntent)
        XCTAssertNil(response.quantumLeap.simBinding)
        guard case .notSimBinding = SmsBindingStarted.parse(quantumLeap: response.quantumLeap.simBindingDictionary()) else {
            return XCTFail("OTP is not SIM binding")
        }
    }

    func testASimBindingIntentMissingWhatTheFlowNeedsIsMalformed() throws {
        let noMessage = simBindingIntent.replacingOccurrences(of: #""smsBody":"please send the message p.9vxGXL3V7#Tr7M","#, with: "")
        let response = try intent(noMessage)
        guard case .malformed = SmsBindingStarted.parse(quantumLeap: response.quantumLeap.simBindingDictionary()) else {
            return XCTFail("expected malformed")
        }
    }

    /// What staging sent once the backend started checking the rules itself: no `rules`, no `rulesHash`, and
    /// no token inside `simBinding` (the token is the top-level `channelAuthToken`).
    func testASimBindingIntentWithNoRulesStillRuns() throws {
        let noRules = """
        {"quantumLeap":{"state":"s1","channelAuthToken":"755822caab2d4dcb85b2ad03e21be121","uid":"U1","channel":"SIM_BINDING",
         "channels":["SIM_BINDING"],"asId":"A1","communicationMode":"OUTBOUND_SMS","status":"PENDING",
         "timerSettings":{"interval":1500,"timeout":120000},"pollingRequired":true,
         "simBinding":{"vmn":"+917065888859","smsBody":"please send the message SUNbX4qIoy0+=NN=.cf65upXIQkNTQiiH9xu.Xh2","expiresAt":1795191221,"expiresInSeconds":120}}}
        """
        let response = try intent(noRules)
        guard case .started(let started) = SmsBindingStarted.parse(quantumLeap: response.quantumLeap.simBindingDictionary()) else {
            return XCTFail("a response without rules must still start the flow")
        }
        XCTAssertEqual(started.issued.attemptId, "755822caab2d4dcb85b2ad03e21be121")
        XCTAssertEqual(started.issued.vmn, "+917065888859")
        XCTAssertEqual(started.issued.ttlSeconds, 120)
        XCTAssertFalse(started.rules.isOn(.singleSession), "an absent rule is off")
        XCTAssertFalse(started.rules.requiresUpiEntitlement)
        XCTAssertNil(started.rules.minimumAppVersion)
    }

    func testWithNoRulesTheDeviceStillNeedsToBeAbleToSendAText() {
        struct Phone: SmsBindingDevice {
            var osVersion = "26.0"; var appVersion = "1.0"; var hasCellularRadio = true; var canSendText: Bool
        }
        let none = SmsBindingRules.decodeInline(rules: [:], rulesHash: nil)
        XCTAssertNil(SmsBindingPrechecks.evaluate(rules: none, device: Phone(canSendText: true), upiEntitlementDeclared: false))
        XCTAssertEqual(SmsBindingPrechecks.evaluate(rules: none, device: Phone(canSendText: false), upiEntitlementDeclared: false), .noSim)
    }

    func testTheIntentUseCaseHandsASimBindingResponseToTheSmsFlowAndDoesNotPoll() throws {
        let result = PostIntentUseCase(others: Otpless.shared).parseSimBindingResponse(try intent(simBindingIntent))
        XCTAssertNotNil(result.smsBindingStart)
        XCTAssertFalse(result.isPollingRequired, "the generic poll would read 1500 ms as 1500 s")
        XCTAssertFalse(result.isSNA)
        XCTAssertEqual(result.tokenAsIdUIdAndTimerSettings?.token, "c8826741741c44bf973ab8764c899451")
        XCTAssertEqual(result.otplessResponse?.response?["authType"] as? String, "SIM_BINDING")
        XCTAssertEqual(result.otplessResponse?.response?["deliveryChannel"] as? String, "OUTBOUND_SMS")
    }

    func testAMalformedSimBindingResponseFailsAtOnceInsteadOfHanging() throws {
        let broken = simBindingIntent.replacingOccurrences(of: #""vmn":"+917065888859","#, with: "")
        let result = PostIntentUseCase(others: Otpless.shared).parseSimBindingResponse(try intent(broken))
        XCTAssertNil(result.smsBindingStart)
        XCTAssertFalse(result.isPollingRequired)
        XCTAssertEqual(result.otplessResponse?.response?["errorCode"] as? String, "SIM_BINDING_NOT_AVAILABLE")
        XCTAssertEqual(result.otplessResponse?.responseType, .INITIATE)
    }
}

final class SmsBindingMainFlowResultTests: XCTestCase {

    private let success = """
    {"authDetail":{"status":"SUCCESS","token":"tok","channel":"SIM_BINDING","asId":"a","communicationDelivered":false,
       "user":{"mobile":"919812345621","uid":"u1"}},
     "oneTap":{"status":"SUCCESS","token":"session-token","sessionInfo":{"sessionToken":"s1","sessionId":"sid"}}}
    """

    func testASuccessIsALoginWithTheSession() throws {
        let response = SmsBindingMainFlow.response(for: .verified(bindingId: "tok", mobile: "919812345621", userId: "u1", payload: Data(success.utf8)))
        XCTAssertEqual(response.responseType, .ONETAP)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.response?["token"] as? String, "session-token")
        XCTAssertEqual((response.response?["sessionInfo"] as? [String: String])?["sessionToken"], "s1")
    }

    func testASuccessWithoutASessionIsAnErrorNotAHalfLogin() {
        let noSession = #"{"authDetail":{"status":"SUCCESS","token":"tok","communicationDelivered":false}}"#
        for payload in [Data(noSession.utf8), nil] as [Data?] {
            let response = SmsBindingMainFlow.response(for: .verified(bindingId: "tok", payload: payload))
            XCTAssertEqual(response.responseType, .VERIFY)
            XCTAssertEqual(response.response?["errorCode"] as? String, "INTERNAL_ERROR")
        }
    }

    func testAFailureIsShapedLikeTheOtherVerifyErrors() {
        let slow = SmsBindingMainFlow.response(for: .failed(.tokenExpired))
        XCTAssertEqual(slow.responseType, .VERIFY)
        XCTAssertEqual(slow.statusCode, 400)
        XCTAssertEqual(slow.response?["errorCode"] as? String, "TOKEN_EXPIRED")
        XCTAssertEqual(slow.response?["authType"] as? String, "SIM_BINDING")
        XCTAssertEqual(slow.response?["retryable"] as? Bool, true)
        XCTAssertFalse((slow.response?["errorMessage"] as? String ?? "").isEmpty)

        let noSim = SmsBindingMainFlow.response(for: .failed(.noSim))
        XCTAssertEqual(noSim.response?["retryable"] as? Bool, false)
    }

    func testTheMessageLeavingThePhoneIsReportedLikeAnotherChannelDelivering() {
        let delivered = SmsBindingMainFlow.deliveredResponse
        XCTAssertEqual(delivered.responseType, .DELIVERY_STATUS)
        XCTAssertEqual(delivered.response?["deliveryChannel"] as? String, "OUTBOUND_SMS")
        XCTAssertEqual(delivered.response?["authType"] as? String, "SIM_BINDING")
        XCTAssertEqual(delivered.response?["communicationDelivered"] as? Bool, true)
    }

    func testTheNumberComesFromTheRequestAndAnEmailRequestHasNone() {
        XCTAssertEqual(SmsBindingMainFlow.e164(countryCode: "+91", phoneNumber: "8980994455"), "+918980994455")
        XCTAssertEqual(SmsBindingMainFlow.e164(countryCode: "91", phoneNumber: "8980994455"), "+918980994455")
        XCTAssertNil(SmsBindingMainFlow.e164(countryCode: nil, phoneNumber: nil), "an email request")
        XCTAssertNil(SmsBindingMainFlow.e164(countryCode: "+91", phoneNumber: ""))
    }
}

/// Found on a device: SNA failed and its status call named SIM binding as the next channel, but the main
/// flow polled it like any other channel and nothing happened.
final class SmsBindingAfterSnaTests: XCTestCase {

    private let simBindingNext = """
    {"authDetail":{"status":"FAILED","communicationDelivered":false,"channel":"SILENT_AUTH"},
     "quantumLeap":{"state":"s1","channelAuthToken":"c8826741741c44bf973ab8764c899451","uid":"U1","channel":"SIM_BINDING",
      "channels":["SIM_BINDING"],"asId":"A1","communicationMode":"OUTBOUND_SMS","status":"PENDING",
      "timerSettings":{"interval":1500,"timeout":120000},"pollingRequired":true,
      "simBinding":{"token":"c8826741741c44bf973ab8764c899451","vmn":"+917065888859","smsBody":"send-me",
        "expiresInSeconds":120,"rulesHash":"67ce","rules":{"token_ttl":{"enabled":true,"seconds":120}}}}}
    """

    private let otpNext = """
    {"authDetail":{"status":"FAILED","communicationDelivered":false,"channel":"SILENT_AUTH"},
     "quantumLeap":{"state":"s1","channelAuthToken":"t","uid":"U1","channel":"OTP","channels":["OTP"],"asId":"A1",
      "status":"PENDING","timerSettings":{"interval":3,"timeout":60},"pollingRequired":true,"communicationMode":"WHATSAPP"}}
    """

    private func status(_ json: String) throws -> TransactionStatusResponse {
        try JSONDecoder().decode(TransactionStatusResponse.self, from: Data(json.utf8))
    }

    func testSimBindingAsTheNextChannelAfterSnaIsRunByTheSmsFlowNotPolled() throws {
        let result = makeSnaUseCaseResponse(try status(simBindingNext))

        let started = try XCTUnwrap(result.smsBindingStart)
        XCTAssertEqual(started.issued.vmn, "+917065888859")
        XCTAssertEqual(started.issued.smsBody, "send-me")
        XCTAssertNil(result.tokenAsIdUIdAndTimerSettings?.timerSettings, "no generic poll: its 1500 would be read as seconds")
        XCTAssertEqual(result.tokenAsIdUIdAndTimerSettings?.token, "c8826741741c44bf973ab8764c899451")
        // The app still hears that SNA failed and what comes next.
        XCTAssertEqual(result.otplessResponse?.count, 2)
        XCTAssertEqual(result.otplessResponse?.last?.response?["deliveryChannel"] as? String, "OUTBOUND_SMS")
    }

    func testAMalformedSimBindingNextChannelFailsAtOnceInsteadOfHanging() throws {
        let broken = simBindingNext.replacingOccurrences(of: #""smsBody":"send-me","#, with: "")
        let result = makeSnaUseCaseResponse(try status(broken))
        XCTAssertNil(result.smsBindingStart)
        XCTAssertNil(result.tokenAsIdUIdAndTimerSettings?.timerSettings, "and nothing is polled")
        let last = try XCTUnwrap(result.otplessResponse?.last)
        XCTAssertEqual(last.response?["errorCode"] as? String, "SIM_BINDING_NOT_AVAILABLE")
    }

    func testAnotherNextChannelIsUntouched() throws {
        let result = makeSnaUseCaseResponse(try status(otpNext))
        XCTAssertNil(result.smsBindingStart)
        XCTAssertEqual(result.tokenAsIdUIdAndTimerSettings?.timerSettings?.interval, 3, "OTP keeps its own polling")
        XCTAssertEqual(result.tokenAsIdUIdAndTimerSettings?.timerSettings?.timeout, 60)
    }
}
