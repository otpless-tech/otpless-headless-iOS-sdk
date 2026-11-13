import Foundation

/// The stable rule keys from the Outbound SMS binding PRD (section 1). Only the ones the iOS
/// SDK acts on are listed; every other key in the payload is ignored.
internal enum SmsBindingRuleKey: String, Sendable {
    case tokenTTL = "token_ttl"
    case simPresent = "sim_present"
    case airplaneModeBlock = "airplane_mode_block"
    case singleSession = "single_session"
    case minAppVersion = "min_app_version"
    case minOS = "min_os"
    case iosUpiEntitlement = "ios_upi_entitlement"
    case iosComposerReturn = "ios_composer_return"
    case iosIccidToken = "ios_iccid_token"
}

/// The client's **effective** rules (template defaults with the client's overrides applied),
/// as served by the backend. Behaviour is driven only by these values: nothing here, or
/// anywhere that reads them, ever looks at the template name.
///
/// Decoding is deliberately forgiving. Unknown rule keys are ignored and a missing rule is
/// treated as **off**, so a backend that adds rules never breaks an older SDK.
internal struct SmsBindingRules: Equatable, Sendable {
    /// Per-rule `enabled` flag and values, keyed by the raw rule key.
    struct Rule: Equatable, Sendable {
        let enabled: Bool
        let intValues: [String: Int]
        let stringValues: [String: String]
    }

    let configVersion: Int
    let rulesHash: String
    let smsTemplate: String
    private let rules: [String: Rule]

    init(configVersion: Int, rulesHash: String, smsTemplate: String = "{token}", rules: [String: Rule] = [:]) {
        self.configVersion = configVersion
        self.rulesHash = rulesHash
        self.smsTemplate = smsTemplate
        self.rules = rules
    }

    /// Returns nil when the payload is not a rules document at all (no version or hash).
    static func decode(_ data: Data) -> SmsBindingRules? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = root["config_version"] as? Int,
              let hash = root["rules_hash"] as? String else { return nil }

        var parsed: [String: Rule] = [:]
        for (key, value) in (root["rules"] as? [String: Any]) ?? [:] {
            guard let body = value as? [String: Any] else { continue }
            var ints: [String: Int] = [:]
            var strings: [String: String] = [:]
            for (name, raw) in body where name != "enabled" {
                // NSNumber bridges Bool and Int; keep real booleans out of the int bucket.
                if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    ints[name] = number.intValue
                } else if let text = raw as? String {
                    strings[name] = text
                }
            }
            parsed[key] = Rule(enabled: (body["enabled"] as? Bool) ?? false, intValues: ints, stringValues: strings)
        }
        return SmsBindingRules(
            configVersion: version,
            rulesHash: hash,
            smsTemplate: (root["sms_template"] as? String) ?? "{token}",
            rules: parsed
        )
    }

    // MARK: - Accessors

    func isOn(_ key: SmsBindingRuleKey) -> Bool { rules[key.rawValue]?.enabled ?? false }

    func int(_ key: SmsBindingRuleKey, _ name: String) -> Int? {
        isOn(key) ? rules[key.rawValue]?.intValues[name] : nil
    }

    func string(_ key: SmsBindingRuleKey, _ name: String) -> String? {
        isOn(key) ? rules[key.rawValue]?.stringValues[name] : nil
    }

    // MARK: - Derived values the iOS flow uses

    /// R19. Entitlement composer: non-editable body, Apple's send completion.
    var requiresUpiEntitlement: Bool { isOn(.iosUpiEntitlement) }

    /// R21 depends on R19 (PRD section 8): without the entitlement rule the token is not requested,
    /// whatever the payload says.
    var requiresIccidToken: Bool { isOn(.iosIccidToken) && requiresUpiEntitlement }

    /// R20. Maximum seconds from composer presentation to the app regaining control, or nil when
    /// the rule is off. The PRD default is 30 s; the SDK never hard-codes one.
    var composerReturnLimit: TimeInterval? {
        guard isOn(.iosComposerReturn) else { return nil }
        return TimeInterval(int(.iosComposerReturn, "max_seconds") ?? 30)
    }

    /// R11. Minimum app version, or nil when the rule is off.
    var minimumAppVersion: String? { string(.minAppVersion, "version") }

    /// R12. Minimum iOS version, or nil when the rule is off.
    var minimumOSVersion: String? { string(.minOS, "ios") }
}

/// Dotted numeric version comparison ("3.10.0" > "3.9.2"). Non-numeric parts count as 0.
internal enum SmsBindingVersion {
    static func isAtLeast(_ version: String, minimum: String) -> Bool {
        let a = parts(version), b = parts(minimum)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
