//
//  with.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//

import Foundation
import AuthenticationServices
import LocalAuthentication

/// `PasskeyUseCase` is used to manage sign in and registration via WebAuthn.
///
/// We haven't annotated the class with `@available(iOS 16, *)` so that it's class level instance can be created in common classes thay may
/// supporting previous versions of iOS. Instead, we have annotated it's extension and other all the functions with `@available(iOS 16, *)`.
internal class PasskeyUseCase: NSObject {
    private var responseCallback: ((PasskeyAuthorizationResult) async -> Void)?
    
    /// Initiates Passkey registration.
    ///
    /// - parameter request: The request dictionary containing registration parameters.
    /// - parameter onResponse: The callback to handle the registration response.
    @available(iOS 16.6, *)
    func initiateRegistration(
        withRequest requestJson: [String: Any],
        onResponse responseCallback: @escaping  (PasskeyAuthorizationResult) async -> Void
    ) async {
        self.responseCallback = responseCallback
        
        await createRegistrationRequest(
            from: requestJson,
            onErrorCallback: responseCallback,
            onRegistrationRequestCreation: { platformKeyRequest in
                let authController = ASAuthorizationController(authorizationRequests: [ platformKeyRequest ])
                authController.delegate = self
                authController.presentationContextProvider = self
                authController.performRequests()
            }
        )
    }
    
    /// Initiates sign in via Passkey.
    ///
    /// - parameter request: The request dictionary containing registration parameters.
    /// - parameter onResponse: The callback to handle the sign in response.
    @available(iOS 16.6, *)
    func initiateSignIn(
        withRequest requestJson: [String: Any],
        onResponse responseCallback: @escaping (PasskeyAuthorizationResult) async -> Void
    ) async {
        self.responseCallback = responseCallback
        
        await createSignInRequest(
            from: requestJson,
            onErrorCallback: responseCallback,
            onSignInRequestCreation: { platformKeyRequest in
                let authController = ASAuthorizationController(authorizationRequests: [ platformKeyRequest ])
                authController.delegate = self
                authController.presentationContextProvider = self
                authController.performRequests()
            }
        )
    }
    
    /// Checks whether device supports WebAuthN.
    ///
    /// - parameter callback: The callback to return the result of check.
    @MainActor @available(iOS 16.6, *)
    func isWebAuthnsupportedOnDevice(onResponse callback: (Bool) -> Void) {
        if DeviceInfoUtils.shared.isDeviceSimulator() {
            callback(false)
            return
        }
        
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            callback(true)
        } else {
            if let laError = error as? LAError {
                switch laError.code {
                case .biometryNotAvailable:
                    log(message: "Biometrics not available on device", type: .IS_PASSKEY_SUPPORTED)
                case .biometryNotEnrolled:
                    log(message: "Biometrics not available on device", type: .IS_PASSKEY_SUPPORTED)
                case .passcodeNotSet:
                    log(message: "No passcode set on device", type: .IS_PASSKEY_SUPPORTED)
                default:
                    log(message: "Authentication error \(error?.localizedDescription ?? "")", type: .IS_PASSKEY_SUPPORTED)
                }
            } else {
                log(message: "Unknown error \(error?.localizedDescription ?? "")", type: .IS_PASSKEY_SUPPORTED)
            }
            callback(false)
        }
    }
}

@available(iOS 16.6, *)
extension PasskeyUseCase: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    
    /// Handles the error of an authorization request.
    ///
    /// - parameter controller: The authorization controller handling the authorization.
    /// - parameter error: The error that occurred during authorization.
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let authorizationError = error as? ASAuthorizationError
        let errorJson: [String: Any] = createError(fromAuthorizationError: authorizationError)
        
        Task {
            await responseCallback?(.failure(errorJson))
        }
    }
    
    
    /// Provides the presentation anchor for the `ASAuthorizationController`.
    ///
    /// - parameter controller: The authorization controller requesting the presentation anchor.
    /// - returns: The presentation anchor for the authorization controller.
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return ASPresentationAnchor(windowScene: Otpless.shared.merchantWindowScene!)
    }
    
    
    /// Handles the successful completion of an authorization request.
    ///
    /// - parameter controller: The authorization controller handling the authorization.
    /// - parameter authorization: The authorization result.
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task {
            if let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
                // A new passkey was registered
                let registrationResponse = createRegistrationResponse(from: credential)
                await responseCallback?(.success(registrationResponse))
            } else if let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
                // A passkey was used to sign in
                let signInResponse = createSignInResponse(from: credential)
                await responseCallback?(.success(signInResponse))
            } else {
                // Some other authorization type was used like passwords.
                let errorJson = Utils.createErrorDictionary(errorCode: "5200", errorMessage: "Unexpected credential type \(authorization.credential.description)")
                await responseCallback?(.failure(errorJson))
            }
        }
    }
}

