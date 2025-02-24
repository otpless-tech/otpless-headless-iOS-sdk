//
//  File.swift
//  otpless-iOS-headless-sdk
//
//  Created by Sparsh on 16/01/25.
//

import Foundation

internal enum AuthenticationMedium: String {
    case PHONE = "PHONE"
    case EMAIL = "EMAIL"
    case OAUTH = "OAUTH"
    case WEB_AUTHN = "WEB_AUTHN"
}
