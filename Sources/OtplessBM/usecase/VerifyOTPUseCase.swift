//
//  VerifyOTPUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//


import Foundation

class VerifyOTPUseCase {
    func invoke(
        state: String,
        queryParams: [String: String],
        simBound: Bool? = nil,
        getTransactionStatusUseCase: TransactionStatusUseCase
    ) async -> OtplessResponse {
        log(message: "[VerifyOTP] Submitting OTP — authType: \(Otpless.shared.authType), rsId: \(Otpless.shared.rsId.isEmpty ? "<none>" : Otpless.shared.rsId)", type: .VERIFY)

        let response = await Otpless.shared.apiRepository
            .verifyOTP(queryParams: queryParams, state: state, simBound: simBound)

        switch response {
        case .failure(let error):
            guard let apiError = error as? ApiError else {
                log(message: "[VerifyOTP] Failed — \(error.localizedDescription)", type: .API_RESPONSE_FAILURE)
                return OtplessResponse(
                    responseType: .VERIFY,
                    response: Utils.createErrorDictionary(
                        errorCode: "500",
                        errorMessage: error.localizedDescription,
                        authType: Otpless.shared.authType
                    ), statusCode: 500
                )
            }
            log(message: "[VerifyOTP] Failed — statusCode: \(apiError.statusCode), error: \(apiError.localizedDescription)", type: .API_RESPONSE_FAILURE)
            var response = apiError.getResponse()
            response["authType"] = Otpless.shared.authType
            return OtplessResponse(responseType: .VERIFY, response: response, statusCode: apiError.statusCode)

        case .success(let data):
            return Self.response(for: data)
        }
    }

    /// The backend answers a verify with HTTP 200 even when it ends the transaction (for example
    /// `SIM_NOT_BOUND` after a `simBound: false`). Only a SUCCESS status is a sign-in.
    static func response(for data: TransactionStatusResponse) -> OtplessResponse {
        if data.authDetail.status == Constants.FAILED {
            log(message: "[VerifyOTP] Transaction FAILED — \(data.authDetail.errorCode ?? "no reason"): \(data.authDetail.errorDetails ?? "")", type: .VERIFY)
            return OtplessResponse.terminalResponse(forFailed: data.authDetail)
        }
        log(message: "[VerifyOTP] Succeeded — ONETAP received", type: .VERIFY)
        return OtplessResponse(
            responseType: .ONETAP,
            response: data.oneTap?.toDict(),
            statusCode: 200
        )
    }
}
