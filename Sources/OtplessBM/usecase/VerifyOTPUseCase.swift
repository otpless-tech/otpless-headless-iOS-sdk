//
//  VerifyOTPUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//


import Foundation

class VerifyOTPUseCase {
    func invoke(state: String, queryParams: [String: String], getTransactionStatusUseCase: TransactionStatusUseCase) async -> OtplessResponse {
        log(message: "[VerifyOTP] Submitting OTP — authType: \(Otpless.shared.authType), rsId: \(Otpless.shared.rsId.isEmpty ? "<none>" : Otpless.shared.rsId)", type: .VERIFY)

        let response = await Otpless.shared.apiRepository
            .verifyOTP(queryParams: queryParams, state: state)

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
            log(message: "[VerifyOTP] Succeeded — ONETAP received", type: .VERIFY)
            return OtplessResponse(
                responseType: .ONETAP,
                response: data.oneTap?.toDict(),
                statusCode: 200
            )
        }
    }
}
