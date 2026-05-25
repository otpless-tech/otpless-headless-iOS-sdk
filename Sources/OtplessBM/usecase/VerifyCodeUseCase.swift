//
//  VerifyOTPUseCase 2.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//


import Foundation

class VerifyCodeUseCase {
    func invoke(state: String, queryParams: [String: Any], getTransactionStatusUseCase: TransactionStatusUseCase) async -> (OtplessResponse?, String?) {
        let channel = queryParams["channel"] as? String ?? "SSO"
        log(message: "[VerifyCode] Submitting code — channel: \(channel), rsId: \(Otpless.shared.rsId.isEmpty ? "<none>" : Otpless.shared.rsId)", type: .VERIFY)

        let response = await Otpless.shared.apiRepository
            .verifySSOCode(queryParams: queryParams, state: state)

        switch response {
        case .failure(let error):
            guard let apiError = error as? ApiError else {
                log(message: "[VerifyCode] Failed — \(error.localizedDescription)", type: .API_RESPONSE_FAILURE)
                return (
                    OtplessResponse(
                        responseType: .VERIFY,
                        response: Utils.createErrorDictionary(
                            errorCode: "500",
                            errorMessage: error.localizedDescription,
                            authType: Otpless.shared.authType
                        ), statusCode: 500
                    ),
                    nil
                )
            }
            log(message: "[VerifyCode] Failed — statusCode: \(apiError.statusCode), error: \(apiError.localizedDescription)", type: .API_RESPONSE_FAILURE)
            var response = apiError.getResponse()
            response["authType"] = Otpless.shared.authType
            return (
                OtplessResponse(responseType: .VERIFY, response: response, statusCode: apiError.statusCode),
                nil
            )

        case .success(let data):
            log(message: "[VerifyCode] Succeeded — ONETAP received, uid: \(data.authDetail.user?.uid ?? "<none>")", type: .VERIFY)
            return (
                OtplessResponse(
                    responseType: .ONETAP,
                    response: data.oneTap?.toDict(),
                    statusCode: 200
                ),
                data.authDetail.user?.uid
            )
        }
    }
}
