//
//  OtplessSslKind.swift
//  OtplessBM
//

import Foundation

/// Merchant-facing SSL pinning mode, passed to `Otpless.initialise` — mirror of the Android
/// SDK's `OtplessSslKind`.
///
/// - `sslEnabled`: SPKI pinning on the Otpless user-auth host, with the trusted pin set
///   refreshed from a signature-verified remote manifest. On persistent pin failure the SDK
///   fails closed with error code 5004 and never sends the request.
/// - `sslDisabled`: no pin comparison; standard system TLS validation only. This is the default
///   for the Objective-C `initialise` overload, preserving pre-2.4 behavior.
/// - `customSsl(pins:)`: merchants who route through their own gateway supply their own pins —
///   a map of host to `sha256/<base64 SPKI hash>` strings (the same format OkHttp's
///   `CertificatePinner` uses). Applied as-is, with no remote refresh.
public enum OtplessSslKind: Sendable {
    case sslDisabled
    case sslEnabled
    case customSsl(pins: [String: [String]])
}
