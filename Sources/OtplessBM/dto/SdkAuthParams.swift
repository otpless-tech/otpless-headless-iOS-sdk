//
//  SdkAuthParams.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//


import Foundation

internal struct SdkAuthParams {
    let nonce: String
    let clientId: String
    let channelType: OtplessChannelType
    let permissions: [String]
    let authorizedAccounts: Bool
    let autoSelectable: Bool
    let verifiedPhone: Bool

    init(
        nonce: String,
        clientId: String,
        channelType: OtplessChannelType,
        permissions: [String],
        authorizedAccounts: Bool = false,
        autoSelectable: Bool = true,
        verifiedPhone: Bool = true
    ) {
        self.nonce = nonce
        self.clientId = clientId
        self.channelType = channelType
        self.permissions = permissions
        self.authorizedAccounts = authorizedAccounts
        self.autoSelectable = autoSelectable
        self.verifiedPhone = verifiedPhone
    }
    
    func toJson() -> [String: Any] {
        return [
            "nonce": nonce,
            "clientId": clientId,
            "channelType": channelType.rawValue,
            "permissions": permissions,
            "authorizedAccounts": authorizedAccounts,
            "autoSelectable": autoSelectable,
            "verifiedPhone": verifiedPhone
        ]
    }
}
