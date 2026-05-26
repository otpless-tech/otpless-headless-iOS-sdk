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
            log(message: "[State] Fetching device state from server", type: .SDK_STATE_FETCH)
        } else {
            log(message: "[State] Retrying state fetch — attempt: \(retryCount + 1)", type: .SDK_STATE_FETCH)
        }

        let response = await Otpless.shared.apiRepository
            .getState(queryParams: queryParams)

        switch response {
        case .success(let success):
            log(message: "[State] State fetch succeeded — state: \(success.state?.prefix(8) ?? "nil")…", type: .SDK_STATE_FETCH)
            return (success, nil)
        case .failure(let failure):
            log(message: "[State] State fetch failed — \(failure.localizedDescription)", type: .API_RESPONSE_FAILURE)
            if retryCount == 1 {
                log(message: "[State] State fetch failed after max retries — returning error response", type: .API_RESPONSE_FAILURE)
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
