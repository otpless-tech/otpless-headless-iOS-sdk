//
//  SmsBindingCoreTests.swift
//  OtplessBMTests
//
//  Outbound SMS SIM binding (ENG-622): the rules model, the pre-checks and the attempt state
//  machine. Hermetic: no SIM, no composer, no network.
//

import XCTest
@testable import OtplessBM

private struct FakeDevice: SmsBindingDevice {
    var osVersion = "27.0"
    var appVersion = "3.2.0"
    var hasCellularRadio = true
    var canSendText = true
}

private func rulesJSON(template: String? = "NPCI", rules: String) -> Data {
    let templateMember = template.map { "\"template\": \"\($0)\"," } ?? ""
    return Data("""
    { \(templateMember) "config_version": 12, "rules_hash": "r_9c41e0", "sms_template": "{token}",
      "rules": { \(rules) } }
    """.utf8)
}

private let npciRules = """
"sim_present": {"enabled": true}, "airplane_mode_block": {"enabled": true},
"min_app_version": {"enabled": true, "version": "3.2.0"},
"min_os": {"enabled": true, "android_api": 23, "ios": "17.0"},
"ios_upi_entitlement": {"enabled": true},
"ios_composer_return": {"enabled": true, "max_seconds": 20},
"ios_iccid_token": {"enabled": true}
"""

final class SmsBindingCoreTests: XCTestCase {

    // MARK: - Rules decoding

    func testDecodesVersionHashTemplateAndRuleValues() throws {
        let rules = try XCTUnwrap(SmsBindingRules.decode(rulesJSON(rules: npciRules)))
        XCTAssertEqual(rules.configVersion, 12)
        XCTAssertEqual(rules.rulesHash, "r_9c41e0")
        XCTAssertEqual(rules.smsTemplate, "{token}")
        XCTAssertEqual(rules.composerReturnLimit, 20)
        XCTAssertEqual(rules.minimumAppVersion, "3.2.0")
        XCTAssertEqual(rules.minimumOSVersion, "17.0")
        XCTAssertTrue(rules.requiresUpiEntitlement)
        XCTAssertTrue(rules.requiresIccidToken)
    }

    func testMissingRuleIsOffAndUnknownKeysAreIgnored() throws {
        let rules = try XCTUnwrap(SmsBindingRules.decode(rulesJSON(rules: """
        "some_future_rule": {"enabled": true, "x": 1}, "vmn_random_pick": {"enabled": true}
        """)))
        XCTAssertFalse(rules.requiresUpiEntitlement)
        XCTAssertNil(rules.composerReturnLimit)
        XCTAssertNil(rules.minimumAppVersion)
    }

