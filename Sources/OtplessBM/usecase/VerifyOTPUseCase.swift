//
//  VerifyOTPUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//


import Foundation

/// What a verify call came to: the response for the app, or, when the backend ends the OTP and names SMS binding as the
/// next channel (the SIM is not bound), the attempt to carry on with.
struct VerifyOutcome {
    let response: OtplessResponse
    let nextSmsBinding: NextSmsBinding?
}

/// SMS binding offered as the next channel by a failed verify, with the ids of the new attempt.
struct NextSmsBinding {
    let started: SmsBindingStarted
    let token: String
    let asId: String
    let uid: String
}

class VerifyOTPUseCase {
    func invoke(
        state: String,
        queryParams: [String: String],
        simBound: Bool? = nil,
        getTransactionStatusUseCase: TransactionStatusUseCase
    ) async -> VerifyOutcome {
        log(message: "[VerifyOTP] Submitting OTP — authType: \(Otpless.shared.authType), rsId: \(Otpless.shared.rsId.isEmpty ? "<none>" : Otpless.shared.rsId)", type: .VERIFY)

        let response = await Otpless.shared.apiRepository
            .verifyOTP(queryParams: queryParams, state: state, simBound: simBound)

        switch response {
        case .failure(let error):
            guard let apiError = error as? ApiError else {
                log(message: "[VerifyOTP] Failed — \(error.localizedDescription)", type: .API_RESPONSE_FAILURE)
                return VerifyOutcome(response: OtplessResponse(
                    responseType: .VERIFY,
                    response: Utils.createErrorDictionary(
                        errorCode: "500",
                        errorMessage: error.localizedDescription,
                        authType: Otpless.shared.authType
                    ), statusCode: 500
                ), nextSmsBinding: nil)
            }
            log(message: "[VerifyOTP] Failed — statusCode: \(apiError.statusCode), error: \(apiError.localizedDescription)", type: .API_RESPONSE_FAILURE)
            var response = apiError.getResponse()
            response["authType"] = Otpless.shared.authType
            return VerifyOutcome(response: OtplessResponse(responseType: .VERIFY, response: response, statusCode: apiError.statusCode), nextSmsBinding: nil)

        case .success(let data):
            return VerifyOutcome(response: Self.response(for: data), nextSmsBinding: Self.nextSmsBinding(from: data))
        }
    }

    /// A verify the backend failed (for example `SIM_NOT_BOUND` after an `OTP_BIND` code) can carry the next channel in
    /// `quantumLeap`, as silent auth's failed status does. When that channel is SMS binding and its data is complete,
    /// the sign-in carries on there instead of ending.
    static func nextSmsBinding(from data: TransactionStatusResponse) -> NextSmsBinding? {
        guard data.authDetail.status == Constants.FAILED, let leap = data.quantumLeap,
              case .started(let started) = SmsBindingStarted.parse(quantumLeap: leap.simBindingDictionary()) else { return nil }
        return NextSmsBinding(started: started, token: leap.channelAuthToken, asId: leap.asId, uid: leap.uid ?? "")
    }

    /// The backend answers a verify with HTTP 200 even when it ends the transaction (for example
    /// `SIM_NOT_BOUND` after a `simBound: false`). Only a SUCCESS status is a sign-in.
    static func response(for data: TransactionStatusResponse) -> OtplessResponse {
        if data.authDetail.status == Constants.FAILED {
            log(message: "[VerifyOTP] Transaction FAILED — \(data.authDetail.errorCode ?? "no reason"): \(data.authDetail.errorDetails ?? "")", type: .VERIFY)
            return OtplessResponse.terminalResponse(forFailed: data.authDetail)
        }
        log(message: "[VerifyOTP] Succeeded — ONETAP received", type: .VERIFY)
        return OtplessResponse(
            responseType: .ONETAP,
            response: data.oneTap?.toDict(),
            statusCode: 200
        )
    }
}
