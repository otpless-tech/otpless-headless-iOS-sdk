//
//  GetMerchantConfigUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//

class GetMerchantConfigUseCase {
    private var retryCount = 0
    
    func invoke(
        queryParams: [String: String],
        isRetry: Bool
    ) async -> (MerchantConfigResponse?, OtplessResponse?) {
        if !isRetry {
            retryCount = 0
        }
        
        let existingState = SecureStorage.shared.retrieve(key: Constants.STATE_KEY)
        if let existingState = existingState {
            Otpless.shared.setExistingState(existingState)
        }
        
        let response = await Otpless.shared.apiRepository
            .getMerchantConfig(queryParams: queryParams)
        
        switch response {
        case .success(let success):
            if success.state != nil {
                SecureStorage.shared.save(key: Constants.STATE_KEY, value: success.state!)
            }
            return (success, nil)
        case .failure(let failure):
            log(message: "Could not fetch merchant config: \(failure.localizedDescription)", type: .API_RESPONSE_FAILURE)
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