    func testRejectsAPayloadThatIsNotARulesDocument() {
        XCTAssertNil(SmsBindingRules.decode(Data("{}".utf8)))
        XCTAssertNil(SmsBindingRules.decode(Data("not json".utf8)))
        XCTAssertNil(SmsBindingRules.decode(Data(#"{"config_version": 1}"#.utf8)))
    }

    func testComposerReturnDefaultsTo30SecondsWhenOnWithoutAValue() throws {
        let rules = try XCTUnwrap(SmsBindingRules.decode(rulesJSON(rules: #""ios_composer_return": {"enabled": true}"#)))
        XCTAssertEqual(rules.composerReturnLimit, 30)
    }

    func testDisabledRuleHidesItsValues() throws {
        let rules = try XCTUnwrap(SmsBindingRules.decode(rulesJSON(rules: """
        "ios_composer_return": {"enabled": false, "max_seconds": 5},
        "min_app_version": {"enabled": false, "version": "9.9.9"}
        """)))
        XCTAssertNil(rules.composerReturnLimit)
        XCTAssertNil(rules.minimumAppVersion)
    }

    /// PRD section 8: R21 needs R19. The payload cannot turn the token on by itself.
    func testIccidTokenIsIgnoredWithoutTheEntitlementRule() throws {
        let rules = try XCTUnwrap(SmsBindingRules.decode(rulesJSON(rules: #""ios_iccid_token": {"enabled": true}"#)))
        XCTAssertTrue(rules.isOn(.iosIccidToken))
        XCTAssertFalse(rules.requiresIccidToken)
    }

    /// The ticket's acceptance criterion: behaviour follows the rules, never the template name.
    func testTemplateNameNeverChangesBehaviour() throws {
        let device = FakeDevice(hasCellularRadio: false)
        let results = try ["NPCI", "Standard", "SomethingNew", nil].map { template -> SmsBindingFailure? in
            let rules = try XCTUnwrap(SmsBindingRules.decode(rulesJSON(template: template, rules: npciRules)))
            return SmsBindingPrechecks.evaluate(rules: rules, device: device, upiEntitlementDeclared: true)
        }
        XCTAssertEqual(Set(results.map { $0?.rawValue ?? "none" }), ["NO_SIM"])
    }

    func testChangingARuleValueChangesTheOutcomeWithNoCodeChange() throws {
        let device = FakeDevice(osVersion: "17.0")
        let strict = try XCTUnwrap(SmsBindingRules.decode(rulesJSON(rules: #""min_os": {"enabled": true, "ios": "18.0"}"#)))
        let relaxed = try XCTUnwrap(SmsBindingRules.decode(rulesJSON(rules: #""min_os": {"enabled": true, "ios": "17.0"}"#)))
        XCTAssertEqual(SmsBindingPrechecks.evaluate(rules: strict, device: device, upiEntitlementDeclared: true), .upgradeRequired)
        XCTAssertNil(SmsBindingPrechecks.evaluate(rules: relaxed, device: device, upiEntitlementDeclared: true))
    }

    // MARK: - Version comparison

    func testVersionComparisonIsNumericNotLexical() {
        XCTAssertTrue(SmsBindingVersion.isAtLeast("3.10.0", minimum: "3.9.2"))
        XCTAssertFalse(SmsBindingVersion.isAtLeast("3.9.2", minimum: "3.10.0"))
        XCTAssertTrue(SmsBindingVersion.isAtLeast("17", minimum: "17.0"))
        XCTAssertTrue(SmsBindingVersion.isAtLeast("17.0.1", minimum: "17.0"))
        XCTAssertFalse(SmsBindingVersion.isAtLeast("16.7.2", minimum: "17.0"))
        XCTAssertTrue(SmsBindingVersion.isAtLeast("3.2.0-beta1", minimum: "3.2.0"))
    }

    // MARK: - Pre-checks

    private func npci() throws -> SmsBindingRules {
        try XCTUnwrap(SmsBindingRules.decode(rulesJSON(rules: npciRules)))
    }

    func testAllChecksPassOnAHealthyDevice() throws {
        XCTAssertNil(SmsBindingPrechecks.evaluate(rules: try npci(), device: FakeDevice(), upiEntitlementDeclared: true))
    }

    func testOldAppAndOldOSRequireAnUpgrade() throws {
        let rules = try npci()
        XCTAssertEqual(SmsBindingPrechecks.evaluate(rules: rules, device: FakeDevice(appVersion: "3.1.9"), upiEntitlementDeclared: true), .upgradeRequired)
        XCTAssertEqual(SmsBindingPrechecks.evaluate(rules: rules, device: FakeDevice(osVersion: "16.7"), upiEntitlementDeclared: true), .upgradeRequired)
    }

    func testNoRadioMeansNoSimAndCannotSendTextMeansNoSim() throws {
        let rules = try npci()
        XCTAssertEqual(SmsBindingPrechecks.evaluate(rules: rules, device: FakeDevice(hasCellularRadio: false), upiEntitlementDeclared: true), .noSim)
        XCTAssertEqual(SmsBindingPrechecks.evaluate(rules: rules, device: FakeDevice(canSendText: false), upiEntitlementDeclared: true), .noSim)
    }

    func testRadioIsNotCheckedWhenBothSimRulesAreOff() throws {
        let rules = try XCTUnwrap(SmsBindingRules.decode(rulesJSON(rules: #""ios_composer_return": {"enabled": true}"#)))
        XCTAssertNil(SmsBindingPrechecks.evaluate(rules: rules, device: FakeDevice(hasCellularRadio: false), upiEntitlementDeclared: false))
    }

    func testMissingEntitlementDeclarationNeverFallsBackSilently() throws {
        XCTAssertEqual(SmsBindingPrechecks.evaluate(rules: try npci(), device: FakeDevice(), upiEntitlementDeclared: false), .entitlementMissing)
    }

    func testEntitlementIsNotRequiredWhenTheRuleIsOff() throws {
        let rules = try XCTUnwrap(SmsBindingRules.decode(rulesJSON(rules: #""sim_present": {"enabled": true}"#)))
        XCTAssertNil(SmsBindingPrechecks.evaluate(rules: rules, device: FakeDevice(), upiEntitlementDeclared: false))
    }

    func testUpgradeIsReportedBeforeSimAndSimBeforeEntitlement() throws {
        let rules = try npci()
        let broken = FakeDevice(appVersion: "1.0", hasCellularRadio: false)
        XCTAssertEqual(SmsBindingPrechecks.evaluate(rules: rules, device: broken, upiEntitlementDeclared: false), .upgradeRequired)
        let simOnly = FakeDevice(hasCellularRadio: false)
        XCTAssertEqual(SmsBindingPrechecks.evaluate(rules: rules, device: simOnly, upiEntitlementDeclared: false), .noSim)
    }

    // MARK: - Failure reasons

    func testBackendReasonsMapAndUnknownOnesBecomeVerificationFailed() {
        XCTAssertEqual(SmsBindingFailure(backendReason: "NUMBER_MISMATCH"), .numberMismatch)
        XCTAssertEqual(SmsBindingFailure(backendReason: "DEVICE_BLOCKED"), .deviceBlocked)
        XCTAssertEqual(SmsBindingFailure(backendReason: "UNKNOWN_TOKEN"), .verificationFailed)
        XCTAssertEqual(SmsBindingFailure(backendReason: "WRONG_VMN"), .verificationFailed)
        XCTAssertEqual(SmsBindingFailure(backendReason: nil), .verificationFailed)
    }

    func testRetryableMatchesThePRDGuidance() {
        XCTAssertTrue(SmsBindingFailure.tokenExpired.isRetryable)
        XCTAssertTrue(SmsBindingFailure.numberMismatch.isRetryable)
        XCTAssertFalse(SmsBindingFailure.entitlementMissing.isRetryable)
        XCTAssertFalse(SmsBindingFailure.deviceBlocked.isRetryable)
        XCTAssertFalse(SmsBindingFailure.upgradeRequired.isRetryable)
    }

    // MARK: - Attempt state machine

    private func attempt() -> SmsBindingAttempt {
        SmsBindingAttempt(attemptId: "att_1", vmn: "+919000000007", smsBody: "tok", ttlSeconds: 45)
    }

    func testHappyPathMovesForwardToVerified() {
        var attempt = attempt()
        XCTAssertEqual(attempt.state, .issued)
        XCTAssertTrue(attempt.advance(to: .sent))
        XCTAssertTrue(attempt.advance(to: .received))
        XCTAssertTrue(attempt.advance(to: .verified))
        XCTAssertTrue(attempt.state.isFinal)
    }

    /// The VMN often hears the SMS before the device reports it, so the backend can jump ahead.
    func testServerStateMaySkipForward() {
        var attempt = attempt()
        XCTAssertTrue(attempt.advance(to: .received))
        XCTAssertTrue(attempt.advance(to: .verified))
    }

    func testNothingMovesOutOfAFinalState() {
        for final in [SmsBindingState.verified, .rejected, .expired, .aborted] {
            var attempt = attempt()
            XCTAssertTrue(attempt.advance(to: final, failure: .tokenExpired))
            for other in [SmsBindingState.issued, .sent, .received, .verified, .rejected, .expired, .aborted] where other != final {
                XCTAssertFalse(attempt.advance(to: other), "\(final) must not move to \(other)")
            }
            XCTAssertEqual(attempt.state, final)
        }
    }

    func testStateNeverMovesBackwards() {
        var attempt = attempt()
        attempt.advance(to: .received)
        XCTAssertFalse(attempt.advance(to: .sent))
        XCTAssertFalse(attempt.advance(to: .issued))
        XCTAssertEqual(attempt.state, .received)
    }

    func testRepeatingTheCurrentStateIsHarmless() {
        var attempt = attempt()
        attempt.advance(to: .sent)
        XCTAssertTrue(attempt.advance(to: .sent))
    }

    func testFailureIsRecordedOnlyForUnsuccessfulFinalStates() {
        var rejected = attempt()
        rejected.advance(to: .rejected, failure: .numberMismatch)
        XCTAssertEqual(rejected.failure, .numberMismatch)

        var verified = attempt()
        verified.advance(to: .verified, failure: .numberMismatch)
        XCTAssertNil(verified.failure)
    }

    func testAnIllegalMoveLeavesTheFailureUntouched() {
        var attempt = attempt()
        attempt.advance(to: .expired, failure: .tokenExpired)
        attempt.advance(to: .rejected, failure: .numberMismatch)
        XCTAssertEqual(attempt.state, .expired)
        XCTAssertEqual(attempt.failure, .tokenExpired)
    }
}
