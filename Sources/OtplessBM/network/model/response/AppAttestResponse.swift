//
//  AppAttestResponse.swift
//  OtplessBM
//

import Foundation

/// Response of `POST /v3/lp/user/device/attestation/{state}`.
struct AppAttestResponse: Decodable {
    let keyId: String?
    /// `SUCCESS` or `FAILED`.
    let status: String?
}
