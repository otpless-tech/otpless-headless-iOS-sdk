import Foundation

// MARK: - Public types

/// Where an outbound SMS binding attempt is. Delivered to `onProgress` on the main thread.
public enum OtplessSmsBindingProgress: String, Sendable {
    /// The backend issued a token and a number to send it to.
    case issued = "ISSUED"
    /// The SMS left the phone.
    case sent = "SENT"
    /// The backend received it.
    case received = "RECEIVED"
    case verified = "VERIFIED"
    case rejected = "REJECTED"
    case expired = "EXPIRED"
    case aborted = "ABORTED"
}

/// Why a binding attempt did not produce a binding. `code` is one of the reason strings in the
/// Outbound SMS binding PRD (section 15), plus `SDK_NOT_READY` and `ATTEMPT_IN_PROGRESS`.
public struct OtplessSmsBindingFailure: Error, Equatable, Sendable {
    public let code: String
    /// Whether trying again straight away can help.
    public let isRetryable: Bool
    /// The number being bound with its middle hidden (`+91 89xxxxxx55`), for wording such as "send it
    /// from the line with …". Nil when the failure has nothing to do with the number.
    public let maskedNumber: String?
    /// For `DEVICE_BLOCKED`: seconds until the user may try again, when known.
    public let retryAfterSeconds: Int?

    internal init(code: String, isRetryable: Bool, maskedNumber: String? = nil, retryAfterSeconds: Int? = nil) {
        self.code = code
        self.isRetryable = isRetryable
        self.maskedNumber = maskedNumber
        self.retryAfterSeconds = retryAfterSeconds
    }

    internal init(_ failure: SmsBindingFailure, maskedNumber: String? = nil, retryAfterSeconds: Int? = nil) {
        self.init(
            code: failure.rawValue, isRetryable: failure.isRetryable,
            maskedNumber: maskedNumber, retryAfterSeconds: retryAfterSeconds
        )
    }
}

public enum OtplessSmsBindingResult: Equatable, Sendable {
    /// - `bindingId`: the token the backend returned for the verified attempt.
    /// - `mobile`, `userId`: who was verified, as the backend reports them.
    case verified(bindingId: String?, mobile: String? = nil, userId: String? = nil)
    case failed(OtplessSmsBindingFailure)
}

// MARK: - Entry point

extension Otpless {

