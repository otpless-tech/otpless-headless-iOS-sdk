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
    private var lapseDataQueryParams = [String: String]()

    func invoke(
        state: String,
        url: String,
        timerSettings: TimerSettings
    ) async -> SNAUseCaseResponse {
        isPolling = true

        async let snaApiCall: Void = Otpless.shared.apiRepository
            .makeSNACall(url: url) { snaResponse in
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
                .getSNATransactionStatus(queryParams: lapseDataQueryParams, state: state)
            
            switch response {
            case .failure(let error):
                lapseDataQueryParams["lapseMeta"] = error.localizedDescription
                
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
        
        return SNAUseCaseResponse(
            tokenAsIdUIdAndTimerSettings: nil,
            otplessResponse: nil
        )
    }
    
    func stopPolling() {
        self.isPolling = false
    }
}

internal struct SNAUseCaseResponse {
    let tokenAsIdUIdAndTimerSettings: TokenAsIdUIdAndTimerSettings?
    let otplessResponse: OtplessResponse?
}
