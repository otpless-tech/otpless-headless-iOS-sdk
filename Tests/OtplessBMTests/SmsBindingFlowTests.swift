//
//  SmsBindingFlowTests.swift
//  OtplessBMTests
//
//  The outbound SMS binding orchestration (ENG-622): rules in, composer, R19/R20/R21, report,
//  verdict. Hermetic: the backend, composer, ICCID token and clock are fakes.
//

import XCTest
@testable import OtplessBM

// MARK: - Fakes

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.locked { date } }
    func advance(_ seconds: TimeInterval) { lock.locked { date = date.addingTimeInterval(seconds) } }
}

private struct FakeDevice: SmsBindingDevice {
    var osVersion = "27.0"
    var appVersion = "3.2.0"
    var hasCellularRadio = true
    var canSendText = true
    var activeLineCount = 1
}

private final class FakePrompter: SmsBindingPrompter, @unchecked Sendable {
    private let lock = NSLock()
    var confirmDualSimAnswer = true
    private var _dualSimAsks: [String] = []
    var dualSimAsks: [String] { lock.locked { _dualSimAsks } }

    func confirmDualSim(lastDigits: String) async -> Bool {
        lock.locked { _dualSimAsks.append(lastDigits) }
        return confirmDualSimAnswer
    }
    func showVerifying() {}
    func hideVerifying() async {}
    func offerRetry(_ failure: SmsBindingFailure) async -> Bool { false }
}

private final class FakeBackend: SmsBindingBackend, @unchecked Sendable {
    private let lock = NSLock()
    var rulesJSON: Data
    var startError: SmsBindingBackendError?
    var reportError: SmsBindingBackendError?
    var ttlSeconds = 45
    var verdicts: [Result<SmsBindingVerdict, SmsBindingBackendError>] = []

    private var _startRequests: [SmsBindingStartRequest] = []
    private var _reports: [SmsBindingReport] = []
    private var _verdictCalls = 0
    private var _rulesCalls = 0

    init(rules: Data) { rulesJSON = rules }

    var startRequests: [SmsBindingStartRequest] { lock.locked { _startRequests } }
    var reports: [SmsBindingReport] { lock.locked { _reports } }
    var verdictCalls: Int { lock.locked { _verdictCalls } }

    func fetchRules(state: String) async throws -> SmsBindingRules {
        guard let rules = SmsBindingRules.decode(rulesJSON) else { throw SmsBindingBackendError.transport }
        return rules
    }

    func startAttempt(state: String, request: SmsBindingStartRequest) async throws -> SmsBindingIssued {
        lock.locked { _startRequests.append(request) }
        if let startError { throw startError }
        return SmsBindingIssued(
            attemptId: "att_1", smsBody: "k#7Qv:2Lm", vmn: "+919000000007",
            ttlSeconds: ttlSeconds, configVersion: request.rules.configVersion, rulesHash: request.rules.rulesHash
        )
    }

    func report(state: String, attemptId: String, report: SmsBindingReport) async throws {
        lock.locked { _reports.append(report) }
        if let reportError { throw reportError }
    }

    func verdict(state: String, attemptId: String, sinceVersion: Int?, waitSeconds: Int) async throws -> SmsBindingVerdict {
        let next: Result<SmsBindingVerdict, SmsBindingBackendError> = lock.locked {
            let index = _verdictCalls
            _verdictCalls += 1
            if verdicts.isEmpty { return .success(SmsBindingVerdict(state: .sent, reason: nil, bindingId: nil, stateVersion: 1)) }
            return verdicts[min(index, verdicts.count - 1)]
        }
        return try next.get()
    }
}

