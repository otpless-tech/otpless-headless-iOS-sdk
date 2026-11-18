#if DEBUG
import Foundation

/// What Apple's UPI send completion should report, instead of whatever the real one does.
public enum OtplessSimulatedUpiCompletion: Sendable {
    /// Apple reports that the carrier accepted the SMS.
    case completes
    /// Apple reports that sending failed.
    case fails
}

internal final class SmsBindingDebugOverrides: @unchecked Sendable {
    static let shared = SmsBindingDebugOverrides()
    private let lock = NSLock()
    private var _upiCompletion: OtplessSimulatedUpiCompletion?

    var upiCompletion: OtplessSimulatedUpiCompletion? {
        get { lock.lock(); defer { lock.unlock() }; return _upiCompletion }
        set { lock.lock(); _upiCompletion = newValue; lock.unlock() }
    }
}

extension Otpless {
    /// **Debug builds only.** Without Apple's UPI Device Validation entitlement, Apple never calls the
    /// send completion, so a flow with R19 on can only end in `SMS_SEND_FAILED`. With this set, the real
    /// message composer still opens and a real SMS is still sent, but once the user has sent it the SDK
    /// behaves as if Apple had reported `mode`. That lets the R19 success path (and R21, which needs
    /// R19) be exercised on a phone whose app holds no entitlement. `nil` goes back to the real thing.
    public func simulateUpiCompletion(_ mode: OtplessSimulatedUpiCompletion?) {
        SmsBindingDebugOverrides.shared.upiCompletion = mode
    }
}
#endif
