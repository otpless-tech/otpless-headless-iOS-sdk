//
//  VerifyOTPUseCase 2.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//


import Foundation

class VerifyCodeUseCase {
    func invoke(state: String, queryParams: [String: Any], getTransactionStatusUseCase: TransactionStatusUseCase) async -> (OtplessResponse?, String?) {
        getTransactionStatusUseCase.stopPolling()
        
        let response = await Otpless.shared.apiRepository
            .verifySSOCode(queryParams: queryParams, state: state)
        
        switch response {
        case .failure(let error):
            guard let apiError = error as? ApiError else {
                return (
                    OtplessResponse(
                        responseType: .VERIFY,
                        response: Utils.createErrorDictionary(
                            errorCode: "500",
                            errorMessage: error.localizedDescription
                        ), statusCode: 500
                    ),
                    nil
                )
            }
            
            log(message: "Could not verify OTP: " + apiError.localizedDescription, type: .API_RESPONSE_FAILURE)
            
            return (
                OtplessResponse(responseType: .VERIFY, response: apiError.getResponse(), statusCode: apiError.statusCode),
                nil
            )
        case .success(let data):
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
