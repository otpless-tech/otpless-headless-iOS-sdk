//
//  VerifyOTPUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//


import Foundation

class VerifyOTPUseCase {
    func invoke(state: String, queryParams: [String: String], getTransactionStatusUseCase: TransactionStatusUseCase) async -> OtplessResponse {
        
        let response = await Otpless.shared.apiRepository
            .verifyOTP(queryParams: queryParams, state: state)
        
        switch response {
        case .failure(let error):
            guard let apiError = error as? ApiError else {
                return OtplessResponse(
                    responseType: .VERIFY,
                    response: Utils.createErrorDictionary(
                        errorCode: "500",
                        errorMessage: error.localizedDescription,
                        authType: Otpless.shared.authType
                    ), statusCode: 500
                )
            }
            
            log(message: "Could not verify OTP: " + apiError.localizedDescription, type: .API_RESPONSE_FAILURE)
            
            var response = apiError.getResponse()
            response["authType"] = Otpless.shared.authType
            return OtplessResponse(responseType: .VERIFY, response: response, statusCode: apiError.statusCode)
        case .success(let data):
            return OtplessResponse(
                responseType: .ONETAP,
                response: data.oneTap?.toDict(),
                statusCode: 200
            )
        }
        
    }
}
