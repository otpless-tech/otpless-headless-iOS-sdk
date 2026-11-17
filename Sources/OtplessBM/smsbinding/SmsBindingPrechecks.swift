import Foundation

/// What the device-side rules need to know about the phone. A seam, so the checks are tested
/// without a SIM: `CTTelephonyNetworkInfo` and `MFMessageComposeViewController` are fakes in tests.
internal protocol SmsBindingDevice: Sendable {
    var osVersion: String { get }
    var appVersion: String { get }
    /// `serviceCurrentRadioAccessTechnology` is non-empty: a SIM is present and on a network.
    /// iOS has no airplane-mode API, but airplane mode empties this, so one signal covers R7 and R8.
    var hasCellularRadio: Bool { get }
    /// `MFMessageComposeViewController.canSendText()`.
    var canSendText: Bool { get }
    /// How many lines (physical SIM or eSIM) are on a network. More than one means the user must
    /// send from the line that holds the number being bound.
    var activeLineCount: Int { get }
}

extension SmsBindingDevice {
    var activeLineCount: Int { 1 }
}

/// The device rules that run **before** any token is requested (PRD section 11, step 1).
/// Failing here costs the user nothing: no attempt is created and nothing is sent.
internal enum SmsBindingPrechecks {

    /// Returns the first failing rule, or nil when the attempt may proceed. Order is fixed so the
    /// user always sees the most actionable problem first: upgrade, then SIM, then integration.
    ///
    /// - Parameter upiEntitlementDeclared: the host app's own declaration that it holds the UPI
    ///   Device Validation entitlement. iOS exposes no public API to read an app's entitlements,
    ///   and without the entitlement the composer silently stays editable, so the SDK can only
    ///   trust (and forward) this declaration; the backend enforces it as well.
    static func evaluate(
        rules: SmsBindingRules,
        device: SmsBindingDevice,
        upiEntitlementDeclared: Bool
    ) -> SmsBindingFailure? {
        // R11 / R12
        if let minimumApp = rules.minimumAppVersion,
           !SmsBindingVersion.isAtLeast(device.appVersion, minimum: minimumApp) {
            return .upgradeRequired
        }
        if let minimumOS = rules.minimumOSVersion,
           !SmsBindingVersion.isAtLeast(device.osVersion, minimum: minimumOS) {
            return .upgradeRequired
        }

        // R7 / R8: one SIM signal. Airplane mode is indistinguishable from "no SIM" on iOS, so
        // both report NO_SIM. `canSendText` is false on devices that cannot send SMS at all.
        if rules.isOn(.simPresent) || rules.isOn(.airplaneModeBlock) {
            if !device.hasCellularRadio { return .noSim }
        }
        if !device.canSendText { return .noSim }

        // R19: never fall back silently. If the rule is on and the host did not declare the
        // entitlement, stop with an integration error.
        if rules.requiresUpiEntitlement && !upiEntitlementDeclared {
            return .entitlementMissing
        }
        return nil
    }
}
