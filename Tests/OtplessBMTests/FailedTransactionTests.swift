//
//  FailedTransactionTests.swift
//  OtplessBMTests
//
//  Found on a device: after `simBound: false` the backend answered the OTP verify with HTTP 200 and
//  authDetail.status FAILED / SIM_NOT_BOUND, and the SDK reported it as a successful sign-in (ONETAP).
//

import XCTest
@testable import OtplessBM

/// The exact body staging returned for the failed verify.
private let simNotBound = """
{"authDetail":{"status":"FAILED","token":"4608b6f85b154a069c8270bba3fba842","asId":"946F536AF0FB423B81CA1761A019F1E8",
 "errorDetails":"The SIM is not bound to this device","errorCode":"SIM_NOT_BOUND","communicationDelivered":false,"webauthnRegistered":false}}
"""

private let verified = """
{"authDetail":{"status":"SUCCESS","token":"t","channel":"OTP","communicationDelivered":false,"webauthnRegistered":false,
 "user":{"mobile":"918980994455","uid":"U1"}}}
"""

private let failedWithoutDetail = """
{"authDetail":{"status":"FAILED","communicationDelivered":false}}
"""

final class FailedTransactionTests: XCTestCase {

    private func decode(_ json: String) throws -> TransactionStatusResponse {
        try JSONDecoder().decode(TransactionStatusResponse.self, from: Data(json.utf8))
    }

    func testAFailedVerifyIsNotASignIn() throws {
        let response = VerifyOTPUseCase.response(for: try decode(simNotBound))
        XCTAssertEqual(response.responseType, .AUTH_TERMINATED)
        XCTAssertNotEqual(response.responseType, .ONETAP)
    }

    func testAFailedVerifyCarriesTheBackendsMessageAndReasonInAnErrorObject() throws {
        let response = VerifyOTPUseCase.response(for: try decode(simNotBound))
        let body = response.response ?? [:]
        XCTAssertEqual(body["errorMessage"] as? String, "The SIM is not bound to this device")
        let error = try XCTUnwrap(body["error"] as? [String: Any], "a non-SNA failure names its reason in `error`")
        XCTAssertEqual(error["errorCode"] as? String, "SIM_NOT_BOUND")
        XCTAssertEqual(error["message"] as? String, "The SIM is not bound to this device")
        XCTAssertEqual(error["description"] as? String, "The SIM is not bound to this device")
        XCTAssertNil(body["snaError"], "snaError stays for silent-auth failures")
        XCTAssertNil(body["failureReason"], "no new top-level key")
        XCTAssertEqual(body["errorCode"] as? String, String(OtplessConstant.EC.ALL_CHANNEL_AUTH_FAILED),
                       "the numeric errorCode merchants already match on does not change")
        XCTAssertEqual(response.statusCode, 400)
    }

    func testAFailedVerifyWithNoDetailStillSaysItFailed() throws {
        let response = VerifyOTPUseCase.response(for: try decode(failedWithoutDetail))
        XCTAssertEqual(response.responseType, .AUTH_TERMINATED)
        XCTAssertEqual(response.response?["errorMessage"] as? String, "Authentication on all channels failed.")
        XCTAssertNil(response.response?["snaError"])
        XCTAssertNil(response.response?["error"])
    }

    func testASnaErrorTheBackendSendsIsPassedThroughAndGetsNoErrorObject() throws {
        let json = #"{"authDetail":{"status":"FAILED","communicationDelivered":false,"errorCode":"SIM_NOT_BOUND","errorDetails":"x","snaError":{"errorCode":"7777","message":"carrier said no"}}}"#
        let response = VerifyOTPUseCase.response(for: try decode(json))
        let sna = try XCTUnwrap(response.response?["snaError"] as? [String: Any])
        XCTAssertEqual(sna["errorCode"] as? String, "7777")
        XCTAssertEqual(sna["message"] as? String, "carrier said no")
        XCTAssertNil(response.response?["error"], "a silent-auth failure with no error object of its own gets none built")
    }

    func testASuccessfulVerifyIsStillASignIn() throws {
        let response = VerifyOTPUseCase.response(for: try decode(verified))
        XCTAssertEqual(response.responseType, .ONETAP)
        XCTAssertEqual(response.statusCode, 200)
    }

    func testThePollAndTheVerifyMapAFailureTheSameWay() throws {
        let detail = try decode(simNotBound).authDetail
        let fromPoll = OtplessResponse.terminalResponse(forFailed: detail)
        let fromVerify = VerifyOTPUseCase.response(for: try decode(simNotBound))
        XCTAssertEqual(fromPoll.responseType, fromVerify.responseType)
        XCTAssertEqual(fromPoll.response?["errorMessage"] as? String, fromVerify.response?["errorMessage"] as? String)
        let pollError = fromPoll.response?["error"] as? [String: Any]
        let verifyError = fromVerify.response?["error"] as? [String: Any]
        XCTAssertEqual(pollError?["errorCode"] as? String, verifyError?["errorCode"] as? String)
    }

    func testAnErrorObjectTheBackendSendsIsPassedThroughAsItCame() throws {
        let json = #"{"authDetail":{"status":"FAILED","communicationDelivered":false,"errorCode":"SIM_NOT_BOUND","errorDetails":"built text","error":{"errorCode":"E100","message":"backend text","description":"backend description"}}}"#
        let response = VerifyOTPUseCase.response(for: try decode(json))
        let error = try XCTUnwrap(response.response?["error"] as? [String: Any])
        XCTAssertEqual(error["errorCode"] as? String, "E100", "the backend's object wins over one built from errorCode")
        XCTAssertEqual(error["message"] as? String, "backend text")
        XCTAssertEqual(error["description"] as? String, "backend description")
        XCTAssertNil(response.response?["snaError"])
    }

