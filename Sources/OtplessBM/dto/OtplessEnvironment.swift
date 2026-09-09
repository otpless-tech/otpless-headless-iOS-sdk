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
            // Moved from user-auth.otpless.app for SSL pinning (Android parity — this is the
            // host the signed pin manifest covers). The old host stays aliased server-side.
            return "https://sigma.otpless.app"
        #if DEBUG
        case .STAGING:
            return "https://user-auth.otpless.tech"
        #endif
        }
    }
}
