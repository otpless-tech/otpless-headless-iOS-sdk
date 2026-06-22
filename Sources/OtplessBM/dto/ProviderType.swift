//
//  ProviderType.swift
//  OtplessBM
//

import Foundation

@objc public enum ProviderType: Int {
    case CLIENT = 0
    case OTPLESS = 1

    internal var nativeName: String {
        switch self {
        case .CLIENT:  return "native_cle_client"
        case .OTPLESS: return "native_cle_otpless"
        }
    }
}
