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
    
    func startFBSignIn(withNonce nonce: String, withPermissions permissions: [String]) async -> [String: Any] {
        os_log("OTPLESS: Facebook support not initialized. Please add OtplessSDK/FacebookSupport to your Podfile")
        return [
            "success": false,
            "error": "Facebook support not initialized. Please add OtplessSDK/FacebookSupport to your Podfile"
        ]
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
    func register(openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        ApplicationDelegate.shared.application(
            UIApplication.shared,
            open: url,
            sourceApplication: nil,
            annotation: [UIApplication.OpenURLOptionsKey.annotation]
        )
    }
    
    func startFBSignIn(withNonce nonce: String, withPermissions permissions: [String]) async -> [String: Any] {
        let loginManager = LoginManager()
        let configuration = LoginConfiguration(permissions: permissions, tracking: .enabled, nonce: nonce)
        
        guard let config = configuration else {
            return ["success": false, "error": "Could not get LocalConfiguration instance"]
        }
        
        return await withCheckedContinuation { continuation in
            loginManager.logIn(configuration: config) { result in
                var response: [String: Any] = ["channel": OtplessChannelType.FACEBOOK_SDK.rawValue]
                
                switch result {
                case .cancelled:
                    response["success"] = false
                    response["error"] = "User cancelled the Facebook login"
                case .failed(let error):
                    response["success"] = false
                    response["error"] = error.localizedDescription
                case .success(_, _, let token):
                    response["success"] = true
                    if let accessTokenStr = token?.tokenString {
                        response["token"] = accessTokenStr
                    }
                    if let authenticationTokenStr = AuthenticationToken.current?.tokenString {
                        response["idToken"] = authenticationTokenStr
                    }
                    if token?.tokenString.isEmpty == true && AuthenticationToken.current?.tokenString.isEmpty == true {
                        response["success"] = false
                        response["error"] = "Authentication Failed"
                    }
                }
                continuation.resume(returning: response)
            }
        }
    }
    
    func logoutFBUser() {
        LoginManager().logOut()
    }
}
#endif

protocol FacebookAuthProtocol {
    func startFBSignIn(withNonce nonce: String, withPermissions permissions: [String]) async -> [String: Any]
    
    func logoutFBUser()
    
    @MainActor
    func register(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any])
    
    @MainActor
    @available(iOS 13.0, *)
    func register(openURLContexts URLContexts: Set<UIOpenURLContext>)
    
    @MainActor
    func register(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?)
}
