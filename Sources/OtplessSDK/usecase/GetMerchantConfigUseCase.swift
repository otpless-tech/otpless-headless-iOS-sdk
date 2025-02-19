//
//  GetMerchantConfigUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//

class GetMerchantConfigUseCase {
    func invoke(
        state: String,
        queryParams: [String: String]
    ) async -> MerchantConfigResponse? {
        let response = await Otpless.shared.apiRepository
            .getMerchantConfig(state: state, queryParams: queryParams)
        
        switch response {
        case .success(let success):
            return success
        case .failure(let failure):
            log(message: "Could not fetch merchant config: \(failure.localizedDescription)", type: .API_RESPONSE_FAILURE)
            return nil
        }
    }
}
