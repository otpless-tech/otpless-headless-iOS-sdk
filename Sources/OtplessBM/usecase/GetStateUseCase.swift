//
//  GetStateUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//

class GetStateUseCase {
    
    private var retryCount = 0
    
    func invoke(
        queryParams: [String: String],
        isRetry: Bool
    ) async -> (StateResponse?, OtplessResponse?) {
        if !isRetry {
            retryCount = 0
        }
        let response = await Otpless.shared.apiRepository
            .getState(queryParams: queryParams)
        
        switch response {
        case .success(let success):
            return (success, nil)
        case .failure(let failure):
            log(message: "Could not fetch state: \(failure.localizedDescription)", type: .API_RESPONSE_FAILURE)
            if retryCount == 1 {
                retryCount = 0
                return (nil, OtplessResponse.failedToInitializeResponse)
            } else {
                retryCount += 1
                return await invoke(queryParams: queryParams, isRetry: true)
            }
        }
    }
}

internal protocol UsecaseProvider {
    var verifyCodeUseCase: VerifyCodeUseCase { get }
    var passkeyUseCase: PasskeyUseCase { get }
}
