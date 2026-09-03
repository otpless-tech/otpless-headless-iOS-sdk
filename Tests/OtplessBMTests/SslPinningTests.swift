//
//  SslPinningTests.swift
//  OtplessBMTests
//
//  End-to-end verification of the signed-envelope SSL pinning flow (iOS mirror of
//  otpless-headless-android-lite PR #39). These tests intentionally hit the real network:
//  the CloudFront manifest CDN and the live sigma.otpless.app TLS endpoint — they verify the
//  production material (anchors, baseline pins, envelope) actually works, not just the code.
//

import XCTest
@testable import OtplessBM

final class SslPinningTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Each test drives PinnedSessionProvider (a process singleton) through configure(),
        // which resets the fail-closed latch and rebuilds the manager, so ordering is safe.
        UserDefaults.standard.removeObject(forKey: PinConstants.manifestEnvelopeKey)
        UserDefaults.standard.removeObject(forKey: PinConstants.manifestLastFetchAtKey)
    }

    // MARK: - Vault

    func testVaultDecodesAnchorsAndBaselinePins() {
        XCTAssertEqual(OtplessKeyVault.verifyAnchors.count, 2, "expected primary + backup anchors")
        for anchor in OtplessKeyVault.verifyAnchors {
            let der = Data(base64Encoded: anchor)
            XCTAssertEqual(der?.count, 91, "anchor should be a P-256 SPKI (91 bytes DER)")
        }
        let sigmaPins = OtplessKeyVault.baselinePins["sigma.otpless.app"]
        XCTAssertEqual(sigmaPins?.count, 2, "expected current + rotation-backup pin")
        for pin in sigmaPins ?? [] {
            XCTAssertTrue(pin.hasPrefix("sha256/"), "pin must be in sha256/<base64> format: \(pin)")
        }
    }

    // MARK: - Envelope verification (live CDN)

    func testLiveEnvelopeVerifiesAndTamperIsRejected() async throws {
        let manager = OtplessSslPinManager(pinner: DynamicSPKIPinner())
        let (data, _) = try await URLSession.shared.data(from: PinConstants.manifestURL)
        let envelope = try XCTUnwrap(String(data: data, encoding: .utf8))

        // 1. The genuine envelope must verify and parse.
        let manifest = try XCTUnwrap(manager.verify(envelope), "live envelope failed signature verification")
        XCTAssertFalse(manifest.isExpired, "live envelope is expired — rotate it server-side")
        XCTAssertNotNil(manifest.pins["sigma.otpless.app"], "manifest must cover the user-auth host")

        // 2. A tampered payload must be rejected.
        var outer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(outer["payload"] as? String)
        // Flip one character of the base64url payload (swap the 10th char for a different one).
        let index = payload.index(payload.startIndex, offsetBy: 10)
        let original = payload[index]
        let replacement: Character = original == "A" ? "B" : "A"
        outer["payload"] = payload.replacingCharacters(in: index...index, with: String(replacement))
        let tamperedData = try JSONSerialization.data(withJSONObject: outer)
        let tampered = try XCTUnwrap(String(data: tamperedData, encoding: .utf8))
        XCTAssertNil(manager.verify(tampered), "tampered payload must fail signature verification")

        // 3. A valid-JSON envelope signed by nobody must be rejected.
        XCTAssertNil(manager.verify(#"{"payload":"eyJ2ZXIiOjF9","sig":"MEQCIA"}"#))
    }

    // MARK: - Defense-in-depth helpers

    func testRestrictToKnownHostsDropsForeignHosts() {
        let restricted = OtplessSslPinManager.restrictToKnownHosts([
            "sigma.otpless.app": ["sha256/x="],
            "evil.example.com": ["sha256/y="]
        ])
        XCTAssertEqual(Array(restricted.keys), ["sigma.otpless.app"], "manifest must not install pins for hosts outside the baseline")
    }

    func testUnionNeverRemovesBaselinePins() {
        let merged = OtplessSslPinManager.union(
            ["sigma.otpless.app": ["sha256/base="]],
            ["sigma.otpless.app": ["sha256/remote=", "sha256/base="]]
        )
        XCTAssertEqual(merged["sigma.otpless.app"], ["sha256/base=", "sha256/remote="], "baseline pins must survive and duplicates must collapse")
    }

    // MARK: - Bootstrap (live CDN) + cache

    func testBootstrapAppliesPinsAndSecondBootstrapUsesCache() async {
        let pinner = DynamicSPKIPinner()
        let manager = OtplessSslPinManager(pinner: pinner)
        await manager.bootstrap()
        XCTAssertTrue(manager.isSslDone, "remote bootstrap should succeed")
        let applied = pinner.currentPins()["sigma.otpless.app"] ?? []
        XCTAssertEqual(Set(applied), Set(OtplessKeyVault.baselinePins["sigma.otpless.app"] ?? []), "envelope pins currently equal the baseline")

        let cachedEnvelope: String = SecureStorage.shared.getFromUserDefaults(key: PinConstants.manifestEnvelopeKey, defaultValue: "")
        XCTAssertFalse(cachedEnvelope.isEmpty, "bootstrap must cache the fetched envelope")

        // Second manager should apply from cache (observable as isSslDone without clearing it).
        let secondPinner = DynamicSPKIPinner()
        let secondManager = OtplessSslPinManager(pinner: secondPinner)
        await secondManager.bootstrap()
        XCTAssertTrue(secondManager.isSslDone, "cache-first bootstrap should succeed")
        XCTAssertFalse(secondPinner.currentPins().isEmpty)
    }

    // MARK: - Live TLS through the shared pinned session

    func testSslEnabledRequestToPinnedHostSucceeds() async throws {
        let provider = PinnedSessionProvider.shared
        provider.configure(sslKind: .sslEnabled)
        await provider.bootstrap()
        XCTAssertTrue(provider.isOkSsl)

        // Any HTTP status is fine — the TLS handshake passing the pin check is what's under test.
        let (_, response) = try await provider.session.data(from: URL(string: "https://sigma.otpless.app/")!)
        XCTAssertTrue(response is HTTPURLResponse, "pinned request should complete the TLS handshake")
        XCTAssertFalse(provider.isPinFailedPersistent)
    }

    func testWrongCustomPinsFailClosedAndLatch() async {
        // Uses click.otpless.app (same *.otpless.app wildcard cert) rather than sigma: other
        // tests in this suite open pooled TLS connections to sigma through the shared session,
        // and URLSession only fires the trust challenge on a NEW handshake — a reused connection
        // would bypass the freshly-configured wrong pins. Pinning is handshake-time enforcement
        // on both platforms; the test just needs a host with no pooled connection.
        let provider = PinnedSessionProvider.shared
        provider.configure(sslKind: .customSsl(pins: [
            "click.otpless.app": ["sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="]
        ]))
        XCTAssertFalse(provider.isPinFailedPersistent)

        do {
            _ = try await provider.session.data(from: URL(string: "https://click.otpless.app/")!)
            XCTFail("request must not succeed when pins mismatch")
        } catch {
            XCTAssertEqual((error as NSError).code, NSURLErrorCancelled, "pin mismatch should cancel the challenge")
        }
        XCTAssertTrue(provider.isPinFailedPersistent, "pin failure must latch fail-closed for the session")

        // Re-initialising resets the latch (Android rebuilds its pinning stack per init).
        provider.configure(sslKind: .sslDisabled)
        XCTAssertFalse(provider.isPinFailedPersistent)
    }

    func testSslDisabledAndUnknownHostsPassThrough() async throws {
        let provider = PinnedSessionProvider.shared

        provider.configure(sslKind: .sslDisabled)
        let (_, disabledResponse) = try await provider.session.data(from: URL(string: "https://sigma.otpless.app/")!)
        XCTAssertTrue(disabledResponse is HTTPURLResponse)

        // .sslEnabled, but api.otpless.com is not in the pin set — must pass through on system trust.
        provider.configure(sslKind: .sslEnabled)
        await provider.bootstrap()
        let (_, apiResponse) = try await provider.session.data(from: URL(string: "https://api.otpless.com/")!)
        XCTAssertTrue(apiResponse is HTTPURLResponse)
        XCTAssertFalse(provider.isPinFailedPersistent)
    }
}
