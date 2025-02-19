//
//  OtplessAppleSignIn.swift
//  OtplessSDK
//
//  Created by Sparsh on 19/02/25.
//


import Foundation
import AuthenticationServices

@available(iOS 13.0, *)
class AppleSignInUseCase: NSObject {
    
    @MainActor
    func invoke(withNonce nonce: String?) async -> AppleSignInResult {
        do {
            let credential = try await signIn(withNonce: nonce)
            return handleSuccessfulSignIn(with: credential)
        } catch {
            return handleSignInError(error)
        }
    }
    
    @MainActor
    private func signIn(withNonce nonce: String?) async throws -> ASAuthorizationAppleIDCredential {
        return try await withCheckedThrowingContinuation { continuation in
            let appleIDProvider = ASAuthorizationAppleIDProvider()
            let request = appleIDProvider.createRequest()
            request.nonce = nonce
            request.requestedScopes = [.fullName, .email]
            
            let authorizationController = ASAuthorizationController(authorizationRequests: [request])
            let delegate = AppleSignInDelegate { result in
                continuation.resume(with: result)
            }
            authorizationController.delegate = delegate
            authorizationController.presentationContextProvider = delegate
            authorizationController.performRequests()
        }
    }
    
    private func handleSuccessfulSignIn(with credential: ASAuthorizationAppleIDCredential) -> AppleSignInResult {
        let appleSignInResult = AppleSignInResult()
        
        if let idToken = credential.identityToken,
           let idTokenStr = String(data: idToken, encoding: .utf8) {
            appleSignInResult.setIdToken(idTokenStr)
        }
        
        if let authorizationCode = credential.authorizationCode,
           let authorizationCodeStr = String(data: authorizationCode, encoding: .utf8) {
            appleSignInResult.setToken(authorizationCodeStr)
        }
        
        if appleSignInResult.idToken == nil && appleSignInResult.token == nil {
            appleSignInResult.setErrorStr("Could not get a valid token after authentication.")
        }
        
        return appleSignInResult
    }
    
    private func handleSignInError(_ error: Error) -> AppleSignInResult{
        let appleSignInResult = AppleSignInResult()
        appleSignInResult.setErrorStr(error.localizedDescription)
        return appleSignInResult
    }
}

@available(iOS 13.0, *)
private class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let completion: (Result<ASAuthorizationAppleIDCredential, Error>) -> Void
    
    init(completion: @escaping (Result<ASAuthorizationAppleIDCredential, Error>) -> Void) {
        self.completion = completion
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            completion(.success(appleIDCredential))
        }
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        completion(.failure(error))
    }
    
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return UIApplication.shared.windows.first!
    }
}

class AppleSignInResult: @unchecked Sendable {
    var idToken: String?
    var error: String?
    var success: Bool = false
    let channel = OtplessChannelType.APPLE_SDK.rawValue
    var token: String?
    
    func setToken(_ token: String) {
        self.token = token
        self.success = true
    }
    
    func setIdToken(_ idToken: String) {
        self.idToken = idToken
        self.success = true
    }
    
    func setErrorStr(_ error: String) {
        self.error = error
        self.success = false
    }
    
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
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
