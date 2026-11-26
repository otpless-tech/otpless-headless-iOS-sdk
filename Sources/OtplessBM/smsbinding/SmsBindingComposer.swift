import Foundation

// MARK: - Seams

/// What happened in the SMS composer. Times are what the R20 rule needs: when the composer went
/// up and when the app got control back.
internal struct SmsComposerOutcome: Equatable, Sendable {
    enum Result: String, Sendable { case sent, cancelled, failed }

    let result: Result
    /// Apple's UPI send completion: true once the SMS reached the carrier, false if it failed,
    /// nil when it never fired or the entitlement composer was not used.
    let sendCompletion: Bool?
    let presentedAt: Date
    let returnedAt: Date

    var returnSeconds: TimeInterval { returnedAt.timeIntervalSince(presentedAt) }
}

internal protocol SmsBindingComposer: Sendable {
    /// Shows the composer addressed to `recipient` with `body`. With `upiValidation` the body and
    /// recipient are not editable (needs the UPI Device Validation entitlement in the host app).
    func present(recipient: String, body: String, upiValidation: Bool) async -> SmsComposerOutcome
}

/// Result of Apple's ICCID-mapped token request (iOS 26+).
internal enum IccidTokenResult: Equatable, Sendable {
    case token(String)
    /// Apple returned nothing. Recorded, never treated as a failure (R21).
    case nilToken
    /// iOS below 26.
    case unsupported
}

internal protocol IccidTokenProvider: Sendable {
    func fetch() async -> IccidTokenResult
}

#if os(iOS)
import CoreTelephony
import MessageUI
import UIKit

// MARK: - Live: device facts

internal struct LiveSmsBindingDevice: SmsBindingDevice {
    var osVersion: String { UIDevice.current.systemVersion }

    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    var hasCellularRadio: Bool {
        guard #available(iOS 12.0, *) else { return false }
        return !(CTTelephonyNetworkInfo().serviceCurrentRadioAccessTechnology ?? [:]).isEmpty
    }

    var canSendText: Bool { MFMessageComposeViewController.canSendText() }

    var supportsIccidToken: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    var activeLineCount: Int {
        guard #available(iOS 12.0, *) else { return 1 }
        return (CTTelephonyNetworkInfo().serviceCurrentRadioAccessTechnology ?? [:]).count
    }
}

// MARK: - Live: ICCID token

internal struct LiveIccidTokenProvider: IccidTokenProvider {
    func fetch() async -> IccidTokenResult {
        guard #available(iOS 26.0, *) else { return .unsupported }
        return await withCheckedContinuation { continuation in
            CTCellularPlanStatus.getTokenWithCompletion { token, _ in
                if let token, !token.isEmpty {
                    continuation.resume(returning: .token(token))
                } else {
                    continuation.resume(returning: .nilToken)
                }
            }
        }
    }
}

// MARK: - Live: composer

/// Presents `MFMessageComposeViewController` from the host app's topmost view controller.
internal final class LiveSmsBindingComposer: SmsBindingComposer, @unchecked Sendable {
    /// How long to wait, after the user taps Send, for Apple's carrier-transmission result.
    static let sendCompletionTimeout: TimeInterval = 10

    private let presenter: @Sendable @MainActor () -> UIViewController?

    init(presenter: @escaping @Sendable @MainActor () -> UIViewController? = LiveSmsBindingComposer.topViewController) {
        self.presenter = presenter
    }

    func present(recipient: String, body: String, upiValidation: Bool) async -> SmsComposerOutcome {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let session = ComposerSession(continuation: continuation, upiValidation: upiValidation)
                session.start(recipient: recipient, body: body, presenter: presenter())
            }
        }
    }

    @MainActor
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// One composer presentation. Retains itself until it has delivered exactly one outcome,
/// because `MFMessageComposeViewController` holds its delegate weakly.
@MainActor
private final class ComposerSession: NSObject, MFMessageComposeViewControllerDelegate {
    private var continuation: CheckedContinuation<SmsComposerOutcome, Never>?
    private let upiValidation: Bool
    private var selfRetain: ComposerSession?
    private var presentedAt = Date()
    private var returnedAt: Date?
    private var composerResult: SmsComposerOutcome.Result = .failed
    private var sendCompletion: Bool?
    private var awaitingCompletion = false
    private var dismissalHandled = false

