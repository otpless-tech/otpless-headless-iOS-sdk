//
//  OtplessEnvironment.swift
//  OtplessBM
//

import Foundation

@objc public enum OtplessEnvironment: Int {
    case PRODUCTION
    case STAGING
    
    /// Returns the user-auth base URL for the environment
    internal var userAuthBaseURL: String {
        switch self {
        case .PRODUCTION:
            return "https://user-auth.otpless.app"
        case .STAGING:
            return "https://user-auth-pp.otpless.app"
        }
    }
}