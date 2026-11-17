import Foundation

// MARK: - Public types (ENG-628)

/// Whether the number is on a plan that is active on this device.
public enum OtplessSimBindingStatus: String, Sendable {
    /// An active plan for the number exists on this device, and the system is confident.
    case bound = "BOUND"
    /// The system is confident the number has no active plan on this device.
    case notBound = "NOT_BOUND"
    /// The SDK cannot tell. `OtplessSimBindingCheck.reason` says why.
    case unknown = "UNKNOWN"
}

/// Why a check came back `unknown`.
public enum OtplessSimBindingUnknownReason: String, Sendable {
    /// The user has not allowed the check for this number, or said no. iOS does not tell the two apart.
    case notAuthorized = "NOT_AUTHORIZED"
    /// The system's confidence in its answer is low.
    case lowConfidence = "LOW_CONFIDENCE"
    /// The feature is unavailable for this number (for example a number from a region that is not supported).
    case restricted = "RESTRICTED"
    /// Apple's API failed or did not answer.
    case apiError = "API_ERROR"
}

public struct OtplessSimBindingCheck: Equatable, Sendable {
    public let status: OtplessSimBindingStatus
    /// Set only when `status` is `.unknown`.
    public let reason: OtplessSimBindingUnknownReason?

    internal init(_ status: OtplessSimBindingStatus, reason: OtplessSimBindingUnknownReason? = nil) {
        self.status = status
        self.reason = reason
    }

    internal static func unknown(_ reason: OtplessSimBindingUnknownReason) -> OtplessSimBindingCheck {
        OtplessSimBindingCheck(.unknown, reason: reason)
    }

    /// Stable text used to tell whether two checks are the same result.
    internal var signature: String {
        reason.map { "\(status.rawValue):\($0.rawValue)" } ?? status.rawValue
    }
}

/// The user's answer to Apple's "check the phone number on this device?" prompt.
public enum OtplessNumberStatusPermission: String, Sendable {
    case granted = "GRANTED"
    case denied = "DENIED"
    /// Nothing can be asked: restricted for this number, or Apple's API failed.
    case unavailable = "UNAVAILABLE"
}

/// The SIM check could not run at all (as opposed to running and being unsure).
public struct OtplessSimCheckError: Error, Equatable, Sendable {
    public let code: String

    /// This iOS version does not have Apple's plan status API (it arrives with iOS 27).
    public static let notSupported = OtplessSimCheckError(code: "SIM_CHECK_NOT_SUPPORTED")
    /// The number is not in E.164 form (`+919812345621`).
    public static let invalidPhoneNumber = OtplessSimCheckError(code: "INVALID_PHONE_NUMBER")
}

// MARK: - Apple's values

/// `CTCellularPlanStatusAuthorization`. Raw values observed on an iOS 27.0.1 device:
/// 0 not authorized (including never asked), 1 authorized, 2 restricted. Anything else is treated
/// as "not supported", the only other case Apple documents.
internal enum PlanAuthorization: Equatable, Sendable {
    case notAuthorized, authorized, restricted, notSupported

    init(rawValue: Int) {
        switch rawValue {
        case 0: self = .notAuthorized
        case 1: self = .authorized
        case 2: self = .restricted
        default: self = .notSupported
        }
    }
}

/// `CTCellularPlanStatusAvailability` and `CTCellularPlanStatusAvailabilityConfidence` together.
/// Raw 1 is `available` / `high`; anything else is `unavailable` / `low`.
internal struct PlanHint: Equatable, Sendable {
    let available: Bool
    let highConfidence: Bool

    init(available: Bool, highConfidence: Bool) {
        self.available = available
        self.highConfidence = highConfidence
    }

    init(availabilityRaw: Int, confidenceRaw: Int) {
        self.init(available: availabilityRaw == 1, highConfidence: confidenceRaw == 1)
    }
}

internal enum PlanStatusError: Error, Equatable, Sendable {
    /// Apple's API is not on this device.
    case unavailable
    /// Apple's API answered with an error (observed: `NSCocoaErrorDomain` 4097, "helper application").
    case system
    /// Apple's API never called back.
    case timeout
}

// MARK: - Seam

/// Apple's iOS 27 plan status API. A seam so the mapping is tested without an iOS 27 phone.
internal protocol PlanStatusProvider: Sendable {
    /// The class and all three methods are present on this device.
    var isSupported: Bool { get }
    /// No UI. Never asked and denied both come back as `.notAuthorized`.
    func authorizationStatus(for phoneNumber: String) async throws -> PlanAuthorization
    /// May show Apple's permission dialog.
    func requestAuthorization(for phoneNumber: String) async throws -> PlanAuthorization
    func hint(for phoneNumber: String) async throws -> PlanHint
}

internal enum PhoneNumberFormat {
    /// E.164: `+`, a non-zero first digit, 7 to 15 digits in all.
    static func isE164(_ value: String) -> Bool {
        guard value.hasPrefix("+") else { return false }
        let digits = value.dropFirst()
        return (7...15).contains(digits.count) && digits.first != "0" && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
