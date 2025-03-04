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
    @MainActor func showOneTapViewIfIdentityExists(
        request: OtplessRequest
    ) async -> OneTapIdentity? {
        guard let merchantVC = merchantVC, let config = merchantConfig else {
            return nil
        }

        if request.isPhoneAuth() {
            guard let userDetails = config.userDetails, let mobileIdentities = userDetails.mobile, !mobileIdentities.isEmpty else {
                return nil
            }

            if request.isPhoneNumberWithCountryCodeValid() {
                let identity = (request.getCountryCode()?.replacingOccurrences(of: "+", with: "") ?? "") + (request.getPhone() ?? "")
                return performOneTapIfInputOneTapExists(
                    identity: identity,
                    mobileOneTapIdentities: mobileIdentities,
                    emailOneTapIdentities: nil
                )
            }

            var oneTapIdentities = getChannelMatchingIdentities(
                channelConfig: config.channelConfig,
                userDetails: userDetails,
                isMobile: true,
                name: request.getSelectedChannelType()?.rawValue
            )

            if oneTapIdentities.isEmpty {
                return nil
            }

            oneTapIdentities.append(OneTapIdentity(name: "", identity: "Use another account", uiId: "", logo: nil))
            return await showOneTapView(in: merchantVC, identities: oneTapIdentities)
            
        } else {
            guard let userDetails = config.userDetails, let emailIdentities = userDetails.email, !emailIdentities.isEmpty else {
                return nil
            }

            if request.isEmailValid() {
                return performOneTapIfInputOneTapExists(
                    identity: request.getEmail() ?? "",
                    mobileOneTapIdentities: nil,
                    emailOneTapIdentities: emailIdentities
                )
            }

            var oneTapIdentities = getChannelMatchingIdentities(
                channelConfig: config.channelConfig,
                userDetails: userDetails,
                isMobile: false,
                name: request.getSelectedChannelType()?.rawValue
            )

            if oneTapIdentities.isEmpty {
                return nil
            }

            oneTapIdentities.append(OneTapIdentity(name: "", identity: "Use another account", uiId: "", logo: nil))
            return await showOneTapView(in: merchantVC, identities: oneTapIdentities)
        }
    }
    
    private func getChannelMatchingIdentities(
            channelConfig: [ChannelConfig]?,
            userDetails: UserDetails?,
            isMobile: Bool,
            name: String?
        ) -> [OneTapIdentity] {
            var identitiesList = [OneTapIdentity]()

            guard let configs = channelConfig else { return identitiesList }

            for config in configs {
                if isMobile {
                    if let mobileIdentities = userDetails?.mobile {
                        for mobile in mobileIdentities {
                            for channel in config.channel ?? [] {
                                if let channelName = channel.name,
                                   let selectedName = name,
                                   channelName.trimSSOAndSDKFromStringIfExists() != selectedName.trimSSOAndSDKFromStringIfExists() {
                                    continue
                                }

                                if mobile.logo == channel.logo {
                                    identitiesList.append(
                                        OneTapIdentity(
                                            name: mobile.name,
                                            identity: mobile.value,
                                            uiId: mobile.uiId,
                                            logo: mobile.logo
                                        )
                                    )
                                }
                            }
                        }
                    }
                } else {
                    if let emailIdentities = userDetails?.email {
                        for email in emailIdentities {
                            for channel in config.channel ?? [] {
                                if let channelName = channel.name,
                                   let selectedName = name,
                                   channelName.trimSSOAndSDKFromStringIfExists() != selectedName.trimSSOAndSDKFromStringIfExists() {
                                    continue
                                }

                                if email.logo == channel.logo {
                                    identitiesList.append(
                                        OneTapIdentity(
                                            name: email.name,
                                            identity: email.value,
                                            uiId: email.uiId,
                                            logo: email.logo
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }

            return identitiesList
        }

    private func performOneTapIfInputOneTapExists(
        identity: String,
        mobileOneTapIdentities: [Mobile]?,
        emailOneTapIdentities: [Email]?
    ) -> OneTapIdentity? {
        if let mobileIdentities = mobileOneTapIdentities {
            if let mobile = mobileIdentities.first(where: { $0.value == identity }) {
                return mobile.toOneTapIdentity()
            }
        }

        if let emailIdentities = emailOneTapIdentities {
            if let email = emailIdentities.first(where: { $0.value == identity }) {
                return email.toOneTapIdentity()
            }
        }

        return nil
    }

    @MainActor private func showOneTapView(
        in viewController: UIViewController,
        identities: [OneTapIdentity]
    ) async -> OneTapIdentity? {
        return await withCheckedContinuation { continuation in
            guard let window = viewController.view.window else {
                continuation.resume(returning: nil)
                return
            }
            
            let title = "Sign in to " + (merchantConfig?.uiConfig?.general?.brandName ?? "Otpless")
            
            weak var oneTapView: OneTapView?
            
            let onItemInteract = { (result: OneTapIdentity?) in
                oneTapView?.removeFromSuperview()
                continuation.resume(returning: result)
            }
            
            let view = OneTapView(
                title: title,
                items: identities
            ) { selectedIdentity in
                onItemInteract(selectedIdentity)
            } onDismiss: {
                onItemInteract(nil)
            }
            
            oneTapView = view
            view.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(view)
            
            let safeAreaBottom = window.safeAreaInsets.bottom
            
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: window.centerXAnchor),
                view.bottomAnchor.constraint(equalTo: window.bottomAnchor, constant: -safeAreaBottom),
                view.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                view.heightAnchor.constraint(equalTo: window.heightAnchor, multiplier: 0.35)
            ])
        }
    }
}

extension Otpless {
    func invokeResponse(_ otplessResponse: OtplessResponse) {
        if otplessResponse.responseType == .ONETAP {
            Otpless.shared.resetStates()
            transactionStatusUseCase.stopPolling(dueToSuccessfulVerification: true)
        }
        
        if (otplessResponse.statusCode >= 9100 && otplessResponse.statusCode <= 9105) {
            sendEvent(event: .HEADLESS_TIMEOUT, extras: merchantOtplessRequest?.getEventDict() ?? [:])
        } else {
            Utils.convertToEventParamsJson(
                otplessResponse: otplessResponse,
                callback: { extras, requestId, musId in
                    sendEvent(event: .HEADLESS_RESPONSE_SDK, extras: extras, musId: musId ?? "", requestId: requestId ?? "")
                }
            )
        }
        
        DispatchQueue.main.async {
            self.responseDelegate?.onResponse(otplessResponse)
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
