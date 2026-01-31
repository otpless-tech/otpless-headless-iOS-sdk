//
//  PostIntentRequestBody.swift
//  otpless-iOS-headless-sdk
//
//  Created by Sparsh on 16/01/25.
//


import Foundation

struct PostIntentRequestBody: DictionaryConvertible {
    let channel: String
    let email: String?
    let hasWhatsapp: String
    let identifierType: String
    let metadata: String
    let mobile: String?
    let selectedCountryCode: String?
    let silentAuthEnabled: Bool
    var triggerWebauthn: Bool
    let type: String
    let uid: String?
    let value: String?
    let expiry: String?
    let deliveryMethod: String?
    let otpLength: String?
    let uiIds: [String]?
    let fireIntent: Bool?
    let requestId: String?
    let clientMetaData: String? // Must a dictionary converted to String
    let asId: String?
    let isViSnaWhitelisted = true
    let isAirtelSnaWhitelisted = true
    
    init(
        channel: String,
        email: String?,
        hasWhatsapp: String,
        identifierType: String,
        mobile: String?,
        selectedCountryCode: String?,
        silentAuthEnabled: Bool,
        triggerWebauthn: Bool,
        type: String,
        uid: String?,
        value: String?,
        expiry: String?,
        deliveryMethod: String?,
        otpLength: String?,
        uiIds: [String]?,
        fireIntent: Bool?,
        requestId: String?,
        clientMetaData: String?,
        asId: String?
    ) {
        self.channel = channel
        self.email = email
        self.hasWhatsapp = hasWhatsapp
        self.identifierType = identifierType
        self.metadata = """
        {
            "appInfo": "\(Otpless.shared.appInfo)",
            "deviceInfo": "\(Otpless.shared.deviceInfo)"
        }
        """
        self.mobile = mobile
        self.selectedCountryCode = selectedCountryCode
        self.silentAuthEnabled = silentAuthEnabled
        self.triggerWebauthn = triggerWebauthn
        self.type = type
        self.uid = uid
        self.value = value
        self.expiry = expiry
        self.deliveryMethod = deliveryMethod
        self.otpLength = otpLength
        self.uiIds = uiIds
        self.fireIntent = fireIntent
        self.requestId = requestId
        self.clientMetaData = clientMetaData
        self.asId = asId
    }
    
    internal mutating func setWebAuthnFallback(is fallback: Bool) {
        if fallback {
            triggerWebauthn = false
        } else {
            triggerWebauthn = true
        }
    }
}
