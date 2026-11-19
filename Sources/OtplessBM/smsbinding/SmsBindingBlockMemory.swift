import Foundation

/// Remembers how long a device stays blocked (R10's `block_h`), as last seen in the rules. When the
/// backend later refuses an attempt with "device blocked" it does not say for how long, so this is
/// what lets the message say "try again in about 6 hours". A hint only: the SDK never refuses an
/// attempt itself on the strength of it.
internal final class SmsBindingBlockMemory: @unchecked Sendable {
    static let shared = SmsBindingBlockMemory(defaults: .standard)

    private let defaults: UserDefaults
    private let key = "otpless.smsbinding.block_hours"

    init(defaults: UserDefaults) { self.defaults = defaults }

    var hours: Int? {
        let value = defaults.integer(forKey: key)
        return value > 0 ? value : nil
    }

    func remember(_ hours: Int?) {
        guard let hours, hours > 0 else { return }
        defaults.set(hours, forKey: key)
    }
}
