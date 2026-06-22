//
//  SNAUseCase.swift
//  OtplessSDK
//

import Foundation

/// Helper class used to call the Sekura API to perform SNA and then poll the
/// SNA transaction status API to fetch user details.
internal final class SNAUseCase: @unchecked Sendable {
    private var isPolling = true
    private var snaStatusPollingLapse: Bool = false
    private var snaUrlHitError: [String: String]?

    private let SILENT_AUTH = "SILENT_AUTH"

    func invoke(
        url: String,
        timerSettings: TimerSettings
    ) async -> SNAUseCaseResponse {
        isPolling = true
        snaStatusPollingLapse = false

        OtplessBMEvents.Sna.statusCheckStarted(isMfaEnabled: Otpless.shared.isMfaEnabled)
        OtplessBMEvents.Sna.started(url: url)

        let receivedSNAConnectionTimeout = timerSettings.timeout
        let snaConnectionTimeout: Double
        if let receivedSNAConnectionTimeout = receivedSNAConnectionTimeout {
            snaConnectionTimeout = Double(receivedSNAConnectionTimeout / 1000)
        } else {
            snaConnectionTimeout = 7.0
        }
        Otpless.shared.apiRepository.updateSNAConnectionTimeout(connectionTimeout: snaConnectionTimeout)

        async let snaApiCall: Void = Otpless.shared.apiRepository
            .makeSNACall(url: url) { [weak self] snaResponse in
                let status = snaResponse["status"] as? String

                if status == nil || status?.lowercased() != "ok" {
                    let snaError = [
                        "cause": snaResponse["error"] as? String ?? "Unable to find cause",
                        "brief": snaResponse["error_description"] as? String ?? "Unable to find brief"
                    ]
                    self?.snaUrlHitError = ["lapseMeta": Utils.convertDictionaryToString(snaError)]
                    self?.stopPolling()
                }

                log(message: "Sna response: \(snaResponse)", type: .SNA_RESPONSE)
                OtplessBMEvents.Sna.callbackResult(status: status ?? "nil")
            }

        async let snaTransactionApiCall = pollSNATransaction(timerSettings: timerSettings)

        let (_, transactionResponse) = await (snaApiCall, snaTransactionApiCall)
        return transactionResponse
    }

    private func pollSNATransaction(timerSettings: TimerSettings) async -> SNAUseCaseResponse {
        var startTime: TimeInterval = 0
        let endTime = TimeInterval(timerSettings.timeout ?? 7_000)
        let pollingInterval = TimeInterval(timerSettings.interval ?? 200)

        while startTime <= endTime && isPolling {
            let response: Result<TransactionStatusResponse, Error>
            if Otpless.shared.isMfaEnabled {
                response = await Otpless.shared.apiRepository
                    .mfaSnaStatus(queryParams: [:], state: Otpless.shared.state ?? "")
            } else {
                response = await Otpless.shared.apiRepository
                    .getSNATransactionStatus(queryParams: [:], state: Otpless.shared.state ?? "")
            }

            switch response {
            case .failure(let error):
                log(message: "SNA polling error: \(error)", type: .API_RESPONSE_FAILURE)

            case .success(let data):
                switch data.authDetail.status {
                case Constants.SUCCESS:
                    isPolling = false
                    if let quantumLeap = data.quantumLeap {
                        Otpless.shared.onAuthTypeChange(newAuthType: quantumLeap.channel)
                        Otpless.shared.onCommunicationModeChange(quantumLeap.communicationMode ?? "")
                    }
                    return makeSnaUseCaseResponse(data)

                case Constants.FAILED:
                    isPolling = false
                    Otpless.shared.onAuthTypeChange(newAuthType: data.quantumLeap?.channel ?? "")
                    Otpless.shared.onCommunicationModeChange(data.quantumLeap?.communicationMode ?? "")
                    return makeSnaUseCaseResponse(data)

                case Constants.PENDING:
                    break

                default:
                    break
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000))
            startTime += pollingInterval
        }

        return await performFallbackTransactionRequest(
            withErrorDict: snaUrlHitError ?? [
                "lapseMeta": Utils.convertDictionaryToString([
                    "cause": "sdk_polling_timeout",
                    "brief": "Transaction could not be polled anymore."
                ])
            ]
        )
    }

    private func performFallbackTransactionRequest(withErrorDict errorDict: [String: String]) async -> SNAUseCaseResponse {
        stopPolling()
        self.snaStatusPollingLapse = true

        let response: Result<TransactionStatusResponse, Error>
        if Otpless.shared.isMfaEnabled {
            response = await Otpless.shared.apiRepository
                .mfaSnaStatus(queryParams: errorDict, state: Otpless.shared.state ?? "")
        } else {
            response = await Otpless.shared.apiRepository
                .getSNATransactionStatus(queryParams: errorDict, state: Otpless.shared.state ?? "")
        }

        switch response {
        case .failure:
            return SNAUseCaseResponse(
                tokenAsIdUIdAndTimerSettings: nil,
                otplessResponse: [OtplessResponse.snaTransactionFinalTimeout]
            )

        case .success(let data):
            switch data.authDetail.status {
            case Constants.SUCCESS:
                return makeSnaUseCaseResponse(data)

            case Constants.FAILED:
                Otpless.shared.onAuthTypeChange(newAuthType: data.quantumLeap?.channel ?? "")
                Otpless.shared.onCommunicationModeChange(data.quantumLeap?.communicationMode ?? "")
                return makeSnaUseCaseResponse(data)

            default:
                return SNAUseCaseResponse(
                    tokenAsIdUIdAndTimerSettings: nil,
                    otplessResponse: [OtplessResponse.snaTransactionFinalTimeout]
                )
            }
        }
    }

    func stopPolling() {
        self.isPolling = false
    }
}

internal struct SNAUseCaseResponse {
    let tokenAsIdUIdAndTimerSettings: TokenAsIdUIdAndTimerSettings?
    let otplessResponse: [OtplessResponse]?
}
