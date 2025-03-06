//
//  TransactionStatusUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//

import Foundation

class TransactionStatusUseCase {
    private var isPolling: Bool = false
    private var state: String = ""
    private var timerSettings: TimerSettings?
    private var attempt: Int64 = 0
    private var queryParams: [String: String] = [:]
    private var isCommunicationDelivered: Bool? = nil
    
    private var responseCallback: ((OtplessResponse) -> Void)?
    
    func invoke(
        queryParams: [String: String],
        state: String,
        timerSettings: TimerSettings?,
        onResponse: ((OtplessResponse) -> Void)?
    ) async {
        self.state = state
        self.queryParams = queryParams
        self.timerSettings = timerSettings
        self.isPolling = true
        self.attempt = 0
        self.responseCallback = onResponse
        
        await startPolling()
    }
    
    private func startPolling() async {
        var mInterval: Int64 = 3
        var mTimeout: Int64 = 60
        var maxAttempts = mTimeout / mInterval
        
        if let timerSettings = timerSettings,
           let interval = timerSettings.interval,
           let timeout = timerSettings.timeout {
            maxAttempts = (timeout) / (interval)
            mInterval = interval
            mTimeout = timeout
        }
        
        log(message: "Polling started", type: .POLLING_STARTED)
        
        for _ in (attempt...maxAttempts) {
            guard isPolling else { break }
            
            try? await Task.sleep(nanoseconds: UInt64(mInterval * 1_000_000_000))
            
            let transactionStatus = await Otpless.shared.apiRepository
                .getTransactionStatus(queryParams: queryParams, state: state)
            
            guard isPolling else { break } // Break if the code was verified at the same time to prevent sending double response
            
            switch transactionStatus {
            case .success(let success):
                switch success.authDetail.status {
                case Constants.SUCCESS:
                    stopPolling(dueToSuccessfulVerification: true)
                    let response = OtplessResponse(
                        responseType: ResponseTypes.ONETAP,
                        response: success.oneTap?.toDict(),
                        statusCode: 200
                    )
                    responseCallback?(response)
                    return
                    
                case Constants.FAILED:
                    // Stop polling, don't send failure resposne, there's no point in notifying client why polling failed.
                    stopPolling(dueToSuccessfulVerification: false)
                    return
                    
                case Constants.PENDING:
                    await handlePendingState(success)
                    if success.authDetail.channel == "OTP" &&
                        success.authDetail.communicationDelivered == true
                    {
                        self.isCommunicationDelivered = true
                        // Only stop polling when channel is OTP.
                        log(message: "Stopping polling because OTP is delivered", type: .POLLING_STOPPED)
                        stopPolling(dueToSuccessfulVerification: false)
                        return
                    }
                default:
                    break
                }
                
            case .failure(let error):
                // Stop polling, don't send failure resposne, there's no point in notifying client why polling failed.
                if let apiError = error as? ApiError {
                    if apiError.statusCode >= 400 && apiError.statusCode <= 500 {
                        stopPolling(dueToSuccessfulVerification: false)
                    }
                }
            }
        }
    }
    
    private func handlePendingState(_ success: TransactionStatusResponse) async {
        if (Otpless.shared.communicationMode == "NA") {
            Otpless.shared.onCommunicationModeChange(
                success.authDetail.communicationMode ?? "NA"
            )
        }
        
        if (Otpless.shared.communicationMode != success.authDetail.communicationMode) {
            Otpless.shared.onCommunicationModeChange(
                success.authDetail.communicationMode ?? ""
            )
            
            let response = parseFallbackTriggered(
                data: success
            )
            responseCallback?(response)
            return
        }
    }
    
    func stopPolling(dueToSuccessfulVerification: Bool) {
        if dueToSuccessfulVerification {
            self.isPolling = false
            self.attempt = 0
            log(message: "Polling stopped.", type: .POLLING_STOPPED)
        } else {
            if isCommunicationDelivered != nil && isCommunicationDelivered == true {
                self.isPolling = false
                self.attempt = 0
                log(message: "Polling stopped.", type: .POLLING_STOPPED)
            } else {
                // Keep on polling
            }
        }
    }
    
    private func parseFallbackTriggered(
        data: TransactionStatusResponse
    ) -> OtplessResponse {
        return OtplessResponse(
            responseType: .FALLBACK_TRIGGERED,
            response: [
                "requestId": data.authDetail.token ?? "",
                "deliveryChannel": data.authDetail.communicationMode ?? "Unknown",
                "channel": Otpless.shared.authType,
                "authType": Otpless.shared.authType
            ],
            statusCode: 200
        )
    }
}
