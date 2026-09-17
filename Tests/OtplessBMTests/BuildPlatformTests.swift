//
//  BuildPlatformTests.swift
//  OtplessBMTests
//
//  Covers `Otpless.setBuildPlatform(_:)` — the wrapper attribution API used by the
//  Flutter / React Native wrappers — and the telemetry string it feeds.
//  Hermetic: no network, no `initialise()`.
//

import XCTest
@testable import OtplessBM

final class BuildPlatformTests: XCTestCase {

    /// `Otpless.shared` is a process-wide singleton, so restore the shipped default
    /// after every case to keep these tests order-independent and not leak into others.
    override func tearDown() {
        Otpless.shared.setBuildPlatform(Constants.DEFAULT_BUILD_PLATFORM)
        super.tearDown()
    }

    func testDefaultBuildPlatformIsIos() {
        XCTAssertEqual(Otpless.shared.buildPlatform, "ios")
    }

    /// The default device-event attribution must stay byte-identical to pre-3.0.1.
    func testDefaultPlatformAttributionIsUnchanged() {
        XCTAssertEqual(OtplessBMEvents.Device.platformAttribution, "otpless-headless(ios)")
    }

    func testSetBuildPlatformIsReflectedInAttribution() {
        Otpless.shared.setBuildPlatform("flutter")

        XCTAssertEqual(Otpless.shared.buildPlatform, "flutter")
        XCTAssertEqual(OtplessBMEvents.Device.platformAttribution, "otpless-headless(flutter)")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        Otpless.shared.setBuildPlatform("  react-native \n")

        XCTAssertEqual(Otpless.shared.buildPlatform, "react-native")
        XCTAssertEqual(OtplessBMEvents.Device.platformAttribution, "otpless-headless(react-native)")
    }

    /// A wrapper bug must never be able to emit `otpless-headless()`.
    func testBlankValuesAreIgnoredAndKeepPreviousValue() {
        Otpless.shared.setBuildPlatform("flutter")

        for blank in ["", " ", "\t", "\n", "   \n  \t "] {
            Otpless.shared.setBuildPlatform(blank)
            XCTAssertEqual(Otpless.shared.buildPlatform, "flutter", "blank input \(blank.debugDescription) overwrote the value")
        }
        XCTAssertEqual(OtplessBMEvents.Device.platformAttribution, "otpless-headless(flutter)")
    }

    /// Nothing was ever set, and a blank arrives first: the default must survive.
    func testBlankValueOnUntouchedSdkKeepsDefault() {
        Otpless.shared.setBuildPlatform("   ")

        XCTAssertEqual(Otpless.shared.buildPlatform, "ios")
        XCTAssertEqual(OtplessBMEvents.Device.platformAttribution, "otpless-headless(ios)")
    }

    /// Wrappers call the setter from their bridge before `initialise()`, while the device
    /// event is pushed from inside the init Task. Hammer both sides for TSan/races.
    func testConcurrentSetAndReadNeverYieldsEmptyAttribution() {
        let iterations = 500
        let writers = DispatchQueue(label: "bp.writer", attributes: .concurrent)
        let expectation = expectation(description: "concurrent access finished")
        expectation.expectedFulfillmentCount = 2

        writers.async {
            for i in 0..<iterations {
                Otpless.shared.setBuildPlatform(i.isMultiple(of: 2) ? "flutter" : "  react-native  ")
            }
            expectation.fulfill()
        }
        writers.async {
            for _ in 0..<iterations {
                let attribution = OtplessBMEvents.Device.platformAttribution
                XCTAssertTrue(
                    attribution == "otpless-headless(flutter)" || attribution == "otpless-headless(react-native)" || attribution == "otpless-headless(ios)",
                    "unexpected attribution: \(attribution)"
                )
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10)
    }
}
