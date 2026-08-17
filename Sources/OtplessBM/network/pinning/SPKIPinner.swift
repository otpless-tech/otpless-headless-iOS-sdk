//
//  SPKIPinner.swift
//  OtplessBM
//

import Foundation
import Security
import CryptoKit

/// Pure, synchronous SPKI (Subject Public Key Info) pin comparison. Given a validated
/// certificate chain and a hostname, checks whether any certificate's public key hashes to one
/// of the configured pins for that host. No networking, no delegate machinery — kept standalone
/// so it can be unit tested in isolation against real certificate fixtures.
internal enum SPKIPinner {

    // Fixed ASN.1 SubjectPublicKeyInfo headers that `SecKeyCopyExternalRepresentation` strips
    // out (it returns raw key material, not full DER). Prepending the right header per
    // key-type/size reconstructs the DER blob whose SHA-256 hash is the standard
    // `sha256/<base64>` pin format (same technique TrustKit and Apple's own pinning sample code
    // use — there is no public API that returns full SPKI DER directly).
    private static let rsa2048Header: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
        0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
        0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
    ]
    private static let rsa4096Header: [UInt8] = [
        0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09,
        0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
        0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00
    ]
    private static let ecP256Header: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
        0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
        0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00
    ]
    private static let ecP384Header: [UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86,
        0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b,
        0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00
    ]

    /// True if any certificate in `trust`'s chain matches any pin configured for `host`. Hosts
    /// with no configured pins return `true` (nothing to enforce) — callers should only invoke
    /// this for hosts they know are meant to be pinned. Fails closed: if the chain can't be
    /// read at all, `presentedHashes` is empty and this returns `false`.
    static func evaluate(trust: SecTrust, host: String, pins: [String: [String]]) -> Bool {
        guard let expectedPins = pins[host], !expectedPins.isEmpty else {
            return true
        }
        let presentedHashes = Set(spkiHashes(in: trust))
        return !presentedHashes.isDisjoint(with: Set(expectedPins))
    }

    /// Returns the `sha256/<base64>` pin string for every certificate in the chain.
    static func spkiHashes(in trust: SecTrust) -> [String] {
        var hashes: [String] = []
        let count = SecTrustGetCertificateCount(trust)
        for index in 0..<count {
            // SecTrustGetCertificateAtIndex is deprecated in favor of SecTrustCopyCertificateChain
            // (iOS 15+), but this SDK supports iOS 13+ and the deprecation is cosmetic — this API
            // still works correctly on every supported OS version.
            guard let certificate = SecTrustGetCertificateAtIndex(trust, index),
                  let key = SecCertificateCopyKey(certificate),
                  let spkiDER = spkiDER(for: key) else {
                continue
            }
            let digest = SHA256.hash(data: spkiDER)
            hashes.append("sha256/" + Data(digest).base64EncodedString())
        }
        return hashes
    }

    private static func spkiDER(for key: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let rawKeyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            return nil
        }
        guard let header = asn1Header(for: key) else {
            return nil
        }
        return Data(header) + rawKeyData
    }

    private static func asn1Header(for key: SecKey) -> [UInt8]? {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String,
              let keySizeInBits = attributes[kSecAttrKeySizeInBits as String] as? Int else {
            return nil
        }

        let rsaType = kSecAttrKeyTypeRSA as String
        let ecType = kSecAttrKeyTypeECSECPrimeRandom as String

        switch (keyType, keySizeInBits) {
        case (rsaType, 2048):
            return rsa2048Header
        case (rsaType, 4096):
            return rsa4096Header
        case (ecType, 256):
            return ecP256Header
        case (ecType, 384):
            return ecP384Header
        default:
            return nil
        }
    }
}
