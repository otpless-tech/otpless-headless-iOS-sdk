//
//  SmsBindingPolishTests.swift
//  OtplessBMTests
//
//  The PRD's UX wording (section 17), the failure messages that use the number or a retry time, and
//  the rule values the PRD does not name.
//

import XCTest
@testable import OtplessBM

final class SmsBindingCopyTests: XCTestCase {

    func testTheNumberIsMaskedLikeThePRDExample() {
        XCTAssertEqual(SmsBindingCopy.mask(countryCode: "+91", national: "8980994455"), "+91 89xxxxxx55")
        XCTAssertEqual(SmsBindingCopy.mask(countryCode: "91", national: "9876543210"), "+91 98xxxxxx10")
        XCTAssertEqual(SmsBindingCopy.mask(countryCode: "+1", national: "4155550123"), "+1 41xxxxxx23")
        XCTAssertEqual(SmsBindingCopy.mask(countryCode: "+91", national: "123"), "+91 xxx", "too short to show any digits")
    }

    func testThePreSendMessageSaysChargesAndPrefilledAndNamesTheLineOnlyOnDualSim() {
        let single = SmsBindingCopy.preSendMessage(lastDigits: "4455", dualSim: false)
        XCTAssertTrue(single.contains("We'll send a verification SMS from this SIM. Standard SMS charges may apply."))
        XCTAssertTrue(single.contains("Tap Send without changing it."))
        XCTAssertFalse(single.contains("more than one active line"))

        let dual = SmsBindingCopy.preSendMessage(lastDigits: "4455", dualSim: true)
        XCTAssertTrue(dual.contains("more than one active line"))
        XCTAssertTrue(dual.contains("ending in 4455"))
        XCTAssertTrue(dual.contains("Standard SMS charges may apply."), "the standard lines stay")
    }

    func testMismatchNamesTheLineToSendFromWhenTheNumberIsKnown() {
        let context = SmsBindingFailureContext(maskedNumber: "+91 89xxxxxx55")
        XCTAssertEqual(
            SmsBindingCopy.failure(code: "NUMBER_MISMATCH", context: context),
            "This SMS came from a different number. Send it from the line with +91 89xxxxxx55."
        )
        XCTAssertTrue(SmsBindingCopy.failure(code: "NUMBER_MISMATCH").contains("different number"), "and has wording without it")
    }

    func testABlockSaysHowLongWhenKnown() {
        XCTAssertEqual(SmsBindingCopy.failure(code: "DEVICE_BLOCKED", context: .init(retryAfterSeconds: 6 * 3600)),
                       "Too many attempts. You can try again in about 6 hours.")
        XCTAssertEqual(SmsBindingCopy.failure(code: "DEVICE_BLOCKED", context: .init(retryAfterSeconds: 1800)),
                       "Too many attempts. You can try again in about 30 minutes.")
        XCTAssertEqual(SmsBindingCopy.failure(code: "DEVICE_BLOCKED"), "Too many attempts. Please try again later.")
    }

    func testDurations() {
        XCTAssertEqual(SmsBindingCopy.duration(seconds: 3600), "1 hour")
        XCTAssertEqual(SmsBindingCopy.duration(seconds: 7200), "2 hours")
        XCTAssertEqual(SmsBindingCopy.duration(seconds: 60), "1 minute")
        XCTAssertEqual(SmsBindingCopy.duration(seconds: 10), "1 minute", "never says 0 minutes")
    }

    func testTheCountdownReadsMinutesAndSecondsAndNeverGoesNegative() {
        XCTAssertEqual(SmsBindingCopy.timeLeft(seconds: 102), "Time left 1:42")
        XCTAssertEqual(SmsBindingCopy.timeLeft(seconds: 9), "Time left 0:09")
        XCTAssertEqual(SmsBindingCopy.timeLeft(seconds: -3), "Time left 0:00")
    }

