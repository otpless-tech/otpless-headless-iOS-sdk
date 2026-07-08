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
            maxAttempts = timeout / interval
            mInterval = interval
            mTimeout = timeout
        }

        log(message: "[Polling] Started — interval: \(mInterval)s, timeout: \(mTimeout)s, maxAttempts: \(maxAttempts)", type: .POLLING_STARTED)

        OtplessBMEvents.Api.transactionStatusCheckStarted()

        for _ in attempt...maxAttempts {
            guard isPolling else {
                log(message: "[Polling] Stopped before next attempt", type: .POLLING_STOPPED)
                break
            }

            try? await Task.sleep(nanoseconds: UInt64(mInterval * 1_000_000_000))

            let transactionStatus = await Otpless.shared.apiRepository
                .getTransactionStatus(queryParams: queryParams, state: state)

            guard isPolling else {
                log(message: "[Polling] Stopped during response handling (concurrent verification)", type: .POLLING_STOPPED)
                break
            }

            switch transactionStatus {
            case .success(let success):
                log(message: "[Polling] Status: \(success.authDetail.status) — channel: \(success.authDetail.channel ?? "nil"), communicationDelivered: \(success.authDetail.communicationDelivered)", type: .POLLING_RESPONSE)

                switch success.authDetail.status {
                case Constants.SUCCESS:
                    log(message: "[Polling] Auth succeeded — relaying ONETAP", type: .POLLING_RESPONSE)
                    stopPolling(dueToSuccessfulVerification: true)
                    let response = OtplessResponse(
                        responseType: ResponseTypes.ONETAP,
                        response: success.oneTap?.toDict(),
                        statusCode: 200
                    )
                    responseCallback?(response)
                    return

                case Constants.FAILED:
                    log(message: "[Polling] Auth failed — emitting AUTH_TERMINATED and stopping poll", type: .POLLING_STOPPED)
                    let terminal = OtplessResponse.makeTerminalResponse(
                        status: 400,
                        error: String(OtplessConstant.EC.ALL_CHANNEL_AUTH_FAILED),
                        message: "Authentication on all channels failed.",
                        snaError: success.authDetail.snaError
                    )
                    responseCallback?(terminal)
                    stopPolling(dueToSuccessfulVerification: false)
                    return

                case Constants.PENDING:
                    await handlePendingState(success)

                    if success.authDetail.communicationDelivered == true,
                       let communicationMode = success.authDetail.communicationMode,
                       let authType = success.authDetail.channel {
                        log(message: "[Polling] Communication delivered — mode: \(communicationMode), authType: \(authType)", type: .POLLING_RESPONSE)
                        sendCommunicationDeliveredResponse(deliveredOn: communicationMode, forAuthType: authType)
                    }

                    if success.authDetail.channel == "OTP" &&
                        success.authDetail.communicationDelivered == true {
                        log(message: "[Polling] OTP delivered — stopping poll, waiting for user to enter OTP", type: .POLLING_STOPPED)
                        self.isCommunicationDelivered = true
                        stopPolling(dueToSuccessfulVerification: false)
                        return
                    }

                default:
                    log(message: "[Polling] Unknown status: \(success.authDetail.status)", type: .POLLING_RESPONSE)
                }

            case .failure(let error):
                log(message: "[Polling] Request failed — \(error.localizedDescription)", type: .API_RESPONSE_FAILURE)
                if let apiError = error as? ApiError, apiError.statusCode >= 400 && apiError.statusCode <= 500 {
                    log(message: "[Polling] Client/server error (\(apiError.statusCode)) — stopping poll", type: .POLLING_STOPPED)
                    stopPolling(dueToSuccessfulVerification: false)
                }
            }
        }

        log(message: "[Polling] Loop exhausted — max attempts reached", type: .POLLING_STOPPED)
    }
    
    private func handlePendingState(_ success: TransactionStatusResponse) async {
        if Otpless.shared.communicationMode == "NA" {
            let newMode = success.authDetail.communicationMode ?? "NA"
            log(message: "[Polling] Communication mode initialised — mode: \(newMode)", type: .POLLING_RESPONSE)
            Otpless.shared.onCommunicationModeChange(newMode)
        }

        if Otpless.shared.communicationMode != success.authDetail.communicationMode {
            let newMode = success.authDetail.communicationMode ?? ""
            log(message: "[Polling] Fallback triggered — communicationMode changed from '\(Otpless.shared.communicationMode)' to '\(newMode)'", type: .POLLING_RESPONSE)
            Otpless.shared.onCommunicationModeChange(newMode)
            let response = parseFallbackTriggered(data: success)
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
    
    private func sendCommunicationDeliveredResponse(deliveredOn deliveryChannel: String, forAuthType authType: String) {
        responseCallback?(
            OtplessResponse(
                responseType: .DELIVERY_STATUS,
                response: [
                    "deliveryChannel": deliveryChannel,
                    "authType": authType,
                    "communicationDelivered": true
                ],
                statusCode: 200
            )
        )
    }
}
