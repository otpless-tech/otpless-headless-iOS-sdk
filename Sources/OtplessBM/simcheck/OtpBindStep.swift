import Foundation

/// `OTP_BIND`: an OTP sign-in that also binds the SIM (iOS 27+, ENG-628 item 4). When the backend
/// routes the sign-in here, whether straight from the intent or after silent auth failed, the SDK settles Apple's permission to check the number **before** the app is told to
/// show the OTP screen, so the check after the OTP has an answer.
///
/// It asks Apple's dialog only when the user has not decided: the check is silent, and a permission already held
/// is never asked for again (Apple would show the dialog again, and Not Now would take the permission away).
/// The answer never blocks the OTP: with no permission the SDK simply sends no `simBound`.
internal enum OtpBindStep {
    static let channel = "OTP_BIND"

    /// An `INITIATE` that says the code goes with a SIM bind. Staging names it in `deliveryChannel` (the
    /// communication mode) while `channel` stays `OTP`; a backend that names it in `channel` is read too.
    static func isOtpBind(_ response: OtplessResponse?) -> Bool {
        guard response?.responseType == .INITIATE, let body = response?.response else { return false }
        return (body["deliveryChannel"] as? String) == channel || (body["channel"] as? String) == channel
    }

    /// Settles the permission for `e164`. Returns nil when there is nothing to settle: no number (an email
    /// request) or no plan status API on this device (before iOS 27).
    @discardableResult
    static func settlePermission(provider: PlanStatusProvider, e164: String?) async -> OtplessNumberStatusPermission? {
        guard let e164, provider.isSupported else { return nil }
        guard case .success(let permission) = await SimBindingChecker(provider: provider).requestPermission(phoneNumber: e164) else {
            return nil
        }
        return permission
    }
}
