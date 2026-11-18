#if DEBUG
import Foundation

/// Hardcoded backend answers for every outbound SMS binding outcome, so the whole flow (start with
/// rules, pre-checks, composer, report, status) can be exercised before the real backend exists.
///
/// Debug builds only: this file is not compiled into a Release build of the SDK. Going live means
/// not calling `Otpless.useMockSmsBinding`; the flow then talks to `LiveSmsBindingBackend`, whose
/// requests and responses have exactly the shapes this mock returns.
public enum OtplessSmsBindingMockScenario: String, CaseIterable, Sendable {
    // Success
    /// NPCI-style rules (R19 entitlement composer, R20 30 s, R21 ICCID token), then verified.
    case verifiedNpci
    /// Standard-style rules (editable composer, no R21), then verified. The one to use on a phone
    /// whose app does not hold the UPI Device Validation entitlement.
    case verifiedStandard
    /// Verdict arrives in steps: sent, then received after a pause, then verified.
    case slowVerdict
    /// Report calls fail; the verdict still verifies.
    case reportFails
    /// Two failed verdict polls, then verified.
    case pollFlaky

    // Device rules (stopped before the composer; the token exists, so the attempt is reported failed)
    case upgradeRequired
    case osTooOld

    // Backend refuses at the start
    case deviceBlockedAtStart
    case vmnPoolUnavailable
    case rulesUnavailable
    case startTransportError

    // Backend verdict is a failure
    case numberMismatch
    case rejectedUnknownReason
    case tokenExpiredVerdict
    case abortedVerdict
    case neverCompletes

    // Timing rules
    /// 8 s token: let it run out in the composer.
    case shortTtl
    /// R20 limit of 5 s: take longer than that in the composer.
    case strictComposerReturn
}

/// Answers every call from a fixed script chosen by the scenario.
internal final class MockSmsBindingBackend: SmsBindingBackend, @unchecked Sendable {

    struct VerdictStep {
        /// How long the "long-poll" is held open before this answer, simulating the backend waiting.
        let delay: TimeInterval
        let result: Result<SmsBindingVerdict, SmsBindingBackendError>
    }

    private struct Plan {
        var rules: Data?
        var startError: SmsBindingBackendError?
        var ttlSeconds = 45
        var reportError: SmsBindingBackendError?
        var verdicts: [VerdictStep] = []
    }

    let scenario: OtplessSmsBindingMockScenario
    /// The number the SMS is addressed to. The composer sends a **real** SMS to it, so use a
    /// number you own; the mock never receives anything.
    let vmn: String
    private let sleepFor: @Sendable (TimeInterval) async -> Void
    private let lock = NSLock()
    private var plan: Plan
    private var verdictCalls = 0
    private var _attemptSerial = 0

