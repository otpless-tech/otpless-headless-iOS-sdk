//
//  GetMerchantConfigUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//

class GetMerchantConfigUseCase {
    private var retryCount = 0

    func invoke(
        state: String,
        queryParams: [String: String],
        isRetry: Bool
    ) async -> (MerchantConfigResponse?, OtplessResponse?) {
        if !isRetry {
            retryCount = 0
            log(message: "[MerchantConfig] Fetching config — state: \(state.prefix(8))…", type: .MERCHANT_CONFIG)
        } else {
            log(message: "[MerchantConfig] Retrying config fetch — attempt: \(retryCount + 1)", type: .MERCHANT_CONFIG)
        }

        let response = await Otpless.shared.apiRepository
            .getMerchantConfig(state: state, queryParams: queryParams)

        switch response {
        case .success(let success):
            let diType = success.metaData?.deviceIntelligence?.type ?? "<not set>"
            log(message: "[MerchantConfig] Config fetch succeeded — isMFAEnabled: \(success.isMFAEnabled ?? false), deviceIntelligence.type: \(diType)", type: .MERCHANT_CONFIG)
            return (success, nil)
        case .failure(let failure):
            log(message: "[MerchantConfig] Config fetch failed — \(failure.localizedDescription)", type: .API_RESPONSE_FAILURE)
            if retryCount == 1 {
                log(message: "[MerchantConfig] Config fetch failed after max retries — returning error response", type: .API_RESPONSE_FAILURE)
                retryCount = 0
                return (nil, OtplessResponse.failedToInitializeResponse)
            } else {
                retryCount += 1
                return await invoke(state: state, queryParams: queryParams, isRetry: true)
            }
        }
    }
}