private final class FakeComposer: SmsBindingComposer, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: TestClock
    var result: SmsComposerOutcome.Result = .sent
    var sendCompletion: Bool? = true
    var returnSeconds: TimeInterval = 4
    private var _calls: [(recipient: String, body: String, upi: Bool)] = []

    init(clock: TestClock) { self.clock = clock }
    var calls: [(recipient: String, body: String, upi: Bool)] { lock.locked { _calls } }

    func present(recipient: String, body: String, upiValidation: Bool) async -> SmsComposerOutcome {
        lock.locked { _calls.append((recipient, body, upiValidation)) }
        let presented = clock.now
        clock.advance(returnSeconds)
        return SmsComposerOutcome(
            result: result, sendCompletion: sendCompletion, presentedAt: presented, returnedAt: clock.now
        )
    }
}

private final class FakeIccid: IccidTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    var result: IccidTokenResult = .token("iccid-token")
    private var _fetches = 0
    var fetches: Int { lock.locked { _fetches } }
    func fetch() async -> IccidTokenResult {
        lock.locked { _fetches += 1 }
        return result
    }
}

// MARK: - Rules fixtures

private func rules(r19: Bool = true, r20: Int? = 30, r21: Bool = true, extra: String = "") -> Data {
    var members = [#""sim_present": {"enabled": true}"#, #""airplane_mode_block": {"enabled": true}"#]
    if r19 { members.append(#""ios_upi_entitlement": {"enabled": true}"#) }
    if let r20 { members.append(#""ios_composer_return": {"enabled": true, "max_seconds": \#(r20)}"#) }
    if r21 { members.append(#""ios_iccid_token": {"enabled": true}"#) }
    if !extra.isEmpty { members.append(extra) }
    return Data("""
    { "config_version": 12, "rules_hash": "r_9c41e0", "sms_template": "{token}",
      "rules": { \(members.joined(separator: ",")) } }
    """.utf8)
}

private func verdict(_ state: SmsBindingState, reason: String? = nil, binding: String? = nil, version: Int)
    -> Result<SmsBindingVerdict, SmsBindingBackendError> {
    .success(SmsBindingVerdict(state: state, reason: reason, bindingId: binding, stateVersion: version))
}

// MARK: - Tests

final class SmsBindingFlowTests: XCTestCase {

    private struct Harness {
        let clock = TestClock()
        let backend: FakeBackend
        let composer: FakeComposer
        let iccid = FakeIccid()
        let useCase: SmsBindingUseCase
        let sleeps: SleepLog

        let prompter = FakePrompter()

        init(rules: Data = rules(), device: FakeDevice = FakeDevice(), planStatusSupported: Bool = false) {
            let clock = self.clock
            backend = FakeBackend(rules: rules)
            composer = FakeComposer(clock: clock)
            let log = SleepLog()
            sleeps = log
            useCase = SmsBindingUseCase(
                backend: backend, composer: composer, iccid: iccid, device: device,
                prompter: prompter, planStatusSupported: { planStatusSupported },
                sdkVersion: "3.2.0", deviceFingerprintHash: { "fp-hash" },
                now: { clock.now },
                sleep: { seconds in log.record(seconds); clock.advance(seconds) }
            )
        }

        func run(entitlement: Bool = true, previous: String? = nil) async -> SmsBindingOutcome {
            await useCase.run(state: "state-1", msisdn: "+919812345621", upiEntitlementDeclared: entitlement, previousAttemptId: previous)
        }
    }

    final class SleepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [TimeInterval] = []
        func record(_ value: TimeInterval) { lock.locked { _values.append(value) } }
        var values: [TimeInterval] { lock.locked { _values } }
    }

    // MARK: Dual SIM and device context (ENG-622, ENG-628)

    func testDualSimAsksBeforeAnyTokenIsRequested() async {
        let h = Harness(device: FakeDevice(activeLineCount: 2))
        h.prompter.confirmDualSimAnswer = false

        let outcome = await h.run()

        XCTAssertEqual(outcome, .failed(.smsSendFailed))
        XCTAssertEqual(h.prompter.dualSimAsks, ["5621"], "names the last four digits of the number being bound")
        XCTAssertTrue(h.backend.startRequests.isEmpty, "declining must not consume an attempt")
        XCTAssertTrue(h.composer.calls.isEmpty)
    }

    func testDualSimConfirmedContinuesToTheComposer() async {
        let h = Harness(device: FakeDevice(activeLineCount: 2))
        h.backend.verdicts = [verdict(.verified, binding: "bnd_1", version: 2)]

        let outcome = await h.run()

        XCTAssertEqual(outcome, .verified(bindingId: "bnd_1"))
        XCTAssertEqual(h.prompter.dualSimAsks.count, 1)
        XCTAssertEqual(h.composer.calls.count, 1)
    }

    func testSingleLineNeverAsks() async {
        let h = Harness(device: FakeDevice(activeLineCount: 1))
        h.backend.verdicts = [verdict(.verified, version: 2)]
        _ = await h.run()
        XCTAssertTrue(h.prompter.dualSimAsks.isEmpty)
    }

    func testStartRequestCarriesPlanStatusSupported() async {
        for supported in [true, false] {
            let h = Harness(planStatusSupported: supported)
            h.backend.verdicts = [verdict(.verified, version: 2)]
            _ = await h.run()
            let request = try! XCTUnwrap(h.backend.startRequests.first)
            XCTAssertEqual(request.planStatusSupported, supported)
            XCTAssertEqual((request.toDict()["capabilities"] as? [String: Any])?["plan_status_supported"] as? Bool, supported)
        }
    }

    // MARK: Happy path

    func testNpciHappyPathVerifiesAndSendsEverythingTheContractNames() async {
        let h = Harness()
        h.backend.verdicts = [verdict(.received, version: 2), verdict(.verified, binding: "bnd_31Ke", version: 3)]

        let outcome = await h.run()

        XCTAssertEqual(outcome, .verified(bindingId: "bnd_31Ke"))
        XCTAssertEqual(h.composer.calls.count, 1)
        XCTAssertEqual(h.composer.calls.first?.recipient, "+919000000007")
        XCTAssertEqual(h.composer.calls.first?.body, "k#7Qv:2Lm")
        XCTAssertEqual(h.composer.calls.first?.upi, true, "R19 on must use the entitlement composer")

        let request = try! XCTUnwrap(h.backend.startRequests.first)
        XCTAssertEqual(request.msisdn, "+919812345621")
        XCTAssertEqual(request.rules.configVersion, 12)
        XCTAssertTrue(request.upiEntitlementDeclared)
        let dict = request.toDict()
        XCTAssertEqual(dict["device_platform"] as? String, "ios")
        XCTAssertEqual(dict["rules_hash"] as? String, "r_9c41e0")
        XCTAssertEqual((dict["capabilities"] as? [String: Any])?["upi_entitlement"] as? Bool, true)

        let sentReport = try! XCTUnwrap(h.backend.reports.first)
        XCTAssertEqual(sentReport.event, .sent)
        XCTAssertEqual(sentReport.ios?.sendCompletion, true)
        XCTAssertEqual(sentReport.ios?.iccidToken, "iccid-token")
        XCTAssertEqual(sentReport.ios?.iccidTokenStatus, "OK")
        XCTAssertEqual(sentReport.ios?.returnSeconds ?? 0, 4, accuracy: 0.001)
    }

    func testPreviousAttemptIdIsForwardedSoTheBackendCanPickADifferentVmn() async {
        let h = Harness()
        h.backend.verdicts = [verdict(.verified, version: 2)]
        _ = await h.run(previous: "att_0")
        XCTAssertEqual(h.backend.startRequests.first?.previousAttemptId, "att_0")
        XCTAssertEqual(h.backend.startRequests.first?.toDict()["previous_attempt_id"] as? String, "att_0")
    }

    // MARK: Pre-checks and start

    func testFailedPrecheckNeverRequestsATokenOrShowsTheComposer() async {
        let h = Harness(device: FakeDevice(hasCellularRadio: false))
        let outcome = await h.run()
        XCTAssertEqual(outcome, .failed(.noSim))
        XCTAssertTrue(h.backend.startRequests.isEmpty)
        XCTAssertTrue(h.composer.calls.isEmpty)
        XCTAssertTrue(h.backend.reports.isEmpty)
    }

    func testMissingEntitlementDeclarationStopsBeforeAnyTokenIsIssued() async {
        let h = Harness()
        let outcome = await h.run(entitlement: false)
        XCTAssertEqual(outcome, .failed(.entitlementMissing))
        XCTAssertTrue(h.backend.startRequests.isEmpty)
    }

    func testBackendRefusalToStartIsSurfacedAndNothingIsShown() async {
        let h = Harness()
        h.backend.startError = .rejected(.deviceBlocked, retryAfterSeconds: 3600)
        let outcome = await h.run()
        XCTAssertEqual(outcome, .failed(.deviceBlocked))
        XCTAssertTrue(h.composer.calls.isEmpty)
    }

    func testRulesThatCannotBeFetchedFailAsAnInternalError() async {
        let h = Harness(rules: Data("garbage".utf8))
        let outcome = await h.run()
        XCTAssertEqual(outcome, .failed(.internalError))
    }

    func testStandardClientWithR19OffGetsTheEditableComposer() async {
        let h = Harness(rules: rules(r19: false, r20: 30, r21: false))
        h.composer.sendCompletion = nil   // Apple's completion never fires without the entitlement
        h.backend.verdicts = [verdict(.verified, version: 2)]

        let outcome = await h.run(entitlement: false)

        XCTAssertEqual(outcome, .verified(bindingId: nil))
        XCTAssertEqual(h.composer.calls.first?.upi, false)
    }

    // MARK: Composer results

    func testCancelledComposerEndsTheAttemptAndIsReported() async {
        let h = Harness()
        h.composer.result = .cancelled
        let outcome = await h.run()
        XCTAssertEqual(outcome, .failed(.smsSendFailed))
        XCTAssertEqual(h.backend.reports.map(\.event), [.cancelled])
        XCTAssertEqual(h.backend.verdictCalls, 0)
    }

    func testFailedComposerEndsTheAttemptAndIsReported() async {
        let h = Harness()
        h.composer.result = .failed
        let outcome = await h.run()
        XCTAssertEqual(outcome, .failed(.smsSendFailed))
        XCTAssertEqual(h.backend.reports.map(\.event), [.failed])
    }

    // MARK: R19

    func testR19RequiresAppleSendCompletionNotJustTheComposerSentResult() async {
        for completion in [nil, false] as [Bool?] {
            let h = Harness()
            h.composer.sendCompletion = completion
            let outcome = await h.run()
            XCTAssertEqual(outcome, .failed(.smsSendFailed), "completion=\(String(describing: completion))")
            XCTAssertEqual(h.backend.reports.map(\.event), [.failed])
            XCTAssertEqual(h.backend.verdictCalls, 0)
        }
    }

    // MARK: R20

    func testR20DeclinesWhenTheAppWasAwayLongerThanTheLimit() async {
        let h = Harness(rules: rules(r20: 30))
        h.composer.returnSeconds = 31
        let outcome = await h.run()
        XCTAssertEqual(outcome, .failed(.tokenExpired))
        let report = try! XCTUnwrap(h.backend.reports.first)
        XCTAssertEqual(report.event, .failed)
        XCTAssertEqual(report.reason, .tokenExpired)
        XCTAssertEqual(report.ios?.returnSeconds ?? 0, 31, accuracy: 0.001, "timings are reported even when declining")
        XCTAssertEqual(h.backend.verdictCalls, 0)
    }

    func testR20LimitComesFromTheRuleNotFromTheCode() async {
        let h = Harness(rules: rules(r20: 20))
        h.composer.returnSeconds = 25
        let outcome1 = await h.run()
        XCTAssertEqual(outcome1, .failed(.tokenExpired))

        let relaxed = Harness(rules: rules(r20: 60))
        relaxed.composer.returnSeconds = 25
        relaxed.backend.ttlSeconds = 120
        relaxed.backend.verdicts = [verdict(.verified, version: 2)]
        let outcome2 = await relaxed.run()
        XCTAssertEqual(outcome2, .verified(bindingId: nil))
    }

    func testR20OffNeverDeclinesOnTime() async {
        let h = Harness(rules: rules(r20: nil))
        h.composer.returnSeconds = 40
        h.backend.ttlSeconds = 120
        h.backend.verdicts = [verdict(.verified, version: 2)]
        let outcome3 = await h.run()
        XCTAssertEqual(outcome3, .verified(bindingId: nil))
    }

    func testTokenThatExpiredWhileTheUserWasInTheComposerIsDeclined() async {
        let h = Harness(rules: rules(r20: nil))
        h.backend.ttlSeconds = 45
        h.composer.returnSeconds = 50
        let outcome4 = await h.run()
        XCTAssertEqual(outcome4, .failed(.tokenExpired))
        XCTAssertEqual(h.backend.reports.first?.reason, .tokenExpired)
    }

    // MARK: R21

    func testNilIccidTokenIsMarkedAndDoesNotFailTheAttempt() async {
        let h = Harness()
        h.iccid.result = .nilToken
        h.backend.verdicts = [verdict(.verified, version: 2)]
        let outcome5 = await h.run()
        XCTAssertEqual(outcome5, .verified(bindingId: nil))
        XCTAssertEqual(h.backend.reports.first?.ios?.iccidTokenStatus, "NIL")
        XCTAssertNil(h.backend.reports.first?.ios?.iccidToken)
    }

    func testUnsupportedOSIsReportedAsUnsupported() async {
        let h = Harness()
        h.iccid.result = .unsupported
        h.backend.verdicts = [verdict(.verified, version: 2)]
        _ = await h.run()
        XCTAssertEqual(h.backend.reports.first?.ios?.iccidTokenStatus, "UNSUPPORTED")
    }

    func testIccidTokenIsNotRequestedWhenR21IsOff() async {
        let h = Harness(rules: rules(r21: false))
        h.backend.verdicts = [verdict(.verified, version: 2)]
        _ = await h.run()
        XCTAssertEqual(h.iccid.fetches, 0)
        XCTAssertEqual(h.backend.reports.first?.ios?.iccidTokenStatus, "NOT_REQUIRED")
    }

    func testIccidTokenIsNotRequestedWhenR19IsOffEvenIfR21IsOn() async {
        let h = Harness(rules: rules(r19: false, r21: true))
        h.composer.sendCompletion = nil
        h.backend.verdicts = [verdict(.verified, version: 2)]
        _ = await h.run(entitlement: false)
        XCTAssertEqual(h.iccid.fetches, 0, "PRD section 8: R21 needs R19")
    }

    // MARK: Reporting

    func testAFailedReportDoesNotEndTheAttempt() async {
        let h = Harness()
        h.backend.reportError = .transport
        h.backend.verdicts = [verdict(.verified, version: 2)]
        let outcome6 = await h.run()
        XCTAssertEqual(outcome6, .verified(bindingId: nil))
        XCTAssertEqual(h.backend.reports.count, 2, "one retry, then move on")
    }

    // MARK: Verdict

    func testRejectionReasonFromTheBackendIsMapped() async {
        let h = Harness()
        h.backend.verdicts = [verdict(.rejected, reason: "NUMBER_MISMATCH", version: 2)]
        let outcome7 = await h.run()
        XCTAssertEqual(outcome7, .failed(.numberMismatch))
    }

    func testUnknownRejectionReasonBecomesAGenericVerificationFailure() async {
        let h = Harness()
        h.backend.verdicts = [verdict(.rejected, reason: "WRONG_VMN", version: 2)]
        let outcome8 = await h.run()
        XCTAssertEqual(outcome8, .failed(.verificationFailed))
    }

    func testExpiredAndAbortedVerdictsMapToTheirErrors() async {
        let expired = Harness()
        expired.backend.verdicts = [verdict(.expired, version: 2)]
        let outcome9 = await expired.run()
        XCTAssertEqual(outcome9, .failed(.tokenExpired))

        let aborted = Harness()
        aborted.backend.verdicts = [verdict(.aborted, version: 2)]
        let outcome10 = await aborted.run()
        XCTAssertEqual(outcome10, .failed(.sessionInterrupted))
    }

    func testTransportErrorsWhilePollingFallBackToTheShortCadenceAndRecover() async {
        let h = Harness()
        h.backend.verdicts = [.failure(.transport), .failure(.transport), verdict(.verified, version: 2)]
        let outcome11 = await h.run()
        XCTAssertEqual(outcome11, .verified(bindingId: nil))
        XCTAssertEqual(h.sleeps.values, [1.5, 1.5])
    }

    func testABackendThatAnswersAtOnceIsNotHammered() async {
        let h = Harness()
        // The first answer at version 1 is progress (nothing was seen before); the two repeats of
        // the same version are not, so each of those must wait instead of spinning.
        h.backend.verdicts = [
            verdict(.sent, version: 1), verdict(.sent, version: 1), verdict(.sent, version: 1),
            verdict(.verified, version: 2)
        ]
        let outcome12 = await h.run()
        XCTAssertEqual(outcome12, .verified(bindingId: nil))
        XCTAssertEqual(h.sleeps.values, [1.5, 1.5], "an unchanged state_version must wait, not spin")
    }

    func testAnAttemptThatNeverCompletesEndsAsExpiredAfterTheGrace() async {
        let h = Harness()
        h.backend.verdicts = [verdict(.sent, version: 1)]
        let outcome13 = await h.run()
        XCTAssertEqual(outcome13, .failed(.tokenExpired))
        XCTAssertGreaterThan(h.backend.verdictCalls, 1)
        // 45 s token + 10 s grace, from the moment the token was issued.
        let elapsed = h.clock.now.timeIntervalSince(Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertGreaterThanOrEqual(elapsed, 55)
        XCTAssertLessThan(elapsed, 60)
    }

    func testABackendRefusalWhilePollingEndsTheAttemptWithItsReason() async {
        let h = Harness()
        h.backend.verdicts = [.failure(.rejected(.deviceBlocked, retryAfterSeconds: nil))]
        let outcome14 = await h.run()
        XCTAssertEqual(outcome14, .failed(.deviceBlocked))
    }

    func testProgressStatesAreReportedInOrder() async {
        let h = Harness()
        h.backend.verdicts = [verdict(.received, version: 2), verdict(.verified, version: 3)]
        let seen = StateLog()
        _ = await h.useCase.run(
            state: "s", msisdn: "+919812345621", upiEntitlementDeclared: true,
            onState: { seen.record($0) }
        )
        XCTAssertEqual(seen.values, [.issued, .sent, .received, .verified])
    }

    /// Found on a real device: a verdict that repeats the state the attempt is already in
    /// (the device just reported SENT, and the backend's first answer is also SENT) fired the
    /// progress callback again on every poll.
    func testAStateThatRepeatsIsReportedOnlyOnce() async {
        let h = Harness()
        h.backend.verdicts = [
            verdict(.sent, version: 1), verdict(.sent, version: 1), verdict(.sent, version: 2),
            verdict(.received, version: 3), verdict(.received, version: 3), verdict(.verified, version: 4)
        ]
        let seen = StateLog()
        let outcome = await h.useCase.run(
            state: "s", msisdn: "+919812345621", upiEntitlementDeclared: true,
            onState: { seen.record($0) }
        )
        XCTAssertEqual(outcome, .verified(bindingId: nil))
        XCTAssertEqual(seen.values, [.issued, .sent, .received, .verified], "each state exactly once")
    }

    final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [SmsBindingState] = []
        func record(_ value: SmsBindingState) { lock.locked { _values.append(value) } }
        var values: [SmsBindingState] { lock.locked { _values } }
    }
}
