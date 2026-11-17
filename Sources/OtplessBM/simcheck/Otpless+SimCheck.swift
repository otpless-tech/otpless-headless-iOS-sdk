import CoreTelephony
import Foundation
import UIKit

// MARK: - Public API (ENG-628)

extension Otpless {

    /// Whether this device has Apple's plan status API (iOS 27 and later). When this is false every
    /// SIM check below answers `SIM_CHECK_NOT_SUPPORTED`; the SDK does not guess.
    public var isSimCheckSupported: Bool { SimCheckEnvironment.provider.isSupported }

    /// Asks whether `phoneNumber` has an active plan on this device. Never shows a dialog and never
    /// blocks the flow: the app decides what `bound`, `notBound` and `unknown` mean.
    ///
    /// - Parameter phoneNumber: E.164, for example `+919812345621`.
    /// - Parameter completion: Called once, on the main thread.
    public func checkSimBinding(
        phoneNumber: String,
        completion: @escaping @Sendable (Result<OtplessSimBindingCheck, OtplessSimCheckError>) -> Void
    ) {
        let checker = SimBindingChecker(provider: SimCheckEnvironment.provider)
        Task {
            let result = await checker.check(phoneNumber: phoneNumber)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Asks Apple for permission to check `phoneNumber`, for apps that show their own explanation
    /// first. Apple's dialog appears only when the permission is not already held.
    public func requestNumberStatusPermission(
        phoneNumber: String,
        completion: @escaping @Sendable (Result<OtplessNumberStatusPermission, OtplessSimCheckError>) -> Void
    ) {
        let checker = SimBindingChecker(provider: SimCheckEnvironment.provider)
        Task {
            let result = await checker.requestPermission(phoneNumber: phoneNumber)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Calls `listener` when the result of the check for `phoneNumber` changes.
    ///
    /// The check runs on app launch, on return to the foreground, when the radio technology
    /// changes, and every `intervalSeconds` while the app is in the foreground. iOS cannot check
    /// while the app is suspended, so a change that happens meanwhile is reported at the next launch.
    ///
    /// Replaces any listener set earlier. Returns `SIM_CHECK_NOT_SUPPORTED` before iOS 27.
    @discardableResult
    public func setSimBindingListener(
        phoneNumber: String,
        intervalSeconds: TimeInterval = 60,
        listener: @escaping @Sendable (OtplessSimBindingCheck) -> Void
    ) -> Result<Void, OtplessSimCheckError> {
        guard SimCheckEnvironment.provider.isSupported else { return .failure(.notSupported) }
        guard PhoneNumberFormat.isE164(phoneNumber) else { return .failure(.invalidPhoneNumber) }
        SimBindingListenerHost.shared.start(
            phoneNumber: phoneNumber,
            interval: max(intervalSeconds, 5),
            checker: SimBindingChecker(provider: SimCheckEnvironment.provider),
            store: SimCheckEnvironment.store,
            listener: listener
        )
        return .success(())
    }

    public func removeSimBindingListener() {
        SimBindingListenerHost.shared.stop()
    }
}

// MARK: - Wiring

/// What the SIM check talks to. Tests replace these.
internal enum SimCheckEnvironment {
    nonisolated(unsafe) static var provider: PlanStatusProvider = LivePlanStatusProvider()
    nonisolated(unsafe) static var store: SimBindingStateStore = UserDefaultsSimBindingStateStore()
}

/// Owns the one listener and the events that make it re-check.
internal final class SimBindingListenerHost: @unchecked Sendable {
    static let shared = SimBindingListenerHost()

    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []
    private var timer: Task<Void, Never>?
    private var monitor: SimBindingMonitor?

    func start(
        phoneNumber: String,
        interval: TimeInterval,
        checker: SimBindingChecker,
        store: SimBindingStateStore,
        listener: @escaping @Sendable (OtplessSimBindingCheck) -> Void,
        center: NotificationCenter = .default,
        isForeground: @escaping @Sendable () async -> Bool = { await MainActor.run { UIApplication.shared.applicationState == .active } }
    ) {
        stop()
        let monitor = SimBindingMonitor(
            phoneNumber: phoneNumber, checker: checker, store: store,
            deliver: { check in DispatchQueue.main.async { listener(check) } }
        )

        let names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            Notification.Name("CTServiceRadioAccessTechnologyDidChangeNotification")
        ]
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in Task { await monitor.evaluate() } }
        }
        let loop = Task {
            await monitor.evaluate()      // app launch
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                if await isForeground() { await monitor.evaluate() }
            }
        }

        lock.lock()
        self.monitor = monitor
        observers = tokens
        timer = loop
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let tokens = observers
        let loop = timer
        observers = []
        timer = nil
        monitor = nil
        lock.unlock()
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        loop?.cancel()
    }
}
