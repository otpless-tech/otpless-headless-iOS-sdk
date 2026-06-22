//
//  AuthEvent.swift
//  OtplessBM
//

import Foundation

@objc public enum AuthEvent: Int {
    case AUTH_INITIATED = 0
    case AUTH_SUCCESS = 1
    case AUTH_FAILED = 2

    internal var nativeName: String {
        switch self {
        case .AUTH_INITIATED: return "native_cle_auth_initiated"
        case .AUTH_SUCCESS:   return "native_cle_auth_success"
        case .AUTH_FAILED:    return "native_cle_auth_failed"
        }
    }
}
