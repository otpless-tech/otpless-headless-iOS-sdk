//
//  OtplessExtensions.swift
//  OtplessSDK
//
//  Created by Sparsh on 16/02/25.
//

import UIKit

extension Otpless {
    func invokeResponse(_ otplessResponse: OtplessResponse) {
        dismissOneTapBottomSheet()
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
            // check if session init is done and session info in response["data"]
            if OtplessSessionManager.shared.isInit {
                Task {
                    if let sessionInfo = otplessResponse.response?["sessionInfo"] as? [String: Any],
                       let sessionToken = sessionInfo["sessionToken"] as? String,
                       let refreshToken = sessionInfo["refreshToken"] as? String,
                       let jwtToken = sessionInfo["sessionTokenJWT"] as? String {
                        let sessionInfo = OtplessSessionInfo(sessionToken: sessionToken, refreshToken: refreshToken, jwtToken: jwtToken)
                        let state = Otpless.shared.state!
                        await OtplessSessionManager.shared.saveSessionAndState(sessionInfo, state: state)
                        await OtplessSessionManager.shared.startAuthenticationLoopIfNotStarted()
                    }
                    
                }
            }
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