    init(continuation: CheckedContinuation<SmsComposerOutcome, Never>, upiValidation: Bool) {
        self.continuation = continuation
        self.upiValidation = upiValidation
        super.init()
        selfRetain = self
    }

    func start(recipient: String, body: String, presenter: UIViewController?) {
        guard MFMessageComposeViewController.canSendText(), let presenter else {
            presentedAt = Date()
            returnedAt = presentedAt
            finish()
            return
        }
        let controller = MFMessageComposeViewController()
        controller.recipients = [recipient]
        controller.body = body
        controller.messageComposeDelegate = self

        if upiValidation {
            // `MainActor.assumeIsolated` is iOS 17+ and this package supports iOS 13, so hop
            // explicitly. Apple delivers the completion on the main thread, so ordering holds.
            let configured = Self.configureUPI(controller) { [weak self] didSend in
                Task { @MainActor in self?.completionArrived(didSend) }
            }
            // R19 is on but Apple's entitlement composer is unavailable (iOS below 17): never fall
            // back to the editable composer.
            guard configured else {
                presentedAt = Date()
                returnedAt = presentedAt
                finish()
                return
            }
        }
        presentedAt = Date()
        presenter.present(controller, animated: true)
    }

    nonisolated func messageComposeViewController(
        _ controller: MFMessageComposeViewController,
        didFinishWith result: MessageComposeResult
    ) {
        // Stamp the moment the app regains control here, before any actor hop, so R20 measures
        // the user's time and not our scheduling.
        let returned = Date()
        Task { @MainActor in
            returnedAt = returned
            switch result {
            case .sent: composerResult = .sent
            case .cancelled: composerResult = .cancelled
            default: composerResult = .failed
            }
            // Carry on only once the composer has left the screen: anything the SDK shows next (an
            // alert) cannot be presented while it is still animating away.
            controller.dismiss(animated: true) { [weak self] in
                Task { @MainActor in self?.composerDismissed() }
            }
            // `dismiss` skips its completion if the controller is already gone.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.composerDismissed()
            }
        }
    }

    private func composerDismissed() {
        guard !dismissalHandled else { return }
        dismissalHandled = true

        guard composerResult == .sent, upiValidation else { return finish() }
        // Apple calls the send completion after this, once the carrier has the message.
        // If it already ran, finish now; otherwise wait a bounded time for it.
        if sendCompletion != nil { return finish() }
        awaitingCompletion = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LiveSmsBindingComposer.sendCompletionTimeout * 1_000_000_000))
            self?.finish()
        }
    }

    /// `setUPIVerificationCodeSendCompletion:` (iOS 17+) lives in `MFMessageComposeViewController+UPI.h`,
    /// which `MessageUI.h` does not import, so Swift cannot see it. It is public API; call it by
    /// selector, with an Objective-C block, and report whether the device has it.
    private static func configureUPI(
        _ controller: MFMessageComposeViewController,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        let selector = NSSelectorFromString("setUPIVerificationCodeSendCompletion:")
        guard controller.responds(to: selector) else { return false }
        let block: @convention(block) (Bool) -> Void = completion
        _ = controller.perform(selector, with: unsafeBitCast(block, to: AnyObject.self))
        return true
    }

    private func completionArrived(_ didSend: Bool) {
        sendCompletion = didSend
        if awaitingCompletion { finish() }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: SmsComposerOutcome(
            result: composerResult,
            sendCompletion: sendCompletion,
            presentedAt: presentedAt,
            returnedAt: returnedAt ?? Date()
        ))
        selfRetain = nil
    }
}
#endif
