//
//  SimDeviceContextTests.swift
//  OtplessBMTests
//
//  ENG-628 item 5 / ENG-627: the device context sent at flow start.
//

import XCTest
@testable import OtplessBM

final class SimDeviceContextTests: XCTestCase {

    func testTheContextUsesTheFieldNamesENG627Gives() {
        let context = SimDeviceContext.dictionary(osVersion: "27.0.1", planStatusSupported: true, upiEntitlement: false)
        XCTAssertEqual(Set(context.keys), ["platform", "os_version", "plan_status_supported", "upi_entitlement"])
        XCTAssertEqual(context["platform"] as? String, "ios")
        XCTAssertEqual(context["os_version"] as? String, "27.0.1")
        XCTAssertEqual(context["plan_status_supported"] as? Bool, true)
        XCTAssertEqual(context["upi_entitlement"] as? Bool, false)
    }

    func testAnAppThatHasNotSwitchedSmsBindingOnSendsNothingExtra() {
        XCTAssertNil(SimDeviceContext.forIntent(
            smsBindingEnabled: false, osVersion: "27.0.1", planStatusSupported: true, upiEntitlement: true
        ), "existing integrations must send the intent they always did")
    }

    func testAnOnboardedAppSendsTheContextOnItsNormalIntent() throws {
        let context = try XCTUnwrap(SimDeviceContext.forIntent(
            smsBindingEnabled: true, osVersion: "26.7", planStatusSupported: false, upiEntitlement: true
        ))
        XCTAssertEqual(context["plan_status_supported"] as? Bool, false, "an iOS 26 phone is not on the plan-status path")
        XCTAssertEqual(context["upi_entitlement"] as? Bool, true)
    }

    func testTheHostsEntitlementDeclarationIsRememberedAndDefaultsToFalse() {
        let before = UpiEntitlementDeclaration.shared.declared
        defer { UpiEntitlementDeclaration.shared.declared = before }

        UpiEntitlementDeclaration.shared.declared = false
        XCTAssertFalse(UpiEntitlementDeclaration.shared.declared)
        Otpless.shared.setUpiEntitlementDeclared(true)
        XCTAssertTrue(UpiEntitlementDeclaration.shared.declared)
        Otpless.shared.setUpiEntitlementDeclared(false)
        XCTAssertFalse(UpiEntitlementDeclaration.shared.declared)
    }

    func testAnSdkThatHasFetchedNoConfigSendsNoContext() {
        // SMS binding is off until the merchant config switches it on, so nothing extra is sent.
        XCTAssertNil(Otpless.shared.deviceContextForIntent())
    }
}
