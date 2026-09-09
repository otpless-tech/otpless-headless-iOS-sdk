//
//  OtplessKeyVault.swift
//  OtplessBM
//

import Foundation

/// Decodes the XOR-obfuscated anchor / baseline-pin blobs from `PinConstants` and exposes them
/// as plain Swift values — the iOS mirror of the Android SDK's `OtplessKeyVault`.
///
/// Fail-closed: any failure (malformed hex, unparseable plaintext) leaves the property empty and
/// fires exception telemetry. Nothing here ever throws. An empty `baselinePins` in `.sslEnabled`
/// mode means every envelope refresh fails its known-hosts restriction, `isSslDone` stays false,
/// and `start()` short-circuits with the 5004 response — the same outcome as Android's
/// vault-load failure.
internal enum OtplessKeyVault {

    /// Base64 DER `SubjectPublicKeyInfo` strings for the ECDSA P-256 envelope-signing anchors.
    static let verifyAnchors: [String] = safeLoad(id: "verify_anchors", cipherHex: PinConstants.verifyAnchorsHex) { bytes in
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        let anchors = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return anchors.isEmpty ? nil : anchors
    } ?? []

    /// SPKI `sha256/<base64>` pins per host.
    static let baselinePins: [String: [String]] = safeLoad(id: "baseline_pins", cipherHex: PinConstants.baselinePinsHex) { bytes in
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        var pins: [String: [String]] = [:]
        for line in text.split(separator: "\n") where !line.isEmpty {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 2 else { continue }
            pins[parts[0]] = Array(parts.dropFirst())
        }
        return pins.isEmpty ? nil : pins
    } ?? [:]

    private static func safeLoad<T>(id: String, cipherHex: String, parse: (Data) -> T?) -> T? {
        guard let salt = decodeHex(PinConstants.saltHex), !salt.isEmpty,
              let cipher = decodeHex(cipherHex) else {
            reportFailure(id: id, detail: "malformed hex")
            return nil
        }
        var plain = Data(count: cipher.count)
        for (i, byte) in cipher.enumerated() {
            plain[i] = byte ^ salt[i % salt.count]
        }
        guard let value = parse(plain) else {
            reportFailure(id: id, detail: "unparseable plaintext")
            return nil
        }
        return value
    }

    private static func reportFailure(id: String, detail: String) {
        OtplessBMEvents.Exception.captured(where: "key_vault_read_failed", message: "\(id): \(detail)")
        DLog("[Pin] Key vault load failed for \(id): \(detail)")
    }

    private static func decodeHex(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