    func testNoSimWordingCoversAirplaneModeBecauseIOSCannotTellThemApart() {
        let text = SmsBindingCopy.failure(code: "NO_SIM")
        XCTAssertTrue(text.contains("SIM") && text.lowercased().contains("airplane mode"))
    }

    func testThePublicFailureMessageUsesWhatItCarries() {
        let mismatch = OtplessSmsBindingFailure(.numberMismatch, maskedNumber: "+91 89xxxxxx55")
        XCTAssertTrue(mismatch.message.contains("+91 89xxxxxx55"))
        let blocked = OtplessSmsBindingFailure(.deviceBlocked, retryAfterSeconds: 21600)
        XCTAssertTrue(blocked.message.contains("6 hours"))
        XCTAssertNil(OtplessSmsBindingFailure(.tokenExpired).maskedNumber)
    }
}

final class SmsBindingRetryabilityTests: XCTestCase {
    /// Found on a device with no network: the message said "try again" but no button was offered.
    func testAFailedCallIsRetryableAndTheRefusalsThatCannotHelpAreNot() {
        XCTAssertTrue(SmsBindingFailure.internalError.isRetryable)
        XCTAssertTrue(OtplessSmsBindingFailure(.internalError).isRetryable)
        for failure in [SmsBindingFailure.noSim, .upgradeRequired, .entitlementMissing, .deviceBlocked,
                        .vmnPoolUnavailable, .verificationFailed, .notAvailable, .invalidPhoneNumber] {
            XCTAssertFalse(failure.isRetryable, failure.rawValue)
        }
        for failure in [SmsBindingFailure.smsSendFailed, .numberMismatch, .tokenExpired, .sessionInterrupted] {
            XCTAssertTrue(failure.isRetryable, failure.rawValue)
        }
    }
}

final class SmsBindingRuleValueTests: XCTestCase {

    private func decode(_ rulesJSON: String) throws -> SmsBindingRules {
        try XCTUnwrap(SmsBindingRules.decode(Data(#"{"config_version":1,"rules_hash":"h","rules":{\#(rulesJSON)}}"#.utf8)))
    }

    func testTheMinimumAppVersionIsReadUnderLikelyValueNames() throws {
        for name in ["version", "min_version", "app_version", "value"] {
            let rules = try decode(#""min_app_version": {"enabled": true, "\#(name)": "3.4.0"}"#)
            XCTAssertEqual(rules.minimumAppVersion, "3.4.0", name)
        }
        XCTAssertNil(try decode(#""min_app_version": {"enabled": false, "version": "3.4.0"}"#).minimumAppVersion, "off means off")
    }

    func testTheMinimumIOSVersionIsReadUnderLikelyValueNames() throws {
        for name in ["ios", "ios_version", "min_ios", "version"] {
            let rules = try decode(#""min_os": {"enabled": true, "android_api": 23, "\#(name)": "17.0"}"#)
            XCTAssertEqual(rules.minimumOSVersion, "17.0", name)
        }
        XCTAssertNil(try decode(#""min_os": {"enabled": true, "android_api": 23}"#).minimumOSVersion, "only an iOS value counts")
    }

    func testTheBlockLengthComesFromTheAttemptLimit() throws {
        let rules = try decode(#""attempt_limit": {"enabled": true, "max": 5, "window_h": 24, "block_h": 6}"#)
        XCTAssertEqual(rules.attemptBlockHours, 6)
        XCTAssertNil(try decode(#""attempt_limit": {"enabled": false, "block_h": 6}"#).attemptBlockHours)
    }
}

final class SmsBindingBlockMemoryTests: XCTestCase {
    func testItRemembersAPositiveLengthAndIgnoresNothing() {
        let memory = SmsBindingBlockMemory(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertNil(memory.hours)
        memory.remember(nil)
        memory.remember(0)
        XCTAssertNil(memory.hours)
        memory.remember(6)
        XCTAssertEqual(memory.hours, 6)
        memory.remember(nil)
        XCTAssertEqual(memory.hours, 6, "a response without it does not erase what was known")
    }
}
