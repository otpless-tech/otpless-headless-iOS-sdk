//
//  SmsBindingGateTests.swift
//  OtplessBMTests
//
//  The opt-in gate: outbound SMS binding is off unless the app's merchant config switches it on.
//

import XCTest
@testable import OtplessBM

final class SmsBindingGateTests: XCTestCase {

    private func config(_ json: String) throws -> MerchantConfigResponse {
        try JSONDecoder().decode(MerchantConfigResponse.self, from: Data(json.utf8))
    }

    override func tearDown() {
        Otpless.shared.useLiveSmsBinding()
        super.tearDown()
    }

    func testOffUnlessTheConfigSaysTrue() throws {
        XCTAssertFalse(try config(#"{"merchant":{"config":{}}}"#).isOutboundSmsBindingEnabled, "field absent")
        XCTAssertFalse(try config(#"{"merchant":{"config":{"outboundSmsBindingConfig":null}}}"#).isOutboundSmsBindingEnabled)
        XCTAssertFalse(try config(#"{"merchant":{"config":{"outboundSmsBindingConfig":{}}}}"#).isOutboundSmsBindingEnabled)
        XCTAssertFalse(try config(#"{"merchant":{"config":{"outboundSmsBindingConfig":{"isEnabled":null}}}}"#).isOutboundSmsBindingEnabled)
        XCTAssertFalse(try config(#"{"merchant":{"config":{"outboundSmsBindingConfig":{"isEnabled":false}}}}"#).isOutboundSmsBindingEnabled)
        XCTAssertTrue(try config(#"{"merchant":{"config":{"outboundSmsBindingConfig":{"isEnabled":true}}}}"#).isOutboundSmsBindingEnabled)
    }

    func testNoConfigAtAllIsClosed() {
        XCTAssertFalse(SmsBindingGate.isOpen(merchantConfig: nil))
        XCTAssertEqual(SmsBindingGate.notEnabledCode, "FEATURE_NOT_ENABLED")
    }

    func testTheGateReadsTheFlagAndNothingElse() throws {
        let on = try config(#"{"isMFAEnabled":true,"merchant":{"config":{"isAttestationEnabled":true,"outboundSmsBindingConfig":{"isEnabled":true,"future":1}}},"x":2}"#)
        XCTAssertTrue(SmsBindingGate.isOpen(merchantConfig: on))
        XCTAssertTrue(on.isAppAttestEnabled, "the neighbouring flag still decodes")

        let attestOnly = try config(#"{"merchant":{"config":{"isAttestationEnabled":true}}}"#)
        XCTAssertFalse(SmsBindingGate.isOpen(merchantConfig: attestOnly))
    }

    #if DEBUG
    func testADebugMockBypassesTheGateAndLiveDoesNot() {
        Otpless.shared.useMockSmsBinding(.verifiedStandard, vmn: "+919000000007")
        XCTAssertTrue(Otpless.shared.isSmsBindingAvailable, "a mock never touches the network, so it needs no onboarding")

        Otpless.shared.useLiveSmsBinding()
        XCTAssertFalse(Otpless.shared.isSmsBindingAvailable, "live mode with no switched-on config is closed")
    }
    #endif
}