@available(iOS 16.6, *)
extension PasskeyUseCase {
    
    /// Create authorization error dictionary.
    ///
    /// - parameter error: This is the error that occured during registration or sign in via passkey.
    /// - returns: A dictionary containing error and its description.
    private func createError(fromAuthorizationError error: ASAuthorizationError?) -> [String: Any] {
        var errorJson: [String: Any] = [:]
        
        switch error?.code {
        case .canceled:
            errorJson = Utils.createErrorDictionary(errorCode: "5200", errorMessage: "Unexpected cancelled authorization attempt")
        case .failed:
            errorJson = Utils.createErrorDictionary(errorCode: "5201", errorMessage: "Authorization attempt failed")
        case .invalidResponse:
            errorJson = Utils.createErrorDictionary(errorCode: "5202", errorMessage: "Authorization attempt received invalid response")
        case .notHandled:
            errorJson = Utils.createErrorDictionary(errorCode: "5203", errorMessage: error?.localizedDescription ?? "Authorization request was not handled.")
        case .notInteractive:
            errorJson = Utils.createErrorDictionary(errorCode: "5204", errorMessage: error?.localizedDescription ?? "Authorization request does not involve user interaction.")
        case .unknown:
            errorJson = Utils.createErrorDictionary(errorCode: "5205", errorMessage: error?.localizedDescription ?? "Authorization request failed due to unknown reasons.")
        default:
            errorJson = Utils.createErrorDictionary(errorCode: "5206", errorMessage: error?.localizedDescription ?? "Unable to authorize via passkey.")
        }
        
        return errorJson
    }
    