    init(
        scenario: OtplessSmsBindingMockScenario,
        vmn: String,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        }
    ) {
        self.scenario = scenario
        self.vmn = vmn
        self.sleepFor = sleep
        self.plan = Self.plan(for: scenario)
    }

    // MARK: SmsBindingBackend

    func startAttempt(state: String, request: SmsBindingStartRequest) async throws -> SmsBindingStarted {
        // As on the real backend, the rules arrive with the token; no rules is a failed start.
        guard let data = plan.rules, let rules = SmsBindingRules.decode(data) else { throw SmsBindingBackendError.transport }
        if let error = plan.startError { throw error }
        let serial: Int = lock.locked { _attemptSerial += 1; return _attemptSerial }
        return SmsBindingStarted(
            issued: SmsBindingIssued(
                attemptId: "att_mock_\(serial)",
                smsBody: "mock#Tk3:Zq_8Lm+4Rt=eP1.wZ*9sN-6bYh2uGcFdJ",
                vmn: vmn,
                ttlSeconds: plan.ttlSeconds
            ),
            rules: rules
        )
    }

    func report(state: String, attemptId: String, report: SmsBindingReport) async throws {
        if let error = plan.reportError { throw error }
    }

    func verdict(state: String, attemptId: String, sinceVersion: Int?, waitSeconds: Int) async throws -> SmsBindingVerdict {
        let step: VerdictStep = lock.locked {
            let index = verdictCalls
            verdictCalls += 1
            return plan.verdicts.isEmpty
                ? VerdictStep(delay: 0, result: .success(Self.verdict(.sent, version: 1)))
                : plan.verdicts[min(index, plan.verdicts.count - 1)]
        }
        if step.delay > 0 { await sleepFor(step.delay) }
        return try step.result.get()
    }

    // MARK: Scenario scripts

    private static func verdict(_ state: SmsBindingState, reason: String? = nil, binding: String? = nil, version: Int) -> SmsBindingVerdict {
        SmsBindingVerdict(state: state, reason: reason, bindingId: binding, stateVersion: version)
    }

    private static func ok(_ state: SmsBindingState, reason: String? = nil, binding: String? = nil, version: Int, delay: TimeInterval = 0) -> VerdictStep {
        VerdictStep(delay: delay, result: .success(verdict(state, reason: reason, binding: binding, version: version)))
    }

    private static func fail(_ error: SmsBindingBackendError) -> VerdictStep {
        VerdictStep(delay: 0, result: .failure(error))
    }

    /// Effective rules as the backend would serve them (PRD section 8).
    private static func rules(
        r19: Bool, r20: Int? = 30, r21: Bool = false, minApp: String? = nil, minOS: String? = nil
    ) -> Data {
        var members = [#""sim_present": {"enabled": true}"#, #""airplane_mode_block": {"enabled": true}"#]
        if r19 { members.append(#""ios_upi_entitlement": {"enabled": true}"#) }
        if let r20 { members.append(#""ios_composer_return": {"enabled": true, "max_seconds": \#(r20)}"#) }
        if r21 { members.append(#""ios_iccid_token": {"enabled": true}"#) }
        if let minApp { members.append(#""min_app_version": {"enabled": true, "version": "\#(minApp)"}"#) }
        if let minOS { members.append(#""min_os": {"enabled": true, "android_api": 23, "ios": "\#(minOS)"}"#) }
        return Data("""
        { "config_version": 1, "rules_hash": "r_mock", "sms_template": "{token}",
          "rules": { \(members.joined(separator: ",")) } }
        """.utf8)
    }

    private static func plan(for scenario: OtplessSmsBindingMockScenario) -> Plan {
        let standard = rules(r19: false)
        switch scenario {
        case .verifiedNpci:
            return Plan(rules: rules(r19: true, r21: true), verdicts: [ok(.verified, binding: "bnd_mock_npci", version: 2)])
        case .verifiedStandard:
            return Plan(rules: standard, verdicts: [ok(.verified, binding: "bnd_mock_standard", version: 2)])
        case .slowVerdict:
            return Plan(rules: standard, verdicts: [
                ok(.sent, version: 1),
                ok(.received, version: 2, delay: 3),
                ok(.verified, binding: "bnd_mock_slow", version: 3, delay: 3)
            ])
        case .reportFails:
            return Plan(rules: standard, reportError: .transport, verdicts: [ok(.verified, binding: "bnd_mock_report", version: 2)])
        case .pollFlaky:
            return Plan(rules: standard, verdicts: [fail(.transport), fail(.transport), ok(.verified, binding: "bnd_mock_flaky", version: 2)])

        case .upgradeRequired:
            return Plan(rules: rules(r19: false, minApp: "99.0.0"))
        case .osTooOld:
            return Plan(rules: rules(r19: false, minOS: "99.0"))

        case .deviceBlockedAtStart:
            return Plan(rules: standard, startError: .rejected(.deviceBlocked, retryAfterSeconds: 3600))
        case .vmnPoolUnavailable:
            return Plan(rules: standard, startError: .rejected(.vmnPoolUnavailable, retryAfterSeconds: nil))
        case .rulesUnavailable:
            return Plan(rules: nil)
        case .startTransportError:
            return Plan(rules: standard, startError: .transport)

        case .numberMismatch:
            return Plan(rules: standard, verdicts: [ok(.received, version: 2, delay: 2), ok(.rejected, reason: "NUMBER_MISMATCH", version: 3)])
        case .rejectedUnknownReason:
            return Plan(rules: standard, verdicts: [ok(.rejected, reason: "WRONG_VMN", version: 2)])
        case .tokenExpiredVerdict:
            return Plan(rules: standard, verdicts: [ok(.expired, version: 2)])
        case .abortedVerdict:
            return Plan(rules: standard, verdicts: [ok(.aborted, version: 2)])
        case .neverCompletes:
            return Plan(rules: standard, ttlSeconds: 20, verdicts: [ok(.sent, version: 1)])

        case .shortTtl:
            return Plan(rules: rules(r19: false, r20: nil), ttlSeconds: 8, verdicts: [ok(.verified, binding: "bnd_mock_short", version: 2)])
        case .strictComposerReturn:
            return Plan(rules: rules(r19: false, r20: 5), verdicts: [ok(.verified, binding: "bnd_mock_strict", version: 2)])
        }
    }
}

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
#endif
