import Foundation
import UIKit

/// The device context ENG-627 asks the SDK to send at flow start, so orchestration can route an iOS
/// flow by what the device can do (iOS 27 plan-status flow, or SNA then Outbound SMS) and not by the
/// OS version alone.
internal enum SimDeviceContext {

    /// `platform`, `os_version`, `plan_status_supported` (the iOS 27 plan status API is present and
    /// usable) and `upi_entitlement` (the host's declaration that its app holds Apple's UPI Device
    /// Validation entitlement), under the names ENG-627 gives.
    static func dictionary(
        platform: String = SmsBindingMainFlow.platform,
        osVersion: String,
        planStatusSupported: Bool,
        upiEntitlement: Bool
    ) -> [String: Any] {
        [
            "platform": platform,
            "os_version": osVersion,
            "plan_status_supported": planStatusSupported,
            "upi_entitlement": upiEntitlement
        ]
    }

    /// The context for a normal intent, or nil unless the app has switched SMS binding on. Apps that
    /// have not been set up send exactly the intent they sent before.
    static func forIntent(
        smsBindingEnabled: Bool,
        osVersion: String,
        planStatusSupported: Bool,
        upiEntitlement: Bool
    ) -> [String: Any]? {
        guard smsBindingEnabled else { return nil }
        return dictionary(osVersion: osVersion, planStatusSupported: planStatusSupported, upiEntitlement: upiEntitlement)
    }
}

/// The host's declaration, for every flow, that its app holds the UPI Device Validation entitlement.
/// iOS gives an app no way to read its own entitlements, so the SDK takes the host's word.
internal final class UpiEntitlementDeclaration: @unchecked Sendable {
    static let shared = UpiEntitlementDeclaration()
    private let lock = NSLock()
    private var _declared = false

    var declared: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _declared }
        set { lock.lock(); _declared = newValue; lock.unlock() }
    }
}

extension Otpless {
    /// Declares, for every flow, whether this app holds Apple's UPI Device Validation entitlement
    /// (`com.apple.developer.upi-device-validation`). The SDK sends it with the device context so the
    /// backend can route the flow, and the SMS binding flow uses it for the UPI rule. Call it once,
    /// before starting a flow. Declare `true` only if the entitlement is really in the app.
    public func setUpiEntitlementDeclared(_ declared: Bool) {
        UpiEntitlementDeclaration.shared.declared = declared
    }

    /// The device context for a normal intent, nil when SMS binding is not switched on for the app.
    internal func deviceContextForIntent() -> [String: Any]? {
        SimDeviceContext.forIntent(
            smsBindingEnabled: isSmsBindingAvailable,
            osVersion: UIDevice.current.systemVersion,
            planStatusSupported: LivePlanStatusProvider().isSupported,
            upiEntitlement: UpiEntitlementDeclaration.shared.declared
        )
    }
}
