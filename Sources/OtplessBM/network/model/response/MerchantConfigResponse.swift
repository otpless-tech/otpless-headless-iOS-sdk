//
//  MerchantConfigResponse.swift
//  otpless-iOS-headless-sdk
//
//  Created by Sparsh on 16/01/25.
//

import Foundation

struct MerchantConfigResponse: Codable {
    let authType: String?
    let channelConfig: [ChannelConfig]?
    let isMFAEnabled: Bool?
    let merchant: Merchant?
    let uiConfig: UiConfig?
    let userDetails: UserDetails?
}

struct UiConfig: Codable {
    let colors: Colors?
    let general: General?
    let sx: Sx?
}

struct Text: Codable {
    let body: String?
    let heading: String?
}

struct Colors: Codable {
    let cta: Cta?
    let input: Input?
    let social: Social?
    let text: Text?
    let theme: String?
    let widget: Widget?
}

struct Sx: Codable {
    let body: Body?
    let heading: Heading?
    let primaryButton: PrimaryButton?
    let primaryInput: PrimaryInput?
    let sso: Sso?
}

struct UserDetails: Codable {
    let email: [Email]?
    let mobile: [Mobile]?
    
    func toOneTapIdentities() -> [OneTapIdentity] {
        var list: [OneTapIdentity] = []
        email?.forEach { list.append($0.toOneTapIdentity()) }
        mobile?.forEach { list.append($0.toOneTapIdentity()) }
        return list
    }
    
    func toMobileOneTapIdentities() -> [OneTapIdentity] {
        return mobile?.map { $0.toOneTapIdentity() } ?? []
    }
    
    func toEmailOneTapIdentities() -> [OneTapIdentity] {
        return email?.map { $0.toOneTapIdentity() } ?? []
    }
}

struct Widget: Codable {
    let background: String?
    let border: String?
}

struct Body: Codable {
    let color: String?
}

struct Sso: Codable {
    let background: String?
    let borderColor: String?
    let borderRadius: Int?
    let color: String?
}

struct Social: Codable {
    let background: String?
    let border: String?
    let text: String?
}

struct PrimaryInput: Codable {
    let background: String?
    let borderColor: String?
}

struct PrimaryButton: Codable {
    let background: String?
    let borderColor: String?
    let borderRadius: Int?
    let color: String?
}

struct Merchant: Codable {
    let config: Config?
    let loginURI: String?
    let otplessId: String?
}

struct Links: Codable {
    let privacyPolicy: String?
    let tnc: String?
}

struct Input: Codable {
    let background: String?
    let border: String?
    let text: String?
}

struct Heading: Codable {
    let color: String?
}

struct General: Codable {
    let brandLogo: String?
    let brandName: String?
    let language: String?
    let links: Links?
}

struct Email: Codable {
    let logo: String?
    let uiId: String
    let value: String
    let name: String?
    
    func toOneTapIdentity() -> OneTapIdentity {
        return OneTapIdentity(name: name, identity: value, uiId: uiId, logo: logo)
    }
}

struct Mobile: Codable {
    let logo: String?
    let uiId: String
    let value: String
    let name: String?
    
    func toOneTapIdentity() -> OneTapIdentity {
        return OneTapIdentity(name: name, identity: value, uiId: uiId, logo: logo)
    }
}

struct Cta: Codable {
    let background: String?
    let border: String?
    let text: String?
}

struct Config: Codable {
    let isPopUpDisabled: Bool?
    let isSecureSdkEnabled: Bool?
    let isSilentAuthEnabled: Bool?
    let isWebauthnEnabled: Bool?
    let isWebauthnRegistered: Bool?
    let lang: String?
}

struct ChannelConfig: Codable {
    let channel: [Channel]?
    let identifierType: String?
    let mandatory: Bool?
    let verified: Bool?
}

struct Channel: Codable {
    let communicationMode: String?
    let logo: String?
    let name: String?
    let otpLength: Int?
    let type: String?
}

public struct OneTapIdentity: Sendable {
    public let name: String?
    public let identity: String
    public let uiId: String
    public let logo: String?
}
