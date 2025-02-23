//
//  StringExt.swift
//  OtplessSDK
//
//  Created by Sparsh on 16/02/25.
//


extension String {
    func trimSSOAndSDKFromStringIfExists() -> String {
        return self
            .replacingOccurrences(of: "_SDK", with: "")
            .replacingOccurrences(of: "_SSO", with: "")
    }
}