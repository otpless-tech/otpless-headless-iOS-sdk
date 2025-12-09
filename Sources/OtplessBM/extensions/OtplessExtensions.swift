//
//  OtplessExtensions.swift
//  OtplessSDK
//
//  Created by Sparsh on 16/02/25.
//

import UIKit

extension Otpless {
    func startPasskeyAuthorization(passkeyRequestDict: [String: Any]) async {
        if #available(iOS 16.6, *) {
            let data = Utils.convertStringToDictionary(
                (passkeyRequestDict["data"] as? String) ?? ""
            )
            if (passkeyRequestDict["isRegistration"] as? Bool) == true {
                await passkeyUseCase.initiateRegistration(withRequest: data ?? [:], onResponse: { [weak self] result in
                    guard let self = self else {
                        return
                    }
                    let webauthnData = self.passkeyUseCase.handleResult(forAuthorizationResult: result)
                    let response = await self.verifyCodeUseCase.invoke(state: self.state ?? "", queryParams: self.getVerifyCodeQueryParams(code: "", webAuthnData: webauthnData, requestId: merchantOtplessRequest?.getRequestId() ?? ""), getTransactionStatusUseCase: self.transactionStatusUseCase)
                    
                    if let otplessResponse = response.0 {
                        self.invokeResponse(otplessResponse)
                    }
                    if let uid = response.1 {
                        SecureStorage.shared.save(key: Constants.UID_KEY, value: uid)
                    }
                })
            } else {
                await passkeyUseCase.initiateSignIn(withRequest: data ?? [:], onResponse: { [weak self] result in
                    guard let self = self else {
                        return
                    }
                    let webauthnData = self.passkeyUseCase.handleResult(forAuthorizationResult: result)
                    let androidString = webauthnData.replacingOccurrences(of: "\n", with: "")
                        .replacingOccurrences(of: " ", with: "")
                    let response = await self.verifyCodeUseCase.invoke(state: self.state ?? "", queryParams: self.getVerifyCodeQueryParams(code: "", webAuthnData: androidString, requestId: merchantOtplessRequest?.getRequestId() ?? ""), getTransactionStatusUseCase: self.transactionStatusUseCase)
                    
                    if let otplessResponse = response.0 {
                        self.invokeResponse(otplessResponse)
                    }
                    if let uid = response.1 {
                        SecureStorage.shared.save(key: Constants.UID_KEY, value: uid)
                    }
                })
            }
            
        } else {
            invokeResponse(
                OtplessResponse.createUnsupportedIOSVersionResponse(forFeature: "Passkey", supportedFrom: "16.0")
            )
        }
    }
}

extension Otpless {
    func invokeResponse(_ otplessResponse: OtplessResponse) {
        if otplessResponse.statusCode == 9110 {
            return
        }
        
        if otplessResponse.responseType == .ONETAP {
            if let data = otplessResponse.response?["data"] as? [String: Any],
               let token = data["token"] as? String {
                updateAuthMap(token: token)
            }
            Otpless.shared.resetStates()
            transactionStatusUseCase.stopPolling(dueToSuccessfulVerification: true)
        }
        
        if (otplessResponse.statusCode >= 9100 && otplessResponse.statusCode <= 9105) {
            sendEvent(event: .HEADLESS_TIMEOUT, extras: merchantOtplessRequest?.getEventDict() ?? [:])
        } else {
            Utils.convertToEventParamsJson(
                otplessResponse: otplessResponse,
                callback: { extras, musId in
                    sendEvent(event: .HEADLESS_RESPONSE_SDK, extras: extras, musId: musId ?? "")
                }
            )
        }
        
        DispatchQueue.main.async {
            self.responseDelegate?.onResponse(otplessResponse)
            self.objcResponseDelegate?(otplessResponse.toJsonString())
        }
    }
}

extension Otpless {
    func getVerifyCodeQueryParams(code: String, webAuthnData: String = "", requestId: String = "") -> [String: String] {
        var queryParams: [String: String] = [:]
        queryParams["hasWhatsapp"] = (appInfo["hasWhatsapp"] as? String)
        if !code.isEmpty {
            queryParams["code"] = code
        }
        if !webAuthnData.isEmpty {
            queryParams["webauthnData"] = webAuthnData
            queryParams["channel"] = "DEVICE"
            queryParams["requestId"] = requestId
        }
        return queryParams
    }
    
    func prepareForSdkAuth(withAuthParams sdkAuthParams: SdkAuthParams) async {
        switch sdkAuthParams.channelType {
        case .GOOGLE_SDK, .GMAIL:
            sendEvent(event: .GOOGLE_SDK_IOS_SDK)
            await manageGIDSignIn(with: sdkAuthParams)
            
        case .FACEBOOK_SDK, .FACEBOOK:
            sendEvent(event: .FACEBOOK_SDK_IOS_SDK)
            await manageFBSignIn(with: sdkAuthParams)

        case .APPLE_SDK, .APPLE:
            sendEvent(event: .APPLE_SDK_IOS_SDK)
            let appleSignInResponse = await appleSignInUseCase.performSignIn(withNonce: sdkAuthParams.nonce)
            await verifySdkAuthResponse(queryParams: appleSignInResponse.toDict())

        default:
            return
        }
    }
    
