//
//  GetStateUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//

class GetStateUseCase {
    
    private var retryCount = 0
    /// True while the state in use came from the local cache, so a 7005 may refresh it once per session.
    private(set) var isStateRefreshRequired = false

    /// Returns the cached state, or nil if a remote fetch is needed.
    func loadCachedState() -> String? {
        guard let savedState = SecureStorage.shared.retrieve(key: Constants.STATE_KEY), !savedState.isEmpty else {
            isStateRefreshRequired = false
            return nil
        }
        OtplessBMEvents.Init.stateFromCache()
        isStateRefreshRequired = true
        return savedState
    }

    /// Deletes the cached state and fetches a fresh one after a 7005. Runs at most once per session, and only
    /// when the state in use was loaded from the local cache.
    /// - Returns: nil if no refresh was attempted, an empty string if the fetch failed, otherwise the new state.
    func retryStateLoading(queryParams: [String: String]) async -> String? {
        guard isStateRefreshRequired else { return nil }
        isStateRefreshRequired = false
        SecureStorage.shared.delete(key: Constants.STATE_KEY)
        log(message: "[State] Retrying state loading from remote", type: .SDK_STATE_FETCH)
        let (stateResponse, _) = await invoke(queryParams: queryParams, isRetry: false)
        guard let newState = stateResponse?.state, !newState.isEmpty else {
            log(message: "[State] State refresh failed", type: .API_RESPONSE_FAILURE)
            OtplessBMEvents.Init.stateFetchFailed(isRetry: true)
            return ""
        }
        // Persist the refreshed state
        SecureStorage.shared.save(key: Constants.STATE_KEY, value: newState)
        log(message: "[State] State refreshed — state: \(newState.prefix(8))…", type: .SDK_STATE_FETCH)
        OtplessBMEvents.Init.stateReady(isAuthRetry: true)
        return newState
    }

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