    func testBothObjectsArePassedWhenTheBackendSendsBoth() throws {
        let json = #"{"authDetail":{"status":"FAILED","communicationDelivered":false,"snaError":{"errorCode":"7777"},"error":{"errorCode":"E100"}}}"#
        let body = VerifyOTPUseCase.response(for: try decode(json)).response ?? [:]
        XCTAssertEqual((body["snaError"] as? [String: Any])?["errorCode"] as? String, "7777")
        XCTAssertEqual((body["error"] as? [String: Any])?["errorCode"] as? String, "E100")
    }

    func testAnOlderBackendWithoutErrorCodeStillDecodes() throws {
        let old = #"{"authDetail":{"status":"PENDING","communicationDelivered":false}}"#
        XCTAssertNil(try decode(old).authDetail.errorCode)
    }
}

final class PollFailureTests: XCTestCase {
    func testARefusedStatusCallEndsTheTransactionWithTheBackendsReason() {
        let error = ApiError(message: "Token expired", statusCode: 401, responseJson: ["errorCode": "7304", "description": "Token expired"])
        let response = OtplessResponse.pollRejected(by: error)
        XCTAssertEqual(response.responseType, .AUTH_TERMINATED)
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(response.response?["errorCode"] as? String, "7304")
        XCTAssertEqual(response.response?["errorMessage"] as? String, "Token expired")
    }

    func testARefusedStatusCallWithNoBodyFallsBackToTheHttpStatus() {
        let response = OtplessResponse.pollRejected(by: ApiError(message: "Server error", statusCode: 503))
        XCTAssertEqual(response.response?["errorCode"] as? String, "503")
        XCTAssertEqual(response.response?["errorMessage"] as? String, "Server error")
    }
}


/// What staging sent when an OTP_BIND code was verified for a number the SIM does not hold: the transaction FAILED with
/// SIM_NOT_BOUND, and `quantumLeap` named SMS binding as the next channel.
private let simNotBoundWithNextChannel = """
{"authDetail":{"status":"FAILED","token":"21f56e742e3546b2a2889a9121b82b59","asId":"24346881090C48A382BEB4177285E47B",
 "errorDetails":"The SIM is not bound to this device","errorCode":"SIM_NOT_BOUND","communicationDelivered":false,"webauthnRegistered":false},
 "quantumLeap":{"state":"170dc9a0","channelAuthToken":"21f56e742e3546b2a2889a9121b82b59","uid":"3708E6B23FC64C579C411E35CEBB24F2",
 "channel":"SIM_BINDING","channels":["SIM_BINDING"],"asId":"24346881090C48A382BEB4177285E47B","communicationMode":"OUTBOUND_SMS",
 "status":"PENDING","timerSettings":{"interval":1500,"timeout":120000},"pollingRequired":true,
 "simBinding":{"vmn":"+917065888859","smsBody":"please send the message EITRsfrNAJY2A2O:6jj2lHxOOoKQ-z7MQF2RvDvD","expiresAt":1795194486,"expiresInSeconds":120}}}
"""

final class VerifyFallbackTests: XCTestCase {
    private func decode(_ json: String) throws -> TransactionStatusResponse {
        try JSONDecoder().decode(TransactionStatusResponse.self, from: Data(json.utf8))
    }

    func testAFailedVerifyThatNamesSmsBindingNextCarriesOnThere() throws {
        let next = try XCTUnwrap(VerifyOTPUseCase.nextSmsBinding(from: try decode(simNotBoundWithNextChannel)))
        XCTAssertEqual(next.token, "21f56e742e3546b2a2889a9121b82b59")
        XCTAssertEqual(next.started.issued.vmn, "+917065888859")
        XCTAssertEqual(next.started.issued.ttlSeconds, 120)
        XCTAssertEqual(next.uid, "3708E6B23FC64C579C411E35CEBB24F2")
    }

    func testAFailedVerifyWithNoNextChannelStillEnds() throws {
        XCTAssertNil(VerifyOTPUseCase.nextSmsBinding(from: try decode(simNotBound)))
    }

    func testASuccessfulVerifyNeverCarriesOn() throws {
        XCTAssertNil(VerifyOTPUseCase.nextSmsBinding(from: try decode(verified)))
    }

    func testAnotherNextChannelIsNotSmsBinding() throws {
        let other = simNotBoundWithNextChannel
            .replacingOccurrences(of: "\"channel\":\"SIM_BINDING\"", with: "\"channel\":\"OTP\"")
        XCTAssertNil(VerifyOTPUseCase.nextSmsBinding(from: try decode(other)))
    }

    func testANextChannelWithIncompleteDataEnds() throws {
        let incomplete = simNotBoundWithNextChannel.replacingOccurrences(of: "\"vmn\":\"+917065888859\",", with: "")
        XCTAssertNil(VerifyOTPUseCase.nextSmsBinding(from: try decode(incomplete)))
    }

    func testTheFailedResponseIsStillTheTerminalOneForCallersThatDoNotFollowTheNextChannel() throws {
        let response = VerifyOTPUseCase.response(for: try decode(simNotBoundWithNextChannel))
        XCTAssertEqual(response.responseType, .AUTH_TERMINATED)
    }
}
