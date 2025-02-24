//
//  FBSdkUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 18/02/25.
//

import Foundation
import os
import UIKit

#if !canImport(FBSDKLoginKit) && !canImport(FacebookCore)
class FBSdkUseCase: NSObject, FacebookAuthProtocol {
    func register(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]?) {}
    
    func register(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any]) {}
    
    @available(iOS 13.0, *)
    func register(openURLContexts URLContexts: Set<UIOpenURLContext>) {}
    
    func startFBSignIn(withNonce nonce: String, withPermissions permissions: [String]) async -> FacebookSignInResponse {
        os_log("OTPLESS: Facebook support not initialized. Please add OtplessSDK/FacebookSupport to your Podfile")
        return FacebookSignInResponse(
            success: false,
            token: nil,
            idToken: nil,
            error: "Facebook support not initialized. Please add OtplessSDK/FacebookSupport to your Podfile"
        )
    }
    
    func logoutFBUser() {}
}
#else

#if canImport(FBSDKCoreKit)
import FBSDKCoreKit
import FBSDKLoginKit
#endif

#if canImport(FacebookCore)
import FacebookCore
#endif

class FBSdkUseCase: NSObject, FacebookAuthProtocol {
    
    func register(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]?) {
        ApplicationDelegate.shared.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    func register(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any]) {
        ApplicationDelegate.shared.application(
            app,
            open: url,
            sourceApplication: options[UIApplication.OpenURLOptionsKey.sourceApplication] as? String,
            annotation: options[UIApplication.OpenURLOptionsKey.annotation]
        )
    }
    
    @available(iOS 13.0, *)
    @MainActor
    func register(openURLContexts URLContexts: Set<UIOpenURLContext>) async {
        guard let url = URLContexts.first?.url else { return }
        ApplicationDelegate.shared.application(
            UIApplication.shared,
            open: url,
            sourceApplication: nil,
            annotation: [UIApplication.OpenURLOptionsKey.annotation]
        )
    }
    
    @MainActor
    func startFBSignIn(withNonce nonce: String, withPermissions permissions: [String]) async -> FacebookSignInResponse {
        let loginManager = LoginManager()
        let configuration = LoginConfiguration(permissions: permissions, tracking: .enabled, nonce: nonce)
        
        guard let config = configuration else {
            return FacebookSignInResponse(
                success: false,
                token: nil,
                idToken: nil,
                error: "Could not get LocalConfiguration instance"
            )
        }
        
        return await withCheckedContinuation { continuation in
            loginManager.logIn(configuration: config) { result in
                switch result {
                case .cancelled:
                    continuation.resume(returning: FacebookSignInResponse(
                        success: false,
                        token: nil,
                        idToken: nil,
                        error: "User cancelled the Facebook login"
                    ))
                    
                case .failed(let error):
                    continuation.resume(returning: FacebookSignInResponse(
                        success: false,
                        token: nil,
                        idToken: nil,
                        error: error.localizedDescription
                    ))
                    
                case .success(_, _, let token):
                    let accessToken = token?.tokenString
                    let authToken = AuthenticationToken.current?.tokenString
                    
                    if (accessToken?.isEmpty ?? true) && (authToken?.isEmpty ?? true) {
                        continuation.resume(returning: FacebookSignInResponse(
                            success: false,
                            token: nil,
                            idToken: nil,
                            error: "Authentication Failed"
                        ))
                    } else {
                        continuation.resume(returning: FacebookSignInResponse(
                            success: true,
                            token: accessToken,
                            idToken: authToken,
                            error: nil
                        ))
                    }
                }
            }
        }
    }
    
    func logoutFBUser() {
        LoginManager().logOut()
    }
}
#endif

struct FacebookSignInResponse: Sendable {
    let channel: String = OtplessChannelType.FACEBOOK_SDK.rawValue
    let success: Bool
    let token: String?
    let idToken: String?
    let error: String?
    
    func toDict() -> [String: Any] {
        var response: [String: Any] = [
            "channel": channel,
            "success": success
        ]
        
        if let token = token {
            response["token"] = token
        }
        if let idToken = idToken {
            response["idToken"] = idToken
        }
        if let error = error {
            response["error"] = error
        }
        
        return response
    }
}

// Update protocol to use the new response type
protocol FacebookAuthProtocol {
    func startFBSignIn(withNonce nonce: String, withPermissions permissions: [String]) async -> FacebookSignInResponse
    
    func logoutFBUser()
    
    func register(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any])
    
    @available(iOS 13.0, *)
    func register(openURLContexts URLContexts: Set<UIOpenURLContext>) async
    
    func register(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?)
}
