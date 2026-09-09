//
//  PinConstants.swift
//  OtplessBM
//
//  GENERATED FILE — DO NOT EDIT BY HAND.
//  Regenerate with: python3 scripts/src/create-pin-constants.py
//

import Foundation

/// Obfuscated trust roots for the SSL pin envelope flow. At startup `OtplessKeyVault`
/// decodes each ciphertext below by XORing its bytes against `saltHex` cycling
/// `i mod 16`, then hands the plaintext to `OtplessSslPinManager`:
/// `verifyAnchorsHex` authenticates every remotely fetched pin envelope, and
/// `baselinePinsHex` is the always-on pin set that envelopes may refine but never remove.
///
/// Decoded layouts:
///   - `verifyAnchorsHex` → newline-separated base64 DER `SubjectPublicKeyInfo` strings,
///     one ECDSA P-256 anchor per line. Two anchors ship so signers can rotate without
///     a new SDK release.
///   - `baselinePinsHex`  → a single `host\tsha256/pin\tsha256/pin\n` line — the host
///     is pinned on system trust plus these SPKI hashes even before any envelope loads.
///
/// XOR against a fixed salt is obfuscation, not encryption; it only defeats naive
/// `strings`-style scraping of the binary. Real integrity comes from Apple code-signing
/// (authenticity of the anchors in the shipped binary) plus ECDSA verification of every
/// envelope against those anchors before its pins are trusted.
///
/// This file is produced by a full-file emitter that mirrors Android's `emitKotlin` in
/// `OtplessSslKeyVaultTask.kt` — both SDKs read the same AWS material through the same
/// XOR-obfuscation, so blobs are byte-for-byte swappable between platforms.
internal enum PinConstants {

    static let saltHex = "9F3AC18D7E42B5601FE7248BD936A471"

    static let verifyAnchorsHex = "D27CAAFA3B35EC2854887EC2A35C9432DE6B98C4352DEF29658D14CF9867C735CE5D80C83A35D03258844CFBB704C649C958A4BC3808DF572F8D65E1A302EE32EB0BEAC8133AE3514EA066C3B1469202D20EA0BE273384562CBE65DBAD459418EA7BA5E34731C43477B312E3BA19ED3CD64FA8F52634FE524A8019B6D37BE21AE87FB6D43609DA3A569D4EBB9A77F528D671AED73738DF505BA675E89D67C330DA7588F54C1AF60866C86DFAE140F11FF50F8CBF172D80186AC86DB9B85EF639DE088FC12A11FB167AB145E6AD50E133CB7DA6EE110DFE045C846ACAB3058B1EF06BBBE82E2DEC2D59A40FA4EF07FC3BDD6C88E31F18D25D22ED"

    static let baselinePinsHex = "EC53A6E01F6CDA146F8B41F8AA18C501EF33B2E51F70805630B555BFEB05953BA85D9BE23015E2252DA46CFAA34FF304EB60AABF333B9E0D4CA110BCA941FC1AAA5EA0FA434BC6087ED511BDF6649420E769F6E20714F3385D8674EEA06EE242D26088CA272BF91556D17CFAA070E93FEF4FF9D72438DE5822ED"
}