    /// Creates a parsing error and calls the callback with the error dictionary.
    ///
    /// - parameter errorIdentifier: The identifier for the parsing error.
    /// - parameter callback: The callback to return the error dictionary.
    private func createParsingError(
        errorIdentifier: String,
        callback: @escaping (PasskeyAuthorizationResult) async -> Void
    ) async {
        await callback(.failure(
            Utils.createErrorDictionary(errorCode: "5207", errorMessage: "Unable to parse \(errorIdentifier)")
        ))
    }
    
    
    /// Creates a registration response from the provided credential.
    ///
    /// - parameter credential: The credential used for registration.
    /// - returns: A dictionary containing the registration response.
    private func createRegistrationResponse(from credential: ASAuthorizationPlatformPublicKeyCredentialRegistration) -> [String: Any] {
        var attestationJson: [String: Any] = [:]
        
        attestationJson["clientDataJSON"] = Utils.base64UrlEncode(base64String:  credential.rawClientDataJSON.base64EncodedString())
        attestationJson["attestationObject"] = Utils.base64UrlEncode(base64String: credential.rawAttestationObject?.base64EncodedString() ?? "")
        
        var responseJson: [String: Any] = [:]
        responseJson["response"] = attestationJson
        responseJson["id"] = Utils.base64UrlEncode(base64String: credential.credentialID.base64EncodedString())
        responseJson["rawId"] = Utils.base64UrlEncode(base64String: credential.credentialID.base64EncodedString())
        responseJson["type"] = "public-key"
        
        return responseJson
    }
    
    
    /// Creates a sign-in response from the provided credential.
    ///
    /// - parameter credential: The credential used for sign-in.
    /// - returns: A dictionary containing the sign-in response.
    private func createSignInResponse(from credential: ASAuthorizationPlatformPublicKeyCredentialAssertion) -> [String: Any] {
        var attestationJson: [String: Any] = [:]
        
        attestationJson["clientDataJSON"] = Utils.base64UrlEncode(base64String:  credential.rawClientDataJSON.base64EncodedString())
        
        attestationJson["authenticatorData"] = Utils.base64UrlEncode(base64String:  credential.rawAuthenticatorData.base64EncodedString())
        attestationJson["signature"] = Utils.base64UrlEncode(base64String: credential.signature.base64EncodedString())
        
        var responseJson: [String: Any] = [:]
        responseJson["id"] = Utils.base64UrlEncode(base64String: credential.credentialID.base64EncodedString())
        responseJson["rawId"] = Utils.base64UrlEncode(base64String: credential.credentialID.base64EncodedString())
        responseJson["type"] = "public-key"
        responseJson["response"] = attestationJson
        
        let authenticatorAttachment: String
        
        if credential.attachment == .crossPlatform {
            authenticatorAttachment = "crossPlatform"
        } else if credential.attachment == .platform {
            authenticatorAttachment = "platform"
        } else {
            authenticatorAttachment = "NA"
        }
        
        responseJson["authenticatorAttachment"] = authenticatorAttachment
        
        return responseJson
    }
    
    
    /// Create RegistrationRequest using request dictionary from backend
    ///
    /// - parameter request: Dictionary sent from backend containing necessary details for creating a request
    /// - parameter onErrorCallback: Returns an error in the callback
    /// - parameter onRegistrationRequestCreation: Returns registration request for passkey (an instance of `ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest`).
    func createRegistrationRequest(
        from request: [String: Any],
        onErrorCallback: @escaping (PasskeyAuthorizationResult) async -> Void,
        onRegistrationRequestCreation: (ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest) -> Void
    ) async {
        guard let user = request["user"] as? [String: Any] else {
            await createParsingError(errorIdentifier: "user", callback: onErrorCallback)
            return
        }
        
        guard let rp = request["rp"] as? [String: Any] else {
            await createParsingError(errorIdentifier: "relying party", callback: onErrorCallback)
            return
        }
        
        guard let challenge = request["challenge"] as? String else {
            await createParsingError(errorIdentifier: "challenge", callback: onErrorCallback)
            return
        }
        
        var platformProvider: ASAuthorizationPlatformPublicKeyCredentialProvider?
        guard let rpId = rp["id"] as? String else {
            await createParsingError(errorIdentifier: "rp id", callback: onErrorCallback)
            return
        }
        
        platformProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        
        var platformKeyRequest: ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest?
        
        // Since the challenge received from backend is in format base64Url, it must be converted into base64.
        let backendCompatibleChallenge = Data(base64Encoded: Utils.convertBase64UrlToBase64(base64Url: challenge))
        
        if let challenge = backendCompatibleChallenge,
           let userId = (user["id"] as? String)?.data(using: .utf8),
           let name = (user["name"] as? String)
        {
            platformKeyRequest = platformProvider?.createCredentialRegistrationRequest(challenge: challenge, name: name, userID: userId)
        }
        
        guard let platformKeyRequest = platformKeyRequest else {
            await createParsingError(errorIdentifier: "platformKeyRequest", callback: onErrorCallback)
            return
        }
        
        onRegistrationRequestCreation(platformKeyRequest)
    }
    
    
    /// Create Sign In Request using request dictionary from backend
    ///
    /// - parameter request: Dictionary sent from backend containing necessary details for creating a request
    /// - parameter onErrorCallback: Returns an error in the callback
    /// - parameter onSignInRequestCreation: Returns registration request for passkey (an instance of `ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest`).
    func createSignInRequest(
        from request: [String: Any],
        onErrorCallback: @escaping (PasskeyAuthorizationResult) async -> Void,
        onSignInRequestCreation: (ASAuthorizationPlatformPublicKeyCredentialAssertionRequest) -> Void
    ) async {
        guard let challenge = request["challenge"] as? String else {
            await createParsingError(errorIdentifier: "challenge", callback: onErrorCallback)
            return
        }
        
        var platformProvider: ASAuthorizationPlatformPublicKeyCredentialProvider?
        guard let rpId = request["rpId"] as? String else {
            await createParsingError(errorIdentifier: "rpId", callback: onErrorCallback)
            return
        }
        
        platformProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        
        var platformKeyRequest: ASAuthorizationPlatformPublicKeyCredentialAssertionRequest?
        
        // Since the challenge received from backend is in format base64Url, it must be converted into base64.
        let backendCompatibleChallenge = Data(base64Encoded: Utils.convertBase64UrlToBase64(base64Url: challenge))
        
        if let challenge = backendCompatibleChallenge {
            platformKeyRequest = platformProvider?.createCredentialAssertionRequest(challenge: challenge)
        }
        
        guard let platformKeyRequest = platformKeyRequest else {
            await createParsingError(errorIdentifier: "platformKeyRequest", callback: onErrorCallback)
            return
        }
        
        onSignInRequestCreation(platformKeyRequest)
    }
}

extension PasskeyUseCase {
    func handleResult(forAuthorizationResult result: PasskeyAuthorizationResult) -> String {
        switch result {
        case .success(let dictionary):
            return Utils.convertDictionaryToString(dictionary)
        case .failure(let dictionary):
            return Utils.convertDictionaryToString(dictionary)
        }
    }
}

enum PasskeyAuthorizationResult: @unchecked Sendable {
    case success([String: Any])
    case failure([String: Any])
}
