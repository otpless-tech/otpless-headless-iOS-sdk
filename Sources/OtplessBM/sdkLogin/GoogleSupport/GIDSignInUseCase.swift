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
    ) async -> GoogleSignInResponse {
        os_log("OTPLESS: Google support not initialized. Please add OtplessBM/GoogleSupport to your Podfile")
        return GoogleSignInResponse(
            success: false,
            idToken: nil,
            error: "Google support not initialized. Please add OtplessBM/GoogleSupport to your Podfile"
        )
    }
    
    func isGIDDeeplink(url: URL) -> Bool {
        return false
    }
}
#else
@preconcurrency import GoogleSignIn

#if canImport(GoogleSignInSwift)
@preconcurrency import GoogleSignInSwift
#endif

internal class GIDSignInUseCase: NSObject, GoogleAuthProtocol {
    func isGIDDeeplink(url: URL) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }
    
    @MainActor
    func signIn(
        vc: UIViewController,
        withHint hint: String?,
        shouldAddAdditionalScopes additionalScopes: [String]?,
        withNonce nonce: String?
    ) async -> GoogleSignInResponse {
        do {
            let signInResult = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: vc,
                hint: hint,
                additionalScopes: additionalScopes,
                nonce: nonce
            )
            
            guard let idToken = signInResult.user.idToken?.tokenString else {
                return handleSignInError("Invalid idToken")
            }
            
            return GoogleSignInResponse(
                success: true,
                idToken: idToken,
                error: nil
            )
        } catch {
            return handleSignInError(error.localizedDescription)
        }
    }
    
    private func handleSignInError(_ errorDescription: String) -> GoogleSignInResponse {
        return GoogleSignInResponse(
            success: false,
            idToken: nil,
            error: errorDescription
        )
    }
}
#endif

struct GoogleSignInResponse: Sendable {
    let channel: String = OtplessChannelType.GOOGLE_SDK.rawValue
    let success: Bool
    let idToken: String?
    let error: String?
    
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

protocol GoogleAuthProtocol {
    func signIn(
        vc: UIViewController,
        withHint hint: String?,
        shouldAddAdditionalScopes additionalScopes: [String]?,
        withNonce nonce: String?
    ) async -> GoogleSignInResponse
    
    func isGIDDeeplink(url: URL) -> Bool
}
