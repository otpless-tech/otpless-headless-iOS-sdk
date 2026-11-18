import Foundation

/// Why an outbound SMS binding attempt ended without a binding. The raw values are the stable
/// reason strings from PRD section 15 and travel to and from the backend unchanged.
internal enum SmsBindingFailure: String, Error, Equatable, Sendable {
    case permissionMissing = "PERMISSION_MISSING"
    case noSim = "NO_SIM"
    case airplaneMode = "AIRPLANE_MODE"
    case upgradeRequired = "UPGRADE_REQUIRED"
    case entitlementMissing = "ENTITLEMENT_MISSING"
    case unsafeSmsApp = "UNSAFE_SMS_APP"
    case smsSendFailed = "SMS_SEND_FAILED"
    case numberMismatch = "NUMBER_MISMATCH"
    case tokenExpired = "TOKEN_EXPIRED"
    case sessionInterrupted = "SESSION_INTERRUPTED"
    case deviceBlocked = "DEVICE_BLOCKED"
    case vmnPoolUnavailable = "VMN_POOL_UNAVAILABLE"
    /// Backend rejected the attempt for a reason the SDK does not act on (unknown token, wrong
    /// VMN, token reuse). Kept generic on purpose so verifier details never leak to the app.
    case verificationFailed = "VERIFICATION_FAILED"
    /// The SDK could not complete the call itself (network error, undecodable response).
    case internalError = "INTERNAL_ERROR"
    /// The backend did not route this request to SIM binding (for example the app is not set up
    /// for it), so nothing was sent to the user.
    case notAvailable = "SIM_BINDING_NOT_AVAILABLE"
    /// The backend rejected the phone number as invalid (7102).
    case invalidPhoneNumber = "INVALID_PHONE_NUMBER"

    /// Maps a backend `reason` string. Anything unrecognised becomes `verificationFailed`.
    init(backendReason: String?) {
        guard let reason = backendReason, let known = SmsBindingFailure(rawValue: reason) else {
            self = .verificationFailed
            return
        }
        self = known
    }

    /// Whether the user can sensibly try again straight away (PRD section 15, "What the app should do").
    var isRetryable: Bool {
        switch self {
        case .permissionMissing, .smsSendFailed, .numberMismatch, .tokenExpired, .sessionInterrupted:
            return true
        case .noSim, .airplaneMode, .upgradeRequired, .entitlementMissing, .unsafeSmsApp,
             .deviceBlocked, .vmnPoolUnavailable, .verificationFailed, .internalError, .notAvailable, .invalidPhoneNumber:
            return false
        }
    }
}
