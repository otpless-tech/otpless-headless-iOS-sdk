//
//  GIDSignInUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 19/02/25.
//

import Foundation
import UIKit
import os

// Empty implementation for when Google SDK is not available
#if !canImport(GoogleSignIn) && !canImport(GoogleSignInSwift)
internal class GIDSignInUseCase: NSObject, GoogleAuthProtocol {
    func signIn(
        vc: UIViewController,
        withHint hint: String?,
        shouldAddAdditionalScopes additionalScopes: [String]?,
        withNonce nonce: String?
    ) async -> [String: Any] {
        os_log("OTPLESS: Google support not initialized. Please add OtplessBM/GoogleSupport to your Podfile")
        return [
            "success": false,
            "error": "Google support not initialized. Please add OtplessBM/GoogleSupport to your Podfile"
        ]
    }
    
    func isGIDDeeplink(url: URL) -> Bool {
        return false
    }
}
#else
import GoogleSignIn

#if canImport(GoogleSignInSwift)
import GoogleSignInSwift
#endif

internal class GIDSignInUseCase: NSObject, GoogleAuthProtocol {
    func isGIDDeeplink(url: URL) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }
    
    /// Initiates the Google Sign-In process using Swift Concurrency.
    ///
    /// - Parameters:
    ///   - vc: The `UIViewController` that presents the sign-in UI.
    ///   - hint: An optional string to suggest a Google account for the sign-in prompt.
    ///   - additionalScopes: An optional array of additional OAuth 2.0 scopes to request access to.
    ///   - nonce: An optional cryptographic nonce to associate with the sign-in request for enhanced security.
    /// - Returns: A dictionary containing the sign-in result.
    func signIn(
        vc: UIViewController,
        withHint hint: String?,
        shouldAddAdditionalScopes additionalScopes: [String]?,
        withNonce nonce: String?
    ) async -> [String: Any] {
        do {
            let signInResult = try await GIDSignIn.sharedInstance.signIn(withPresenting: vc, hint: hint, additionalScopes: additionalScopes, nonce: nonce)
            
            guard let idToken = signInResult.user.idToken?.tokenString else {
                return handleSignInError("Invalid idToken")
            }
            
            return GIDSignInResult(success: true, idToken: idToken, error: nil).toDict()
        } catch {
            return handleSignInError(error.localizedDescription)
        }
    }
    
    private func handleSignInError(_ errorDescription: String) -> [String: Any] {
        return GIDSignInResult(success: false, idToken: nil, error: errorDescription).toDict()
    }
}

private class GIDSignInResult: NSObject {
    let channel: String = OtplessChannelType.GOOGLE_SDK.rawValue
    let success: Bool
    let idToken: String?
    let error: String?
    
    init(success: Bool, idToken: String?, error: String?) {
        self.success = success
        self.idToken = idToken
        self.error = error
    }
    
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "channel": channel,
            "success": success
        ]
        
        if let idToken = idToken {
            dict["idToken"] = idToken
        }
        
        if let error = error {
            dict["error"] = error
        }
        
        return dict
    }
}
#endif

protocol GoogleAuthProtocol {
    func signIn(
        vc: UIViewController,
        withHint hint: String?,
        shouldAddAdditionalScopes additionalScopes: [String]?,
        withNonce nonce: String?
    ) async -> [String: Any]
    
    func isGIDDeeplink(url: URL) -> Bool
}

