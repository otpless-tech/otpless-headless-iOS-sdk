import Foundation

/// The number the SDK last bound (E.164), so `checkSimBinding()` and `setSimBindingListener(_:)` can
/// work without being handed a number, as the ENG-628 ticket and Android's `checkSimBindingStatus`
/// do. Kept in the Keychain, since it is a phone number, and cleared with the SDK's other secure data.
internal protocol BoundNumberStore: Sendable {
    var current: String? { get }
    func save(_ e164: String)
}

internal struct KeychainBoundNumberStore: BoundNumberStore {
    private static let key = "otpless.simbinding.bound_number"

    var current: String? {
        let value = SecureStorage.shared.retrieve(key: Self.key)
        return (value?.isEmpty ?? true) ? nil : value
    }

    func save(_ e164: String) {
        SecureStorage.shared.save(key: Self.key, value: e164)
    }
}

/// For tests and for a use case that has not been given the real one.
internal final class InMemoryBoundNumberStore: BoundNumberStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var current: String? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ e164: String) { lock.lock(); value = e164; lock.unlock() }
}
