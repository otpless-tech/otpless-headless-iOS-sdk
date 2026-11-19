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

    func testAFailedVerifyCarriesTheBackendsMessageAndReason() throws {
        let response = VerifyOTPUseCase.response(for: try decode(simNotBound))
        let body = response.response ?? [:]
        XCTAssertEqual(body["errorMessage"] as? String, "The SIM is not bound to this device")
        XCTAssertEqual(body["failureReason"] as? String, "SIM_NOT_BOUND")
        XCTAssertEqual(body["errorCode"] as? String, String(OtplessConstant.EC.ALL_CHANNEL_AUTH_FAILED),
                       "the numeric errorCode merchants already match on does not change")
        XCTAssertEqual(response.statusCode, 400)
    }

    func testAFailedVerifyWithNoDetailStillSaysItFailed() throws {
        let response = VerifyOTPUseCase.response(for: try decode(failedWithoutDetail))
        XCTAssertEqual(response.responseType, .AUTH_TERMINATED)
        XCTAssertEqual(response.response?["errorMessage"] as? String, "Authentication on all channels failed.")
        XCTAssertNil(response.response?["failureReason"])
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
        XCTAssertEqual(fromPoll.response?["failureReason"] as? String, fromVerify.response?["failureReason"] as? String)
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
