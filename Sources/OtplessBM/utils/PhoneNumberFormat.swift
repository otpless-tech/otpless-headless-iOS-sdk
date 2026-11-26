import Foundation

internal enum PhoneNumberFormat {
    /// E.164: `+`, a non-zero first digit, 7 to 15 digits in all.
    static func isE164(_ value: String) -> Bool {
        guard value.hasPrefix("+") else { return false }
        let digits = value.dropFirst()
        return (7...15).contains(digits.count) && digits.first != "0" && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
