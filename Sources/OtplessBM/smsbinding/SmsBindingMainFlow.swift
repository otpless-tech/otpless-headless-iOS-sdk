import Foundation

/// SMS binding inside the normal login flow. The backend's orchestration can answer a normal intent as
/// `SIM_BINDING` (outbound SMS is the last step after SNA and OTP). The app then sees the usual
/// responses: `INITIATE` with `authType: SIM_BINDING`, `DELIVERY_STATUS` once the message is sent, and
/// then `ONETAP` with the session, or an error.
internal enum SmsBindingMainFlow {
    static let authType = "SIM_BINDING"
    static let deliveryChannel = "OUTBOUND_SMS"

    /// The number of the request, E.164. SIM binding is a phone flow: an email request has none.
    static func e164(countryCode: String?, phoneNumber: String?) -> String? {
        let code = (countryCode ?? "").filter { $0.isNumber }
        let digits = (phoneNumber ?? "").filter { $0.isNumber }
        guard !code.isEmpty, !digits.isEmpty else { return nil }
        return "+" + code + digits
    }

    /// The message has left the phone, as the other channels say when they have delivered.
    static var deliveredResponse: OtplessResponse {
        OtplessResponse(
            responseType: .DELIVERY_STATUS,
            response: ["deliveryChannel": deliveryChannel, "authType": authType, "communicationDelivered": true],
            statusCode: 200
        )
    }

    static func response(for outcome: SmsBindingOutcome) -> OtplessResponse {
        switch outcome {
        case .failed(let failure):
            return errorResponse(failure)
        case .verified(_, _, _, let payload):
            // The success is a login: hand the app its session, as every other channel does.
            guard let payload,
                  let status = try? JSONDecoder().decode(TransactionStatusResponse.self, from: payload),
                  let oneTap = status.oneTap else { return errorResponse(.internalError) }
            return OtplessResponse(responseType: .ONETAP, response: oneTap.toDict(), statusCode: 200)
        }
    }

    /// Shaped like the other verify errors: `errorCode`, `errorMessage` and `authType`, plus whether
    /// trying again can help.
    static func errorResponse(_ failure: SmsBindingFailure) -> OtplessResponse {
        OtplessResponse(
            responseType: .VERIFY,
            response: [
                "errorCode": failure.rawValue,
                "errorMessage": SmsBindingCopy.failure(code: failure.rawValue),
                "authType": authType,
                "retryable": failure.isRetryable
            ],
            statusCode: 400
        )
    }
}

extension Otpless {
    /// Runs the SMS flow for an intent the backend answered as SIM binding, then reports as above. Not
    /// used by `startSmsBinding`, which asks for the attempt itself.
    func runSmsBindingFromIntent(_ started: SmsBindingStarted, _ request: OtplessRequest) async {
        guard let state = self.state,
              let msisdn = SmsBindingMainFlow.e164(countryCode: request.getCountryCode(), phoneNumber: request.getPhone()) else {
            return invokeResponse(SmsBindingMainFlow.errorResponse(.notAvailable))
        }
        guard SmsBindingRunGate.shared.tryBegin() else {
            return invokeResponse(OtplessResponse(
                responseType: .VERIFY,
                response: ["errorCode": "ATTEMPT_IN_PROGRESS", "errorMessage": "A SIM binding attempt is already running.", "authType": SmsBindingMainFlow.authType],
                statusCode: 409
            ))
        }

        let useCase = SmsBindingUseCase(
            backend: apiRepository.makeSmsBindingBackend(),
            prompter: HeadlessSmsBindingPrompter(),
            lastAttempt: .shared,
            boundNumbers: SimCheckEnvironment.boundNumbers,
            blockMemory: .shared,
            deviceFingerprintHash: { Otpless.shared.appInfo["deviceId"] as? String }
        )
        let outcome = await useCase.continueAttempt(
            state: state,
            msisdn: msisdn,
            started: started,
            upiEntitlementDeclared: UpiEntitlementDeclaration.shared.declared,
            onState: { [weak self] reached in
                if reached == .sent { DispatchQueue.main.async { self?.invokeResponse(SmsBindingMainFlow.deliveredResponse) } }
            }
        )
        SmsBindingRunGate.shared.end()
        invokeResponse(SmsBindingMainFlow.response(for: outcome))
    }
}
