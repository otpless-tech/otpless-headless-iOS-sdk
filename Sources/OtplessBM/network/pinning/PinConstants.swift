//
//  PinConstants.swift
//  OtplessBM
//

import Foundation

/// Constants for the signed, refreshable SSL pin envelope flow — the iOS mirror of the Android
/// SDK's `OtplessVaultConstant` + `OtplessSslPinManager` companion constants (see
/// otpless-headless-android-lite PR #39). The obfuscated hex blobs below are byte-for-byte the
/// same production material the Android vault ships: they are emitted by Android's
/// `:LongClaw:refreshKeyVault` Gradle task (source of truth: AWS KMS aliases
/// `alias/sdk-pin-signer-{primary,backup}-4096` + Secrets Manager
/// `otpless-app/wildcard/4096-baseline-pin-*`). To rotate, re-run that task and copy the
/// regenerated constants here.
internal enum PinConstants {

    /// 16 bytes (hex-encoded), XORed into the blobs cycling by `i mod 16`.
    static let saltHex = "9F3AC18D7E42B5601FE7248BD936A471"

    /// XOR-obfuscated; decodes to newline-separated base64 DER `SubjectPublicKeyInfo` strings —
    /// the ECDSA P-256 public keys ("anchors") that every pin envelope's signature is verified
    /// against before its pins are trusted. Two anchors so the server can rotate signing keys
    /// without shipping a new SDK; any single anchor matching is enough.
    static let verifyAnchorsHex = "D27CAAFA3B35EC2854887EC2A35C9432DE6B98C4352DEF29658D14CF9867C735CE5D80C83A35D03258844CFBB704C649C958A4BC3808DF572F8D65E1A302EE32EB0BEAC8133AE3514EA066C3B1469202D20EA0BE273384562CBE65DBAD459418EA7BA5E34731C43477B312E3BA19ED3CD64FA8F52634FE524A8019B6D37BE21AE87FB6D43609DA3A569D4EBB9A77F528D671AED73738DF505BA675E89D67C330DA7588F54C1AF60866C86DFAE140F11FF50F8CBF172D80186AC86DB9B85EF639DE088FC12A11FB167AB145E6AD50E133CB7DA6EE110DFE045C846ACAB3058B1EF06BBBE82E2DEC2D59A40FA4EF07FC3BDD6C88E31F18D25D22ED"

    /// XOR-obfuscated; decodes to `host\tpin\tpin\n` lines in the standard `sha256/<base64>`
    /// SPKI format (same string format OkHttp's `CertificatePinner` uses, so pins are
    /// copy-paste-shareable with the Android SDK).
    static let baselinePinsHex = "EC53A6E01F6CDA146F8B41F8AA18C501EF33B2E51F70805630B555BFEB05953BA85D9BE23015E2252DA46CFAA34FF304EB60AABF333B9E0D4CA110BCA941FC1AAA5EA0FA434BC6087ED511BDF6649420E769F6E20714F3385D8674EEA06EE242D26088CA272BF91556D17CFAA070E93FEF4FF9D72438DE5822ED"

    /// Signed pin manifest ("envelope") CDN location. Fetched over plain HTTPS with NO pin
    /// enforcement of its own — pinning this fetch would be circular, since the envelope IS the
    /// pin source; its integrity comes entirely from the ECDSA signature verified against the
    /// anchors above.
    static let manifestURL = URL(string: "https://d3efyv4lemhheo.cloudfront.net/envelope.json")!

    /// A cached envelope older than this triggers a remote refresh at init (matches Android's
    /// 7-day interval).
    static let refreshIntervalSeconds: TimeInterval = 7 * 24 * 60 * 60

    static let manifestFetchTimeoutSeconds: TimeInterval = 10

    // Envelope cache lives in SecureStorage.saveToUserDefaults/getFromUserDefaults — NOT the
    // Keychain-backed pair — so it survives Otpless.shared.clearAll().
    static let manifestEnvelopeKey = "otplessbm_pin_manifest_envelope"
    static let manifestLastFetchAtKey = "otplessbm_pin_last_fetch_at"
}
