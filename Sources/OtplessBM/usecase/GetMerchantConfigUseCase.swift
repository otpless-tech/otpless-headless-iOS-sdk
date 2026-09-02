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
            DLog( "[MerchantConfig] Fetching config — state: \(state.prefix(8))…")
        } else {
            DLog("[MerchantConfig] Retrying config fetch — attempt: \(retryCount + 1)")
        }

        let response = await Otpless.shared.apiRepository
            .getMerchantConfig(state: state, queryParams: queryParams)

        switch response {
        case .success(let success):
            let diType = success.metaData?.deviceIntelligence?.type ?? "<not set>"
            DLog("[MerchantConfig] Config fetch succeeded — isMFAEnabled: \(success.isMFAEnabled ?? false), deviceIntelligence.type: \(diType)")
            return (success, nil)
        case .failure(let failure):
            DLog("[MerchantConfig] Config fetch failed — \(failure.localizedDescription)")
            /// checking for ssl failure error no need to retry in this case
            if let apiError = failure as? ApiError, apiError.statusCode == Constants.SSL_ERROR_CODE {
                let response: [String: Any] = [
                    "errorCode": String(Constants.SSL_ERROR_CODE),
                    "errorMessage": "SSL pin validation failed"
                ]
                retryCount = 0
                /// todo: send the event here.
                return (nil, OtplessResponse(responseType: .FAILED, response: response, statusCode: Constants.SSL_ERROR_CODE))
            }
            if retryCount == 1 {
                DLog("[MerchantConfig] Config fetch failed after max retries — returning error response")
                retryCount = 0
                return (nil, OtplessResponse.failedToInitializeResponse)
            } else {
                retryCount += 1
                return await invoke(state: state, queryParams: queryParams, isRetry: true)
            }
        }
    }
}
