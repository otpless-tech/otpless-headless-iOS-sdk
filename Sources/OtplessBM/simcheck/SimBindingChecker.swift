import Foundation

/// Turns Apple's plan status answers into the SDK's `bound` / `notBound` / `unknown` (ENG-628).
///
/// The mapping comes from what an iOS 27.0.1 device returned (ENG-626):
/// - Never-asked and denied both read as `notAuthorized`, so they cannot be told apart.
/// - A hint is returned even without authorization, and says `unavailable` with high confidence.
///   Reading it as `notBound` would be wrong, so the hint is only read once authorization is held.
/// - Numbers from unsupported regions come back `restricted` at once, with no dialog.
internal struct SimBindingChecker: Sendable {
    let provider: PlanStatusProvider

    /// Silent: never shows Apple's dialog.
    func check(phoneNumber: String) async -> Result<OtplessSimBindingCheck, OtplessSimCheckError> {
        guard provider.isSupported else { return .failure(.notSupported) }
        guard PhoneNumberFormat.isE164(phoneNumber) else { return .failure(.invalidPhoneNumber) }

        let authorization: PlanAuthorization
        do { authorization = try await provider.authorizationStatus(for: phoneNumber) } catch {
            return .success(.unknown(.apiError))
        }
        switch authorization {
        case .notAuthorized: return .success(.unknown(.notAuthorized))
        case .restricted: return .success(.unknown(.restricted))
        case .notSupported: return .success(.unknown(.apiError))
        case .authorized: break
        }

        let hint: PlanHint
        do { hint = try await provider.hint(for: phoneNumber) } catch { return .success(.unknown(.apiError)) }
        guard hint.highConfidence else { return .success(.unknown(.lowConfidence)) }
        return .success(OtplessSimBindingCheck(hint.available ? .bound : .notBound))
    }

    /// Asks Apple's permission only when it is not already held. Calling the request for a number
    /// that is already authorized shows the dialog again, and "Not Now" then revokes the permission
    /// (observed on device), so this reads the status first.
    func requestPermission(phoneNumber: String) async -> Result<OtplessNumberStatusPermission, OtplessSimCheckError> {
        guard provider.isSupported else { return .failure(.notSupported) }
        guard PhoneNumberFormat.isE164(phoneNumber) else { return .failure(.invalidPhoneNumber) }

        let current: PlanAuthorization
        do { current = try await provider.authorizationStatus(for: phoneNumber) } catch { return .success(.unavailable) }
        switch current {
        case .authorized: return .success(.granted)
        case .restricted, .notSupported: return .success(.unavailable)
        case .notAuthorized: break
        }

        do {
            switch try await provider.requestAuthorization(for: phoneNumber) {
            case .authorized: return .success(.granted)
            case .notAuthorized: return .success(.denied)
            case .restricted, .notSupported: return .success(.unavailable)
            }
        } catch {
            return .success(.unavailable)
        }
    }
}

// MARK: - Change listener

/// Remembers the last result per number, so a change is noticed across launches.
internal protocol SimBindingStateStore: Sendable {
    func last(for phoneNumber: String) -> String?
    func save(_ signature: String, for phoneNumber: String)
}

internal struct UserDefaultsSimBindingStateStore: SimBindingStateStore, @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func last(for phoneNumber: String) -> String? { defaults.string(forKey: key(phoneNumber)) }
    func save(_ signature: String, for phoneNumber: String) { defaults.set(signature, forKey: key(phoneNumber)) }

    /// The number is not stored in the clear.
    private func key(_ phoneNumber: String) -> String {
        "otpless.simbinding.last." + String(phoneNumber.hashValueStable)
    }
}

private extension String {
    /// FNV-1a: stable between launches, unlike `hashValue`.
    var hashValueStable: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
}

/// Re-checks the number and calls back **only when the result changes** from the last one seen.
///
/// The first result for a number is recorded without a callback: there is nothing to compare it
/// with. iOS cannot check while the app is suspended, so a change that happens meanwhile is
/// reported on the next launch or return to the foreground, by comparing with the saved result.
internal final class SimBindingMonitor: @unchecked Sendable {
    private let numberProvider: @Sendable () -> String?
    private let checker: SimBindingChecker
    private let store: SimBindingStateStore
    private let deliver: @Sendable (OtplessSimBindingCheck) -> Void
    private let lock = NSLock()
    private var evaluating = false

    /// `numberProvider` is asked at every re-check. With no number yet (nothing bound), the check waits.
    init(
        numberProvider: @escaping @Sendable () -> String?,
        checker: SimBindingChecker,
        store: SimBindingStateStore,
        deliver: @escaping @Sendable (OtplessSimBindingCheck) -> Void
    ) {
        self.numberProvider = numberProvider
        self.checker = checker
        self.store = store
        self.deliver = deliver
    }

    convenience init(
        phoneNumber: String,
        checker: SimBindingChecker,
        store: SimBindingStateStore,
        deliver: @escaping @Sendable (OtplessSimBindingCheck) -> Void
    ) {
        self.init(numberProvider: { phoneNumber }, checker: checker, store: store, deliver: deliver)
    }

    // Locking happens in these synchronous helpers: Swift 6 does not allow `NSLock` calls in async code.
    private func tryBegin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if evaluating { return false }
        evaluating = true
        return true
    }

    private func end() {
        lock.lock()
        evaluating = false
        lock.unlock()
    }

    /// One re-check. A check already running absorbs this one: its answer is just as fresh.
    func evaluate() async {
        guard tryBegin() else { return }
        defer { end() }

        guard let phoneNumber = numberProvider() else { return }
        guard case .success(let result) = await checker.check(phoneNumber: phoneNumber) else { return }
        // An API error says nothing about the SIM (Apple's helper process failed once in five
        // permission requests on device), so it is neither saved nor reported as a change.
        if result.reason == .apiError { return }
        let previous = store.last(for: phoneNumber)
        store.save(result.signature, for: phoneNumber)
        if let previous, previous != result.signature { deliver(result) }
    }
}
