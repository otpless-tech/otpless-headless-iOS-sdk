import Foundation
import UIKit

/// How much of the experience the SDK draws.
public enum OtplessSmsBindingUI: Sendable {
    /// No SDK screens besides Apple's message composer. The app uses the callbacks and, if it
    /// wants, `OtplessSmsBindingFailure.message` for wording.
    case headless
    /// The SDK also asks the user to pick the right SIM on a dual-SIM phone, shows a "verifying"
    /// indicator after the message is sent, and offers "Try again" on a failure that can be retried.
    case standard
}

extension OtplessSmsBindingFailure {
    /// A sentence fit to show the user for this failure.
    public var message: String { SmsBindingCopy.failure(code: code) }
}

/// User-facing wording. One place, so it can be checked against the PRD's copy (section 9) and
/// translated without touching the flow.
internal enum SmsBindingCopy {
    static let dualSimTitle = "Use the right SIM"
    static func dualSimMessage(lastDigits: String) -> String {
        "This phone has more than one active line. Send the message from the SIM that has the number ending in \(lastDigits)."
    }
    static let verifying = "Verifying your number…"
    static let continueButton = "Continue"
    static let cancelButton = "Cancel"
    static let retryButton = "Try again"
    static let closeButton = "Close"
    static let failureTitle = "Couldn't verify your number"

    static func failure(code: String) -> String {
        switch SmsBindingFailure(rawValue: code) {
        case .permissionMissing?: return "Allow the app to send messages, then try again."
        case .noSim?: return "No SIM card was found. Insert a SIM and turn off airplane mode, then try again."
        case .airplaneMode?: return "Turn off airplane mode and try again."
        case .upgradeRequired?: return "Please update the app to continue."
        case .entitlementMissing?: return "This app isn't set up for SIM verification. Please contact support."
        case .unsafeSmsApp?: return "Switch your default messaging app and try again."
        case .smsSendFailed?: return "The message wasn't sent. Please try again."
        case .numberMismatch?: return "The message was sent from a different number. Send it from the SIM that has the number you entered."
        case .tokenExpired?: return "This took too long. Please try again."
        case .sessionInterrupted?: return "Verification was interrupted. Please try again."
        case .deviceBlocked?: return "Too many attempts. Please try again later."
        case .vmnPoolUnavailable?: return "Verification isn't available right now. Please try another way."
        case .verificationFailed?: return "We couldn't verify your number."
        case .internalError?, nil: return "Something went wrong. Please try again."
        }
    }
}

// MARK: - Seam

/// The SDK's own screens. Headless mode uses the version that does nothing.
internal protocol SmsBindingPrompter: Sendable {
    /// Before a token is requested, so declining costs the user an attempt for nothing.
    func confirmDualSim(lastDigits: String) async -> Bool
    /// Synchronous, and queued on the main thread at once, so a `hideVerifying` called later can
    /// never run before it.
    func showVerifying()
    func hideVerifying() async
    /// Shows `failure`. Returns true if the user chose to try again.
    func offerRetry(_ failure: SmsBindingFailure) async -> Bool
}

internal struct HeadlessSmsBindingPrompter: SmsBindingPrompter {
    func confirmDualSim(lastDigits: String) async -> Bool { true }
    func showVerifying() {}
    func hideVerifying() async {}
    func offerRetry(_ failure: SmsBindingFailure) async -> Bool { false }
}

// MARK: - Standard UI

internal final class StandardSmsBindingPrompter: SmsBindingPrompter, @unchecked Sendable {

    private let presenter: @Sendable @MainActor () -> UIViewController?
    @MainActor private var overlay: UIView?

    init(presenter: @escaping @Sendable @MainActor () -> UIViewController? = LiveSmsBindingComposer.topViewController) {
        self.presenter = presenter
    }

    func confirmDualSim(lastDigits: String) async -> Bool {
        await ask(
            title: SmsBindingCopy.dualSimTitle,
            message: SmsBindingCopy.dualSimMessage(lastDigits: lastDigits),
            confirm: SmsBindingCopy.continueButton,
            dismiss: SmsBindingCopy.cancelButton,
            ifNoScreen: true
        )
    }

    func offerRetry(_ failure: SmsBindingFailure) async -> Bool {
        await ask(
            title: SmsBindingCopy.failureTitle,
            message: SmsBindingCopy.failure(code: failure.rawValue),
            confirm: failure.isRetryable ? SmsBindingCopy.retryButton : nil,
            dismiss: SmsBindingCopy.closeButton,
            ifNoScreen: false
        )
    }

    func showVerifying() {
        DispatchQueue.main.async { [self] in
            guard overlay == nil, let window = Self.keyWindow() else { return }
            let dim = UIView(frame: window.bounds)
            dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.45)

            let spinner = UIActivityIndicatorView(style: .large)
            spinner.color = .white
            spinner.startAnimating()
            let label = UILabel()
            label.text = SmsBindingCopy.verifying
            label.textColor = .white
            label.font = .preferredFont(forTextStyle: .headline)
            let stack = UIStackView(arrangedSubviews: [spinner, label])
            stack.axis = .vertical
            stack.spacing = 12
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            dim.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: dim.centerYAnchor)
            ])
            window.addSubview(dim)
            overlay = dim
        }
    }

    func hideVerifying() async {
        await MainActor.run {
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
