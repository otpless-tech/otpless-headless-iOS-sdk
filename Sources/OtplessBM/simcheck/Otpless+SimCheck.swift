#if canImport(CoreTelephony)
import CoreTelephony
#endif
import Foundation
import UIKit

// MARK: - Public API (ENG-628)

extension Otpless {

    /// Checks one E.164 number (for example `+919812345621`). Used by `checkSimBinding(completion:)` once
    /// it has the bound number; not part of the public API.
    internal func checkSimBinding(
        phoneNumber: String,
        completion: @escaping @Sendable (Result<OtplessSimBindingCheck, OtplessSimCheckError>) -> Void
    ) {
        let checker = SimBindingChecker(provider: SimCheckEnvironment.provider)
        Task {
            let result = await checker.check(phoneNumber: phoneNumber)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Asks whether the number this app last bound has an active plan on this device. This is the
    /// form the ticket describes: no number to pass, because the SDK keeps the bound number (set when
    /// an SMS binding or a verified OTP binds it). Never shows a dialog.
    ///
    /// Answers `NO_BOUND_NUMBER` if nothing has been bound yet, and `SIM_CHECK_NOT_SUPPORTED` before
    /// iOS 27.
    public func checkSimBinding(
        completion: @escaping @Sendable (Result<OtplessSimBindingCheck, OtplessSimCheckError>) -> Void
    ) {
        guard SimCheckEnvironment.provider.isSupported else {
            return DispatchQueue.main.async { completion(.failure(.notSupported)) }
        }
        guard let number = SimCheckEnvironment.boundNumbers.current else {
            return DispatchQueue.main.async { completion(.failure(.noBoundNumber)) }
        }
        checkSimBinding(phoneNumber: number, completion: completion)
    }

    /// Calls `listener` when the status of the bound number changes (`bound`, `notBound` or
    /// `unknown`; a different reason inside `unknown` is not a change). This is the form the ticket
    /// describes: no number to pass. It can be set before anything is bound: it then waits, and
    /// starts checking once a number is bound.
    ///
    /// The check runs on app launch, on return to the foreground, when the radio technology changes,
    /// and every `intervalSeconds` while the app is in the foreground. The first result is recorded
    /// without a call. iOS cannot check while the app is suspended, so a change in the meantime is
    /// reported at the next launch.
    ///
    /// Replaces any listener set earlier. Returns `SIM_CHECK_NOT_SUPPORTED` before iOS 27.
    @discardableResult
    public func setSimBindingListener(
        intervalSeconds: TimeInterval = 60,
        listener: @escaping @Sendable (OtplessSimBindingCheck) -> Void
    ) -> Result<Void, OtplessSimCheckError> {
        guard SimCheckEnvironment.provider.isSupported else { return .failure(.notSupported) }
        SimBindingListenerHost.shared.start(
            numberProvider: { SimCheckEnvironment.boundNumbers.current },
            interval: max(intervalSeconds, 5),
            checker: SimBindingChecker(provider: SimCheckEnvironment.provider),
            store: SimCheckEnvironment.store,
            listener: listener
        )
        return .success(())
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

    public func removeSimBindingListener() {
        SimBindingListenerHost.shared.stop()
    }
}

// MARK: - Wiring

/// What the SIM check talks to. Tests replace these.
internal enum SimCheckEnvironment {
    nonisolated(unsafe) static var provider: PlanStatusProvider = LivePlanStatusProvider()
    nonisolated(unsafe) static var store: SimBindingStateStore = UserDefaultsSimBindingStateStore()
    nonisolated(unsafe) static var boundNumbers: BoundNumberStore = KeychainBoundNumberStore()
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
        start(
            numberProvider: { phoneNumber }, interval: interval, checker: checker, store: store,
            listener: listener, center: center, isForeground: isForeground
        )
    }

    func start(
        numberProvider: @escaping @Sendable () -> String?,
        interval: TimeInterval,
        checker: SimBindingChecker,
        store: SimBindingStateStore,
        listener: @escaping @Sendable (OtplessSimBindingCheck) -> Void,
        center: NotificationCenter = .default,
        isForeground: @escaping @Sendable () async -> Bool = { await MainActor.run { UIApplication.shared.applicationState == .active } }
    ) {
        stop()
        let monitor = SimBindingMonitor(
            numberProvider: numberProvider, checker: checker, store: store,
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
