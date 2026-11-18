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

    internal init(code: String, isRetryable: Bool) {
        self.code = code
        self.isRetryable = isRetryable
    }

    internal init(_ failure: SmsBindingFailure) {
        self.init(code: failure.rawValue, isRetryable: failure.isRetryable)
    }
}

public enum OtplessSmsBindingResult: Equatable, Sendable {
    case verified(bindingId: String?)
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

        let backend = smsBindingBackend()
        let prompter: SmsBindingPrompter = ui == .standard ? StandardSmsBindingPrompter() : HeadlessSmsBindingPrompter()
        Task {
            var outcome: SmsBindingOutcome
            while true {
                let useCase = SmsBindingUseCase(
                    backend: backend,
                    prompter: prompter,
                    lastAttempt: .shared,
                    // The stable device id the SDK already reports with every request.
                    deviceFingerprintHash: { Otpless.shared.appInfo["deviceId"] as? String }
                )
                outcome = await useCase.run(
                    state: state,
                    msisdn: msisdn,
                    countryCode: code,
                    upiEntitlementDeclared: upiEntitlementDeclared,
                    onState: { reached in
                        if reached == .sent { prompter.showVerifying() }
                        guard let progress = OtplessSmsBindingProgress(rawValue: reached.rawValue) else { return }
                        DispatchQueue.main.async { onProgress?(progress) }
                    }
                )
                await prompter.hideVerifying()
                guard case .failed(let failure) = outcome, await prompter.offerRetry(failure) else { break }
            }
            SmsBindingRunGate.shared.end()
            switch outcome {
            case .verified(let bindingId): finish(.verified(bindingId: bindingId))
            case .failed(let failure): finish(.failed(OtplessSmsBindingFailure(failure)))
            }
        }
    }

    /// The merchant config switches the feature on per app. A Debug build that chose a mock backend
    /// skips this: the mock never talks to the network, and is how the flow is tested before an
    /// app is onboarded.
    internal var isSmsBindingAvailable: Bool {
        #if DEBUG
        if SmsBindingMockSwitch.shared.current != nil { return true }
        #endif
        return SmsBindingGate.isOpen(merchantConfig: merchantConfig)
    }

    /// The backend the flow talks to: the real one, unless a Debug build chose a mock.
    internal func smsBindingBackend() -> SmsBindingBackend {
        #if DEBUG
        if let mock = SmsBindingMockSwitch.shared.current { return mock }
        #endif
        return apiRepository.makeSmsBindingBackend()
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

#if DEBUG
/// Holds the mock a Debug build selected.
internal final class SmsBindingMockSwitch: @unchecked Sendable {
    static let shared = SmsBindingMockSwitch()
    private let lock = NSLock()
    private var backend: SmsBindingBackend?

    var current: SmsBindingBackend? {
        lock.lock()
        defer { lock.unlock() }
        return backend
    }

    func set(_ backend: SmsBindingBackend?) {
        lock.lock()
        self.backend = backend
        lock.unlock()
    }
}

extension Otpless {
    /// **Debug builds only.** Answers every outbound SMS binding backend call from a fixed script
    /// instead of the network, so each outcome can be tested before the backend exists.
    ///
    /// - Parameters:
    ///   - scenario: Which outcome to play.
    ///   - vmn: The number the SMS is addressed to. The composer sends a real SMS to it; use a
    ///     number you own.
    public func useMockSmsBinding(_ scenario: OtplessSmsBindingMockScenario, vmn: String) {
        SmsBindingMockSwitch.shared.set(MockSmsBindingBackend(scenario: scenario, vmn: vmn))
    }

    /// **Debug builds only.** Goes back to the real backend.
    public func useLiveSmsBinding() {
        SmsBindingMockSwitch.shared.set(nil)
    }
}
#endif