    /// Binds the user's SIM by having the phone send a one-time token by SMS from its own SIM.
    ///
    /// Behaviour follows the rules the backend serves for the app's client; the SDK never asks
    /// which template a client is on. Call after `initialise` has reported `SDK_READY`.
    ///
    /// - Parameters:
    ///   - phoneNumber: The number being bound, without its country code (`9812345621`).
    ///   - countryCode: Its country code (`+91` or `91`).
    ///   - upiEntitlementDeclared: Pass `true` only if the app holds Apple's UPI Device Validation
    ///     entitlement. iOS offers no way for the SDK to check this itself, so the SDK trusts the
    ///     declaration and the backend enforces it. With the rule on and `false` here the attempt
    ///     stops with `ENTITLEMENT_MISSING`; it never falls back to an editable message.
    ///   - ui: `.headless` (default) draws nothing of its own. `.standard` adds the dual-SIM prompt,
    ///     a "verifying" indicator and a "Try again" alert on failures that can be retried.
    ///   - onProgress: Called on the main thread as the attempt advances.
    ///   - completion: Called once, on the main thread, with the outcome. With `.standard` this is
    ///     after the user has dismissed a failure alert or stopped retrying.
    public func startSmsBinding(
        phoneNumber: String,
        countryCode: String,
        upiEntitlementDeclared: Bool = false,
        ui: OtplessSmsBindingUI = .headless,
        onProgress: (@Sendable (OtplessSmsBindingProgress) -> Void)? = nil,
        completion: @escaping @Sendable (OtplessSmsBindingResult) -> Void
    ) {
        func finish(_ result: OtplessSmsBindingResult) {
            DispatchQueue.main.async { completion(result) }
        }

        let code = "+" + countryCode.filter { $0.isNumber }
        let msisdn = code + phoneNumber.filter { $0.isNumber }
        guard PhoneNumberFormat.isE164(msisdn) else {
            return finish(.failed(OtplessSmsBindingFailure(code: "INVALID_PHONE_NUMBER", isRetryable: false)))
        }
        guard sdkState == .READY, let state = self.state else {
            return finish(.failed(OtplessSmsBindingFailure(code: "SDK_NOT_READY", isRetryable: true)))
        }
        guard isSmsBindingAvailable else {
            return finish(.failed(OtplessSmsBindingFailure(code: SmsBindingGate.notEnabledCode, isRetryable: false)))
        }
        guard SmsBindingRunGate.shared.tryBegin() else {
            return finish(.failed(OtplessSmsBindingFailure(code: "ATTEMPT_IN_PROGRESS", isRetryable: false)))
        }

        let masked = SmsBindingCopy.mask(countryCode: code, national: String(msisdn.dropFirst(code.count)))
        let backend = apiRepository.makeSmsBindingBackend()
        let prompter: SmsBindingPrompter = ui == .standard ? StandardSmsBindingPrompter() : HeadlessSmsBindingPrompter()
        Task {
            var outcome: SmsBindingOutcome
            var retryAfter: Int?
            while true {
                let useCase = SmsBindingUseCase(
                    backend: backend,
                    prompter: prompter,
                    lastAttempt: .shared,
                    blockMemory: .shared,
                    // The stable device id the SDK already reports with every request.
                    deviceFingerprintHash: { Otpless.shared.appInfo["deviceId"] as? String }
                )
                outcome = await useCase.run(
                    state: state,
                    msisdn: msisdn,
                    countryCode: code,
                    upiEntitlementDeclared: upiEntitlementDeclared,
                    onState: { reached in
                        guard let progress = OtplessSmsBindingProgress(rawValue: reached.rawValue) else { return }
                        DispatchQueue.main.async { onProgress?(progress) }
                    }
                )
                await prompter.hideProgress()
                retryAfter = useCase.lastRetryAfterSeconds
                guard case .failed(let failure) = outcome,
                      await prompter.offerRetry(
                        failure, context: SmsBindingFailureContext(maskedNumber: masked, retryAfterSeconds: retryAfter)
                      ) else { break }
            }
            SmsBindingRunGate.shared.end()
            switch outcome {
            case .verified(let bindingId, let mobile, let userId): finish(.verified(bindingId: bindingId, mobile: mobile, userId: userId))
            case .failed(let failure):
                finish(.failed(OtplessSmsBindingFailure(
                    failure,
                    maskedNumber: failure == .numberMismatch ? masked : nil,
                    retryAfterSeconds: failure == .deviceBlocked ? retryAfter : nil
                )))
            }
        }
    }

    /// The merchant config switches the feature on per app. Until it does, nothing is sent to the
    /// backend.
    internal var isSmsBindingAvailable: Bool {
        SmsBindingGate.isOpen(merchantConfig: merchantConfig)
    }
}

internal enum SmsBindingGate {
    /// Returned when the app's config has not switched outbound SMS binding on.
    static let notEnabledCode = "FEATURE_NOT_ENABLED"

    static func isOpen(merchantConfig: MerchantConfigResponse?) -> Bool {
        merchantConfig?.isOutboundSmsBindingEnabled == true
    }
}

/// One binding attempt at a time: two composers cannot be on screen, and the backend counts
/// attempts per device (R10).
private final class SmsBindingRunGate: @unchecked Sendable {
    static let shared = SmsBindingRunGate()
    private let lock = NSLock()
    private var running = false

    func tryBegin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    func end() {
        lock.lock()
        running = false
        lock.unlock()
    }
}
