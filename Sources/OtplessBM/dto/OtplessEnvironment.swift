//
//  OtplessEnvironment.swift
//  OtplessBM
//

import Foundation

@objc public enum OtplessEnvironment: Int {
    case PRODUCTION = 0

    internal var userAuthBaseURL: String {
        switch self {
        case .PRODUCTION:
            return "https://user-auth.otpless.app"
        }
    }
}
