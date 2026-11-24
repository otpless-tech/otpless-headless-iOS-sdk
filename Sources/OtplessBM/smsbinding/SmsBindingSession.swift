import Foundation

// MARK: - Previous attempt (R4: the backend skips the VMN the device used last time)

/// Remembers the last attempt for a number, so a retry can name it in `previous_attempt_id` and
/// the backend can pick a different VMN. Held in memory only: it matters for a retry, and a retry
/// happens in the same session. A different number never gets the old attempt's id.
internal final class SmsBindingLastAttempt: @unchecked Sendable {
    static let shared = SmsBindingLastAttempt()

    private let lock = NSLock()
    private var msisdn: String?
    private var attemptId: String?

    func previous(for msisdn: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return self.msisdn == msisdn ? attemptId : nil
    }

    func record(_ attemptId: String, for msisdn: String) {
        lock.lock()
        self.msisdn = msisdn
        self.attemptId = attemptId
        lock.unlock()
    }

    /// A verified binding has no retry to chain.
    func clear() {
        lock.lock()
        msisdn = nil
        attemptId = nil
        lock.unlock()
    }
}

// MARK: - Single session (R9)

/// R9: while an attempt is running the app must stay in front. If it goes to the background the
/// attempt is abandoned, so the token cannot be used from somewhere else.
internal protocol SmsBindingSessionGuard: AnyObject, Sendable {
    /// The app left the foreground after `begin`.
    var interrupted: Bool { get }
    /// Starts watching. `onInterrupt` runs once, with a `done` to call when its work is finished.
    func begin(onInterrupt: @escaping @Sendable (_ done: @escaping @Sendable () -> Void) -> Void)
    func end()
}

/// Used when R9 is off.
internal final class InactiveSessionGuard: SmsBindingSessionGuard, @unchecked Sendable {
    var interrupted: Bool { false }
    func begin(onInterrupt: @escaping @Sendable (_ done: @escaping @Sendable () -> Void) -> Void) {}
    func end() {}
}

#if os(iOS)
import UIKit

internal final class LiveSmsBindingSessionGuard: SmsBindingSessionGuard, @unchecked Sendable {
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var _interrupted = false

    var interrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _interrupted
    }

    func begin(onInterrupt: @escaping @Sendable (_ done: @escaping @Sendable () -> Void) -> Void) {
        let token = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let first = !self._interrupted
            self._interrupted = true
            self.lock.unlock()
            guard first else { return }

            // iOS suspends the app moments after it backgrounds; ask for the time to tell the backend.
            let background = BackgroundTask()
            background.id = UIApplication.shared.beginBackgroundTask(withName: "otpless.sms-binding.abort") {
                background.end()
            }
            onInterrupt { DispatchQueue.main.async { background.end() } }
        }
        lock.lock()
        observer = token
        lock.unlock()
    }

    func end() {
        lock.lock()
        let token = observer
        observer = nil
        lock.unlock()
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

private final class BackgroundTask: @unchecked Sendable {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