    private func manageFBSignIn(with sdkAuthParams: SdkAuthParams) async {
        if let FacebookAuthClass = NSClassFromString("OtplessBM.FBSdkUseCase") as? NSObject.Type {
            let fbAuthHandler = FacebookAuthClass.init()
            if let handler = fbAuthHandler as? FacebookAuthProtocol {
                handler.logoutFBUser()
                var permissions = sdkAuthParams.permissions
                if permissions.isEmpty {
                    permissions.append("public_profile")
                    permissions.append("email")
                }
                
                let fbSignInResult = await handler.startFBSignIn(
                    withNonce: sdkAuthParams.nonce,
                    withPermissions: permissions
                )
                
                await verifySdkAuthResponse(queryParams: fbSignInResult.toDict())
            } else {
                let errorDictionary = [
                    "error": "missing_dependency",
                    "errorDescription": "Facebook support not initialized. Please add OtplessBM/FacebookSupport to your Podfile"
                ]
                await verifySdkAuthResponse(queryParams: errorDictionary)
            }
        } else {
            let errorDictionary = [
                "error": "missing_class",
                "errorDescription": "Could not find an instance of FBSdkUseCase"
            ]
            await verifySdkAuthResponse(queryParams: errorDictionary)
        }
    }
    
    private func manageGIDSignIn(with sdkAuthParams: SdkAuthParams) async {
        guard let vc = merchantVC else {
            return
        }
        if let GoogleAuthClass = NSClassFromString("OtplessBM.GIDSignInUseCase") as? NSObject.Type {
            let googleAuthHandler = GoogleAuthClass.init()
            if let handler = googleAuthHandler as? GoogleAuthProtocol {
                let googleSignInResponse = await handler.signIn(
                    vc: vc,
                    withHint: nil,
                    shouldAddAdditionalScopes: nil,
                    withNonce: sdkAuthParams.nonce
                )
                
                await verifySdkAuthResponse(queryParams: googleSignInResponse.toDict())
            } else {
                let errorDictionary: [String: Any] = [
                    "error": "missing_dependency",
                    "error_description": "Google support not initialized. Please add OtplessSDK/GoogleSupport to your Podfile"
                ]
                await verifySdkAuthResponse(queryParams: errorDictionary)
            }
        } else {
            let errorDictionary = [
                "error": "missing_class",
                "errorDescription": "Could not find an instance of OtplessGIDSignIn"
            ]
            await verifySdkAuthResponse(queryParams: errorDictionary)
        }
    }
    
    private func verifySdkAuthResponse(queryParams: [String: Any]) async {
        let mappedQueryParams = [
            "ssoSdkResponse": Utils.convertDictionaryToString(queryParams)
        ]
        let verifyCodeResponse = await verifyCodeUseCase.invoke(state: self.state ?? "", queryParams: mappedQueryParams, getTransactionStatusUseCase: transactionStatusUseCase)
        if let otplessResponse = verifyCodeResponse.0 {
            invokeResponse(otplessResponse)
        }
        
        if let uid = verifyCodeResponse.1 {
            SecureStorage.shared.save(key: Constants.UID_KEY, value: uid)
        }
    }
}

extension Otpless {
    func getOtpLength(
        fromChannelConfig channelConfig: [ChannelConfig]?,
        forAuthenticationMedium authenticationMedium: AuthenticationMedium?
    ) -> Int {
        let toIterate: String
        
        switch authenticationMedium {
        case .PHONE:
            toIterate = "MOBILE"
        case .EMAIL:
            toIterate = "EMAIL"
        default:
            toIterate = "NONE"
        }
        
        if toIterate == "NONE" {
            return -1
        }
        
        for cf in channelConfig ?? [] {
            if cf.identifierType?.uppercased() != toIterate { continue }
            for channel in cf.channel ?? [] {
                if channel.name?.uppercased() != "OTP" && channel.name?.uppercased() != "OTP_LINK" { continue }
                return channel.otpLength ?? -1
            }
        }
        
        return -1
    }
    
    internal func updateAuthMap(token: String){
        if #available(iOS 15.0, *) {
            if let cls = NSClassFromString("OTPlessIntelligence.OTPlessIntelligence") as? NSObject.Type {
                let sharedSelector = NSSelectorFromString("shared")
                
                guard cls.responds(to: sharedSelector),
                      let sharedObj = cls.perform(sharedSelector)?.takeUnretainedValue() as? NSObject
                else {
                    return
                }
                
                var authMap: [String:String] = [:]
                
                if !Otpless.shared.asId.isEmpty {
                    authMap["asId"] = Otpless.shared.asId
                }
                if !token.isEmpty {
                    authMap["token"] = token
                }
                
                let updateSelector = NSSelectorFromString("updateAuthSessionWithIntelligence:")
                
                if sharedObj.responds(to: updateSelector) {
                    _ = sharedObj.perform(updateSelector, with: authMap)
                }
            }
        }
    }
}
