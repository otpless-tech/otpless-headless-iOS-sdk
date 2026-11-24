import Foundation

/// How much of the experience the SDK draws.
enum OtplessSmsBindingUI: Sendable {
    /// No SDK screens besides Apple's message composer. The app uses the callbacks and, if it
    /// wants, `OtplessSmsBindingFailure.message` for wording.
    case headless
    /// The SDK also explains the step before sending (and names the line on a dual-SIM phone),
    /// shows progress with a countdown after the message is sent, and offers "Try again" on a
    /// failure that can be retried.
    case standard
}

extension OtplessSmsBindingFailure {
    /// A sentence fit to show the user for this failure. It names the number to send from when the
    /// message came from a different one, and says how long a block lasts when that is known.
    var message: String {
        SmsBindingCopy.failure(
            code: code,
            context: SmsBindingFailureContext(maskedNumber: maskedNumber, retryAfterSeconds: retryAfterSeconds)
        )
    }
}

/// What the wording of a failure can use beyond its code.
internal struct SmsBindingFailureContext: Equatable, Sendable {
    /// The number being bound with the middle hidden, `+91 89xxxxxx55`.
    var maskedNumber: String?
    /// How long until the user may try again, when known.
    var retryAfterSeconds: Int?

    init(maskedNumber: String? = nil, retryAfterSeconds: Int? = nil) {
        self.maskedNumber = maskedNumber
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// User-facing wording. One place, so it can be checked against the PRD's copy and translated
/// without touching the flow.
internal enum SmsBindingCopy {
    // Before sending (PRD section 17)
    static let preSendTitle = "Verify your number"
    static let preSendCharges = "We'll send a verification SMS from this SIM. Standard SMS charges may apply."
    static let preSendPrefilled = "You'll see a message already filled in. Tap Send without changing it."
    static func dualSimLine(lastDigits: String) -> String {
        "This phone has more than one active line. Send from the SIM that has the number ending in \(lastDigits)."
    }
    static func preSendMessage(lastDigits: String, dualSim: Bool) -> String {
        ([preSendCharges] + (dualSim ? [dualSimLine(lastDigits: lastDigits)] : []) + [preSendPrefilled])
            .joined(separator: "\n\n")
    }

    // Progress (PRD section 17: sent, received, verified, with a countdown tied to the token's life)
    static let progressTitle = "Verifying your number…"
    static let stepSent = "Message sent"
    static let stepReceived = "Message received"
    static let stepVerified = "Number verified"
    static func timeLeft(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return "Time left \(clamped / 60):" + String(format: "%02d", clamped % 60)
    }

    static let continueButton = "Continue"
    static let cancelButton = "Cancel"
    static let retryButton = "Try again"
    static let closeButton = "Close"
    static let failureTitle = "Couldn't verify your number"

    /// `+91 89xxxxxx55`: the country code, the first two digits, the last two, the rest hidden.
    static func mask(countryCode: String, national: String) -> String {
        let code = "+" + countryCode.filter { $0.isNumber }
        let digits = national.filter { $0.isNumber }
        guard digits.count >= 6 else { return code + " " + String(repeating: "x", count: digits.count) }
        return code + " " + digits.prefix(2) + String(repeating: "x", count: digits.count - 4) + digits.suffix(2)
    }

    /// "6 hours", "45 minutes", "1 hour".
    static func duration(seconds: Int) -> String {
        if seconds >= 3600 {
            let hours = Int((Double(seconds) / 3600).rounded())
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    static func failure(code: String, context: SmsBindingFailureContext = SmsBindingFailureContext()) -> String {
        switch SmsBindingFailure(rawValue: code) {
        case .permissionMissing?: return "Allow the app to send messages, then try again."
        // iOS cannot tell airplane mode from no SIM: both leave no cellular signal.
        case .noSim?: return "No SIM card was found, or airplane mode is on. Insert a SIM or turn off airplane mode, then try again."
        case .airplaneMode?: return "Turn off airplane mode and try again."
        case .upgradeRequired?: return "Please update the app to continue."
        case .entitlementMissing?: return "This app isn't set up for SIM verification. Please contact support."
        case .unsafeSmsApp?: return "Switch your default messaging app and try again."
        case .smsSendFailed?: return "The message wasn't sent. Please try again."
        case .numberMismatch?:
            if let masked = context.maskedNumber {
                return "This SMS came from a different number. Send it from the line with \(masked)."
            }
            return "This SMS came from a different number. Send it from the SIM that has the number you entered."
        case .tokenExpired?: return "This took too long. Please try again."
        case .sessionInterrupted?: return "Verification was interrupted. Please try again."
        case .deviceBlocked?:
            if let seconds = context.retryAfterSeconds, seconds > 0 {
                return "Too many attempts. You can try again in about \(duration(seconds: seconds))."
            }
            return "Too many attempts. Please try again later."
        case .vmnPoolUnavailable?: return "Verification isn't available right now. Please try another way."
        case .verificationFailed?: return "We couldn't verify your number."
        case .invalidPhoneNumber?: return "That phone number doesn't look right. Check it and try again."
        case .notAvailable?: return "SIM verification isn't available right now. Please try another way."
        case .internalError?, nil: return "Something went wrong. Please try again."
        }
    }
}

// MARK: - Seam

/// The SDK's own screens. Headless mode uses the version that does nothing.
internal protocol SmsBindingPrompter: Sendable {
    /// Before the attempt exists, so declining costs nothing. Explains the step; on a dual-SIM phone
    /// it also names the line to send from. False means the user declined.
    func confirmBeforeSend(lastDigits: String, dualSim: Bool) async -> Bool
    /// Synchronous, and queued on the main thread at once, so a `hideProgress` called later can
    /// never run before it. `expiresAt` drives the countdown.
    func showProgress(expiresAt: Date)
    /// Marks the steps reached so far.
    func updateProgress(_ state: SmsBindingState)
    func hideProgress() async
    /// Shows `failure`. Returns true if the user chose to try again.
    func offerRetry(_ failure: SmsBindingFailure, context: SmsBindingFailureContext) async -> Bool
}

internal struct HeadlessSmsBindingPrompter: SmsBindingPrompter {
    func confirmBeforeSend(lastDigits: String, dualSim: Bool) async -> Bool { true }
    func showProgress(expiresAt: Date) {}
    func updateProgress(_ state: SmsBindingState) {}
    func hideProgress() async {}
    func offerRetry(_ failure: SmsBindingFailure, context: SmsBindingFailureContext) async -> Bool { false }
}

#if os(iOS)
import UIKit

// MARK: - Standard UI

internal final class StandardSmsBindingPrompter: SmsBindingPrompter, @unchecked Sendable {

    private let presenter: @Sendable @MainActor () -> UIViewController?
    @MainActor private var overlay: ProgressOverlay?

    init(presenter: @escaping @Sendable @MainActor () -> UIViewController? = LiveSmsBindingComposer.topViewController) {
        self.presenter = presenter
    }

    func confirmBeforeSend(lastDigits: String, dualSim: Bool) async -> Bool {
        await ask(
            title: SmsBindingCopy.preSendTitle,
            message: SmsBindingCopy.preSendMessage(lastDigits: lastDigits, dualSim: dualSim),
            confirm: SmsBindingCopy.continueButton,
            dismiss: SmsBindingCopy.cancelButton,
            ifNoScreen: true
        )
    }

    func offerRetry(_ failure: SmsBindingFailure, context: SmsBindingFailureContext) async -> Bool {
        await ask(
            title: SmsBindingCopy.failureTitle,
            message: SmsBindingCopy.failure(code: failure.rawValue, context: context),
            confirm: failure.isRetryable ? SmsBindingCopy.retryButton : nil,
            dismiss: SmsBindingCopy.closeButton,
            ifNoScreen: false
        )
    }

    func showProgress(expiresAt: Date) {
        DispatchQueue.main.async { [self] in
            guard overlay == nil, let window = Self.keyWindow() else { return }
            let view = ProgressOverlay(frame: window.bounds, expiresAt: expiresAt)
            window.addSubview(view)
            overlay = view
        }
    }

    func updateProgress(_ state: SmsBindingState) {
        DispatchQueue.main.async { [self] in overlay?.reach(state) }
    }

    func hideProgress() async {
        await MainActor.run {
            overlay?.stop()
            overlay?.removeFromSuperview()
            overlay = nil
        }
    }

    // MARK: -

    /// One alert, answered once. `confirm == nil` shows a single dismiss button.
    ///
    /// UIKit silently refuses to present while another controller is animating in or out, and the
    /// message composer is usually still leaving the screen when a result arrives. So this waits
    /// for the transition to end, checks the alert actually appeared, and tries again if not. If it
    /// cannot be shown within a few seconds it answers with `ifNoScreen` rather than leave the flow
    /// waiting forever.
    private func ask(title: String, message: String, confirm: String?, dismiss: String, ifNoScreen: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = OneShot()
            let answer: @Sendable (Bool) -> Void = { value in
                if once.claim() { continuation.resume(returning: value) }
            }
            Task { @MainActor in
                let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: dismiss, style: .cancel) { _ in answer(false) })
                if let confirm {
                    alert.addAction(UIAlertAction(title: confirm, style: .default) { _ in answer(true) })
                }

                let deadline = Date().addingTimeInterval(Self.presentTimeout)
                while Date() < deadline {
                    if let top = presenter(), !Self.isTransitioning(top) {
                        top.present(alert, animated: true)
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if alert.presentingViewController != nil { return }   // it is on screen
                        continue                                              // it did not take; try again
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                answer(ifNoScreen)
            }
        }
    }

    /// How long to keep trying to put an alert on screen.
    static let presentTimeout: TimeInterval = 5

    @MainActor
    private static func isTransitioning(_ controller: UIViewController) -> Bool {
        controller.isBeingPresented || controller.isBeingDismissed || controller.transitionCoordinator != nil
    }

    @MainActor
    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
    }
}

/// The waiting screen: the three steps with a tick as each is reached, and the time left.
@MainActor
private final class ProgressOverlay: UIView {
    private let expiresAt: Date
    private let steps: [UILabel]
    private let titles = [SmsBindingCopy.stepSent, SmsBindingCopy.stepReceived, SmsBindingCopy.stepVerified]
    private let countdown = UILabel()
    private var timer: Timer?

    init(frame: CGRect, expiresAt: Date) {
        self.expiresAt = expiresAt
        steps = (0..<3).map { _ in UILabel() }
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = UIColor.black.withAlphaComponent(0.45)

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.startAnimating()
        let heading = UILabel()
        heading.text = SmsBindingCopy.progressTitle
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.textAlignment = .center
        for label in steps { label.font = .preferredFont(forTextStyle: .body) }
        countdown.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        countdown.textColor = .secondaryLabel
        countdown.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [spinner, heading] + steps + [countdown])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -32)
        ])

        // The message has already left the phone by the time this is shown.
        reach(.sent)
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reach(_ state: SmsBindingState) {
        let reached: Int
        switch state {
        case .issued: reached = 0
        case .sent: reached = 1
        case .received: reached = 2
        case .verified: reached = 3
        case .rejected, .expired, .aborted: reached = 1
        }
        for (index, label) in steps.enumerated() {
            let done = index < reached
            label.text = (done ? "✓  " : "○  ") + titles[index]
            label.textColor = done ? .label : .tertiaryLabel
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        countdown.text = SmsBindingCopy.timeLeft(seconds: Int(expiresAt.timeIntervalSinceNow.rounded(.up)))
    }
}
#endif
