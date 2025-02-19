//
//  GetStateUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//

class GetStateUseCase {
    func invoke(
        queryParams: [String: String]
    ) async -> StateResponse? {
        let response = await Otpless.shared.apiRepository
            .getState(queryParams: queryParams)
        
        switch response {
        case .success(let success):
            return success
        case .failure(let failure):
            log(message: "Could not fetch state: \(failure.localizedDescription)", type: .API_RESPONSE_FAILURE)
            return nil
        }
    }
}
