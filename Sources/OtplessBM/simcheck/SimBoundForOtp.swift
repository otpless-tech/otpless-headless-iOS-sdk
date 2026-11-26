import Foundation

/// What the verify-OTP call says about the SIM on iOS 27 and above (ENG-628 item 4, as the backend
/// specified it): `simBound`, true or false. `simBound = false` fails the transaction, so it is sent
/// only when the answer is certain.
///
/// - bound: `true`.
/// - notBound: `false`.
/// - unknown (no permission, restricted, low confidence, an Apple error) or any other case: nothing
///   is sent. The login is never failed on a guess. The permission is not asked here: the app asks
///   for it after number entry (`requestNumberStatusPermission`), and an unanswered permission reads
///   as unknown.
internal enum SimBoundForOtp {

    static func value(
        smsBindingEnabled: Bool,
        provider: PlanStatusProvider,
        countryCode: String?,
        phoneNumber: String?
    ) async -> Bool? {
        guard let number = e164(smsBindingEnabled: smsBindingEnabled, provider: provider, countryCode: countryCode, phoneNumber: phoneNumber),
              case .success(let check) = await SimBindingChecker(provider: provider).check(phoneNumber: number) else { return nil }
        switch check.status {
        case .bound: return true
        case .notBound: return false
        case .unknown: return nil
        }
    }

    /// The number to check, or nil when this flow does not take part: the app is not set up for SMS
    /// binding, the device has no plan status API, or the request is not a phone request.
    static func e164(
        smsBindingEnabled: Bool,
        provider: PlanStatusProvider,
        countryCode: String?,
        phoneNumber: String?
    ) -> String? {
        guard smsBindingEnabled, provider.isSupported, let phone = phoneNumber else { return nil }
        let code = (countryCode ?? "").filter { $0.isNumber }
        let digits = phone.filter { $0.isNumber }
        guard !code.isEmpty, !digits.isEmpty else { return nil }
        return "+" + code + digits
    }

    /// The verify body with `simBound` added as a real boolean, only when there is an answer.
    static func body(_ base: [String: Any], simBound: Bool?) -> [String: Any] {
        guard let simBound else { return base }
        var body = base
        body["simBound"] = simBound
        return body
    }
}
