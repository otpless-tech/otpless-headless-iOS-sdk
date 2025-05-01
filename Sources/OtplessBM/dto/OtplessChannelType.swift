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

@objc public class OtplessChannelTypeObjC: NSObject {
    @objc public static let WHATSAPP = "WHATSAPP"
    @objc public static let GOOGLE_SDK = "GOOGLE_SDK"
    @objc public static let FACEBOOK_SDK = "FACEBOOK_SDK"
    @objc public static let APPLE_SDK = "APPLE_SDK"
    @objc public static let APPLE = "APPLE_EMAIL"
    @objc public static let GMAIL = "GMAIL"
    @objc public static let TWITTER = "TWITTER"
    @objc public static let DISCORD = "DISCORD"
    @objc public static let SLACK = "SLACK"
    @objc public static let FACEBOOK = "FACEBOOK"
    @objc public static let LINKEDIN = "LINKEDIN"
    @objc public static let MICROSOFT = "MICROSOFT"
    @objc public static let LINE = "LINE"
    @objc public static let LINEAR = "LINEAR"
    @objc public static let NOTION = "NOTION"
    @objc public static let TWITCH = "TWITCH"
    @objc public static let GITHUB = "GITHUB"
    @objc public static let BITBUCKET = "BITBUCKET"
    @objc public static let ATLASSIAN = "ATLASSIAN"
    @objc public static let GITLAB = "GITLAB"
    @objc public static let TRUE_CALLER = "TRUE_CALLER"
    
    @objc public static func defaultValue() -> String {
        return WHATSAPP
    }

    @objc public static func validate(value: String) -> String {
        let validValues = [
            WHATSAPP, GOOGLE_SDK, FACEBOOK_SDK, APPLE_SDK, APPLE, GMAIL, TWITTER,
            DISCORD, SLACK, FACEBOOK, LINKEDIN, MICROSOFT, LINE, LINEAR, NOTION,
            TWITCH, GITHUB, BITBUCKET, ATLASSIAN, GITLAB, TRUE_CALLER
        ]
        return validValues.first { $0.caseInsensitiveCompare(value) == .orderedSame } ?? defaultValue()
    }
}
