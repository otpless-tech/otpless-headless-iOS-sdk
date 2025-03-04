//
//  used.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//


import Foundation

/**
 Helper class used to call the Sekura API to perform SNA and then poll the SNATransactionStatus API to fetch user details.
 - Parameter apiRepository: An instance of `ApiRepository` used to call the SNA APIs.
 */
internal final class SNAUseCase: @unchecked Sendable {
    private var isPolling = true
    private var snaStatusPollingLapse: Bool = false

    func invoke(
        state: String,
        url: String,
        timerSettings: TimerSettings
    ) async -> SNAUseCaseResponse {
        isPolling = true
        snaStatusPollingLapse = false

        async let snaApiCall: Void = Otpless.shared.apiRepository
            .makeSNACall(url: url) { [weak self] snaResponse in
                log(message: "Sna response: \(snaResponse)", type: .SNA_RESPONSE)
                sendEvent(event: .SNA_CALLBACK_RESULT)
        }

        async let snaTransactionApiCall = pollSNATransaction(state: state, timerSettings: timerSettings)

        let (_, transactionResponse) = await (snaApiCall, snaTransactionApiCall)
        return transactionResponse
    }

    private func pollSNATransaction(state: String, timerSettings: TimerSettings) async -> SNAUseCaseResponse {
        var startTime: TimeInterval = 0
        let endTime = TimeInterval(timerSettings.timeout ?? 7_000)
        let pollingInterval = TimeInterval(timerSettings.interval ?? 200)
        
        while startTime <= endTime && isPolling {
            let response = await Otpless.shared.apiRepository
                .getSNATransactionStatus(queryParams: [:], state: state)
            
            switch response {
            case .failure(let error):
                log(message: "SNA polling error: \(error)", type: .API_RESPONSE_FAILURE)
                
            case .success(let data):
                
                switch data.authDetail.status {
                case Constants.SUCCESS:
                    isPolling = false
                    return SNAUseCaseResponse(
                        tokenAsIdUIdAndTimerSettings: TokenAsIdUIdAndTimerSettings(
                            token: data.quantumLeap?.channelAuthToken ?? "",
                            asId: data.quantumLeap?.asId ?? "",
                            uid: data.quantumLeap?.uid ?? "",
                            timerSettings: nil // Stop polling if ONETAP data is received
                        ),
                        otplessResponse: OtplessResponse(
                            responseType: .ONETAP,
                            response: data.oneTap?.toDict(),
                            statusCode: 200
                        )
                    )
                    
                case Constants.FAILED:
                    return handleStatusFailed(data)
                    
                case Constants.PENDING:
                    // Continue polling
                    break
                    
                default:
                    break
                }
            }
            
            try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000))
            startTime += pollingInterval
        }
        
        return await performFallbackTransactionRequest(state: state)
    }
    
    private func handleStatusFailed(_ data: TransactionStatusResponse) -> SNAUseCaseResponse {
        isPolling = false
        Otpless.shared.onAuthTypeChange(newAuthType: data.quantumLeap?.channel ?? "")
        Otpless.shared.onCommunicationModeChange(data.quantumLeap?.communicationMode ?? "NA")
        
        return SNAUseCaseResponse(
            tokenAsIdUIdAndTimerSettings: TokenAsIdUIdAndTimerSettings(
                token: data.quantumLeap?.channelAuthToken ?? "",
                asId: data.quantumLeap?.asId ?? "",
                uid: data.quantumLeap?.uid ?? "",
                timerSettings: data.quantumLeap?.pollingRequired == true ? data.quantumLeap?.timerSettings : TimerSettings(interval: 3, timeout: 60)
            ),
            otplessResponse: OtplessResponse(
                responseType: .INITIATE,
                response: [
                    "requestId": data.quantumLeap?.channelAuthToken ?? "",
                    "deliveryChannel": data.quantumLeap?.communicationMode ?? "Unknown",
                    "channel": Otpless.shared.authType,
                    "authType": Otpless.shared.authType
                ],
                statusCode: 200
            )
        )
    }
    
    private func performFallbackTransactionRequest(state: String) async -> SNAUseCaseResponse {
        stopPolling()
        self.snaStatusPollingLapse = true
        let response = await Otpless.shared.apiRepository
            .getSNATransactionStatus(queryParams: [:], state: state)
        
        let snaUseCaseResponse: SNAUseCaseResponse
            
        switch response {
        case .success(let data):
            if data.authDetail.status == Constants.FAILED {
                return handleStatusFailed(data)
            } else {
                snaUseCaseResponse = SNAUseCaseResponse(tokenAsIdUIdAndTimerSettings: nil, otplessResponse: OtplessResponse(responseType: .INITIATE, response: [
                    "errorCode": "9106",
                    "errorMessage": "Transaction timeout"
                ], statusCode: 9106))
            }
            
        case .failure(let error):
            guard let apiError = error as? ApiError else {
                snaUseCaseResponse = SNAUseCaseResponse(tokenAsIdUIdAndTimerSettings: nil, otplessResponse: OtplessResponse(
                    responseType: .INITIATE,
                    response: Utils.createErrorDictionary(
                        errorCode: "9106",
                        errorMessage: "Transaction timeout"
                    ), statusCode: 9106
                ))
                return snaUseCaseResponse
            }
            
            snaUseCaseResponse = SNAUseCaseResponse(tokenAsIdUIdAndTimerSettings: nil, otplessResponse: OtplessResponse(responseType: .INITIATE, response: apiError.getResponse(), statusCode: apiError.statusCode))
        }
        
        return snaUseCaseResponse
    }
    
    func stopPolling() {
        self.isPolling = false
    }
}

internal struct SNAUseCaseResponse {
    let tokenAsIdUIdAndTimerSettings: TokenAsIdUIdAndTimerSettings?
    let otplessResponse: OtplessResponse?
}
