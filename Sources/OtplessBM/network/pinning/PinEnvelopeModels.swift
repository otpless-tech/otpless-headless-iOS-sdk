//
//  PinEnvelopeModels.swift
//  OtplessBM
//

import Foundation

/// Outcome of a single manifest-fetch attempt. Split so the caller can emit distinct telemetry
/// per failure mode: `httpError` carries the response code (4xx misconfig vs 5xx server issue);
/// `networkError` covers unreachable, DNS, and timeout paths uniformly. Only `success` carries
/// the raw envelope JSON for downstream verification.
internal enum SslEnvelopeResult {
    case success(envelope: String)
    case httpError(code: Int)
    case networkError
}

/// Trusted view of a manifest payload AFTER its signature has been verified against
/// `OtplessKeyVault.verifyAnchors`. Do not construct one from raw envelope input — always route
/// through `OtplessSslPinManager.verify`, so an instance existing means "these bytes came from a
/// legitimate signer".
internal struct VerifiedManifest {
    let ver: Int
    let iat: TimeInterval
    let exp: TimeInterval
    let kid: String?
    let pins: [String: [String]]

    var isExpired: Bool {
        return exp < Date().timeIntervalSince1970
    }
}

/// Result of `OtplessSslPinManager.handlePinFailure()`: `retryWithNewPins` means the one-shot
/// envelope refresh succeeded and the caller should re-run its pin check against the same server
/// trust; `failClosed` means the caller must cancel the connection.
internal enum PinFailureAction {
    case retryWithNewPins
    case failClosed
}
