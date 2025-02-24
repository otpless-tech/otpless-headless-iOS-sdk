//
//  File.swift
//  otpless-iOS-headless-sdk
//
//  Created by Sparsh on 16/01/25.
//

import Foundation

public enum OtplessChannelType: String, CaseIterable {
    case WHATSAPP = "WHATSAPP"
    case GOOGLE_SDK = "GOOGLE_SDK"
    case FACEBOOK_SDK = "FACEBOOK_SDK"
    case APPLE_SDK = "APPLE_SDK"
    case APPLE = "APPLE_EMAIL"
    case GMAIL = "GMAIL"
    case TWITTER = "TWITTER"
    case DISCORD = "DISCORD"
    case SLACK = "SLACK"
    case FACEBOOK = "FACEBOOK"
    case LINKEDIN = "LINKEDIN"
    case MICROSOFT = "MICROSOFT"
    case LINE = "LINE"
    case LINEAR = "LINEAR"
    case NOTION = "NOTION"
    case TWITCH = "TWITCH"
    case GITHUB = "GITHUB"
    case BITBUCKET = "BITBUCKET"
    case ATLASSIAN = "ATLASSIAN"
    case GITLAB = "GITLAB"
    case TRUE_CALLER = "TRUE_CALLER"
    
    public static func fromString(_ value: String) -> OtplessChannelType {
        return OtplessChannelType.allCases.first { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame } ?? .WHATSAPP
    }
}
