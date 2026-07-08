//
//  ConvertUtils.swift
//  OtplessBM
//

import Foundation

private let SILENT_AUTH = "SILENT_AUTH"

internal func makeSnaUseCaseResponse(_ response: TransactionStatusResponse) -> SNAUseCaseResponse {
    let quantumLeap = response.quantumLeap
    let timerSettings: TimerSettings? = (quantumLeap?.pollingRequired == true) ? quantumLeap?.timerSettings : nil

    let otplessResponses: [OtplessResponse]
    if response.authDetail.status == Constants.SUCCESS {
        if let quantumLeap = quantumLeap {
            otplessResponses = [
                OtplessResponse.mfaFactorCompleted(
                    authType: response.authDetail.channel,
                    communicationChannel: response.authDetail.communicationMode
                ),
                OtplessResponse.createSuccessfulInitiateResponse(
                    requestId: quantumLeap.channelAuthToken,
                    channel: Otpless.shared.authType,
                    authType: Otpless.shared.authType,
                    deliveryChannel: quantumLeap.communicationMode
                )
            ]
        } else if let oneTap = response.oneTap {
            otplessResponses = [
                OtplessResponse(
                    responseType: .ONETAP,
                    response: oneTap.toDict(),
                    statusCode: 200
                )
            ]
        } else {
            // Unexpected SUCCESS state: neither quantumLeap nor oneTap was returned,
            // so no alternative initiation can be surfaced. Surface a 9106 timeout-shaped
            // response so the host treats it the same as a final-status fallback.
            OtplessBMEvents.Exception.captured(
                where: "makeSnaUseCaseResponse",
                message: "SNA status=SUCCESS without quantumLeap or oneTap — emitting 9106 fallback"
            )
            otplessResponses = [
                OtplessResponse.createVerifyFailed(
                    statusCode: 9106,
                    response: [
                        "errorCode": "9106",
                        "errorMessage": "Silent Authentication failed."
                    ],
                    authType: SILENT_AUTH
                )
            ]
        }
    } else {
        var verifyFailedResponse: [String: Any] = [
            "errorCode": "400",
            "errorMessage": "Silent Authentication failed."
        ]
        // adding sna error block if available
        verifyFailedResponse[OtplessConstant.SnaErrorKey] = response.authDetail.snaError?.toDict()
        let failed = OtplessResponse.createVerifyFailed(
            statusCode: 400,
            response: verifyFailedResponse,
            authType: SILENT_AUTH
        )
        let second: OtplessResponse
        if let quantumLeap = quantumLeap {
            second = OtplessResponse.createSuccessfulInitiateResponse(
                requestId: quantumLeap.channelAuthToken,
                channel: Otpless.shared.authType,
                authType: Otpless.shared.authType,
                deliveryChannel: quantumLeap.communicationMode
            )
        } else {
            second = OtplessResponse.makeTerminalResponse(
                status: 400,
                error: String(OtplessConstant.EC.SNA_AUTH_FAILED),
                message: "Silent Authentication failed.",
                snaError: response.authDetail.snaError
            )
        }
        otplessResponses = [failed, second]
    }

    return SNAUseCaseResponse(
        tokenAsIdUIdAndTimerSettings: TokenAsIdUIdAndTimerSettings(
            token: quantumLeap?.channelAuthToken ?? "",
            asId: quantumLeap?.asId ?? "",
            uid: quantumLeap?.uid ?? "",
            timerSettings: timerSettings
        ),
        otplessResponse: otplessResponses
    )
}
