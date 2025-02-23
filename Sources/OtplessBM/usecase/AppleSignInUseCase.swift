//
//  OtplessAppleSignIn.swift
//  OtplessSDK
//
//  Created by Sparsh on 19/02/25.
//


import Foundation
import AuthenticationServices

@available(iOS 13.0, *)
final class AppleSignInUseCase: NSObject {
    private var continuation: CheckedContinuation<AppleSignInResult, Never>?

    func performSignIn(withNonce nonce: String?) async -> AppleSignInResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            let appleIDProvider = ASAuthorizationAppleIDProvider()
            let request = appleIDProvider.createRequest()
            request.nonce = nonce
            request.requestedScopes = [.fullName, .email]

            let authorizationController = ASAuthorizationController(authorizationRequests: [request])
            authorizationController.delegate = self
            authorizationController.presentationContextProvider = self
            authorizationController.performRequests()
        }
    }

    private func handleSuccessfulSignIn(with credential: ASAuthorizationAppleIDCredential) -> AppleSignInResult {
        var idToken: String?
        var token: String?
        var error: String?
        var success = false

        if let identityToken = credential.identityToken,
           let idTokenString = String(data: identityToken, encoding: .utf8) {
            idToken = idTokenString
            success = true
        }

        if let authCode = credential.authorizationCode,
           let authCodeString = String(data: authCode, encoding: .utf8) {
            token = authCodeString
            success = true
        }

        if !success {
            error = "Could not retrieve valid tokens after authentication."
        }

        return AppleSignInResult(idToken: idToken, token: token, error: error, success: success)
    }

    private func handleSignInError(_ error: Error) -> AppleSignInResult {
        AppleSignInResult(error: error.localizedDescription, success: false)
    }
}

@available(iOS 13.0, *)
extension AppleSignInUseCase: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            let result = handleSuccessfulSignIn(with: credential)
            continuation?.resume(returning: result)
        } else {
            let result = AppleSignInResult(error: "Unexpected credential type", success: false)
            continuation?.resume(returning: result)
        }
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let result = handleSignInError(error)
        continuation?.resume(returning: result)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.windows.first!
    }
}

struct AppleSignInResult: Sendable {
    let idToken: String?
    let token: String?
    let error: String?
    let success: Bool
    let channel = OtplessChannelType.APPLE_SDK.rawValue

    init(idToken: String? = nil, token: String? = nil, error: String? = nil, success: Bool) {
        self.idToken = idToken
        self.token = token
        self.error = error
        self.success = success
    }
    
    func toDict() -> [String: Any] {
        var dict: [String: Any] =  [
            "channel": channel,
            "success": success
        ]
        
        if let idToken = idToken {
            dict["idToken"] = idToken
        }
        
        if let token = token {
            dict["token"] = token
        }
        
        if let error = error {
            dict["error"] = error
        }
        
        return dict
    }
}
