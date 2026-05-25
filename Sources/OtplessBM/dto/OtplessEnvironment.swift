//
//  OtplessEnvironment.swift
//  OtplessBM
//

import Foundation

@objc public enum OtplessEnvironment: Int {
    case PRODUCTION = 0
    #if DEBUG
    case STAGING = 1
    #endif

    internal var userAuthBaseURL: String {
        switch self {
        case .PRODUCTION:
            return "https://user-auth.otpless.app"
        #if DEBUG
        case .STAGING:
            return "https://user-auth.otpless.tech"
        #endif
        }
    }
}
