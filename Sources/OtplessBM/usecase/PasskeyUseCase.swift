//
//  with.swift
//  OtplessSDK
//
//  Created by Digvijay Singh on 25/01/26.
//

import Foundation
import AuthenticationServices
import LocalAuthentication

/// `PasskeyUseCase` is used to manage sign in and registration via WebAuthn.
///
/// We haven't annotated the class with `@available(iOS 15, *)` so that it's class level instance can be created in common classes thay may
/// supporting previous versions of iOS. Instead, we have annotated it's extension and other all the functions with `@available(iOS 16, *)`.
internal class PasskeyUseCase: NSObject {
    private let usecaseProvider: UsecaseProvider
    
    init(others usecaseProvider: UsecaseProvider) {
        self.usecaseProvider = usecaseProvider
    }
    
    private var continuation: CheckedContinuation<Result<[String: Any], Error>, Never>? = nil
    
    func autherizePasskey(request: [String: Any]) async -> Result<OtplessResponse, Error> {
        guard #available(iOS 15.0, *) else {
            return .failure(NSError(domain: "this plarform is not supported", code: 5208))
        }
        guard let dataStr = request["data"] as? String, let data = Utils.convertStringToDictionary(dataStr) else {
            return .failure(NSError(domain: "otpless: failed to parse data", code: 0, userInfo: nil))
        }
        if let isRegistration = request["isRegistration"] as? Bool, isRegistration {
            switch createRegistrationRequest(from: data) {
            case .success(let platfromKeyRequest):
                let registrationResult = await withCheckedContinuation { contin in
                    self.continuation = contin
                    let authController = ASAuthorizationController(authorizationRequests: [platfromKeyRequest])
                    authController.delegate = self
                    authController.presentationContextProvider = self
                    authController.performRequests()
                }
                switch registrationResult {
                case .success(let data):
                    return await submitWebAuthnData(data: data)
                case .failure(let error):
                    return .failure(error)
                }
            case .failure(let error):
                return .failure(error)
            }
        } else {
            switch createSignInRequest(from: data) {
            case .success(let platformKeyRequest):
                let signInResult = await withCheckedContinuation { contin in
                    self.continuation = contin
                    let authController = ASAuthorizationController(authorizationRequests: [platformKeyRequest])
                    authController.delegate = self
                    authController.presentationContextProvider = self
                    authController.performRequests()
                }
                switch signInResult {
                case .success(let data):
                    return await submitWebAuthnData(data: data)
                case .failure(let error):
                    return .failure(error)
                }
            case .failure(let error):
                return .failure(error)
            }
        }
    }
    
    private func submitWebAuthnData(data data: [String: Any]) async -> Result<(OtplessResponse), Error> {
        var webAuthnStr = Utils.convertDictionaryToString(data)
        webAuthnStr = webAuthnStr.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
        let verifyCodeUseCase = usecaseProvider.verifyCodeUseCase
        let (otplessResponse, uid) = await verifyCodeUseCase.submitWebAuthnData(from: webAuthnStr)
        if let uid = uid {
            SecureStorage.shared.save(key: Constants.UID_KEY, value: uid)
        }
        return .success(otplessResponse)
    }
    
    /// Create RegistrationRequest using request dictionary from backend
    ///
    /// - parameter request: Dictionary sent from backend containing necessary details for creating a request
    /// - returns: Result of ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest
    @available(iOS 15.0, *)
    private func createRegistrationRequest(from request: [String: Any]) -> Result<ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest, Error> {
        guard let user = request["user"] as? [String: Any] else {
            return .failure(NSError(domain: "unable to parse user", code: 5207))
        }
        guard let rp = request["rp"] as? [String: Any] else {
            return .failure(NSError(domain: "unable to parse relying party", code: 5207))
        }
        guard let challenge = request["challenge"] as? String else {
            return .failure(NSError(domain: "unable to parse challenge", code: 5207))
        }
        guard let rpId = rp["id"] as? String else {
            return .failure(NSError(domain: "unable to parse rp id", code: 5207))
        }
        let platformProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        // Since the challenge received from backend is in format base64Url, it must be converted into base64.
        let backendCompatibleChallenge = Data(base64Encoded: Utils.convertBase64UrlToBase64(base64Url: challenge))
        guard let challenge = backendCompatibleChallenge,
              let userId = (user["id"] as? String)?.data(using: .utf8),
              let name = (user["name"] as? String) else {
            return .failure(NSError(domain: "unable to parse platformKeyRequest", code: 5207))
        }
        let platformKeyRequest = platformProvider.createCredentialRegistrationRequest(challenge: challenge, name: name, userID: userId)
        return .success(platformKeyRequest)
    }
    
    /// Create Sign In Request using request dictionary from backend
    ///
    /// - parameter request: Dictionary sent from backend containing necessary details for creating a request
    /// - returns Result of ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest
    @available(iOS 15.0, *)
    func createSignInRequest(from request: [String: Any]) -> Result<ASAuthorizationPlatformPublicKeyCredentialAssertionRequest, Error> {
        guard let challenge = request["challenge"] as? String else {
            return .failure(NSError(domain: "unable to parse challenge", code: 5207))
        }
        guard let rpId = request["rpId"] as? String else {
            return .failure(NSError(domain: "unable to parse rpId", code: 5207))
        }
        let platformProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        // Since the challenge received from backend is in format base64Url, it must be converted into base64.
        let backendCompatibleChallenge = Data(base64Encoded: Utils.convertBase64UrlToBase64(base64Url: challenge))
        guard let challenge = backendCompatibleChallenge else {
            return .failure(NSError(domain: "unable to parse challenge into base64", code: 5207))
        }
        let platformKeyRequest = platformProvider.createCredentialAssertionRequest(challenge: challenge)
        return .success(platformKeyRequest)
    }
    
    /// Checks whether device supports WebAuthN.
    func isWebAuthnsupportedOnDevice() -> Bool {
        if DeviceInfoUtils.shared.isDeviceSimulator() {
            return false
        }
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            return true
        } else {
            let msg: String
            if let laError = error as? LAError {
                switch laError.code {
                case .biometryNotAvailable:
                    msg = "Biometrics not available on device"
                case .biometryNotEnrolled:
                    msg = "Biometrics not enrolled on device"
                case .passcodeNotSet:
                    msg = "No passcode set on device"
                default:
                    msg = "Authentication error \(error?.localizedDescription ?? "")"
                }
            } else {
                msg = "Unknown error \(error?.localizedDescription ?? "")"
            }
            DispatchQueue.main.async {
                log(message: msg, type: .IS_PASSKEY_SUPPORTED)
            }
            return false
        }
    }
}

@available(iOS 15.0, *)
extension PasskeyUseCase: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    
    /// Handles the error of an authorization request.
    ///
    /// - parameter controller: The authorization controller handling the authorization.
    /// - parameter error: The error that occurred during authorization.
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(returning: .failure(error))
        continuation = nil
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
        if let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
            // A new passkey was registered
            let registrationResponse = createRegistrationResponse(from: credential)
            self.continuation?.resume(returning: .success(registrationResponse))
            self.continuation = nil
        } else if let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            let signInResponse = createSignInResponse(from: credential)
            self.continuation?.resume(returning: .success(signInResponse))
            self.continuation = nil
        } else {
            self.continuation?.resume(returning:  .failure(NSError(domain: "Unexpected credential type \(authorization.credential.description)", code: 5200)))
            self.continuation = nil
        }
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
        
        if #available(iOS 16.6, *) {
            if credential.attachment == .crossPlatform {
                authenticatorAttachment = "crossPlatform"
            } else if credential.attachment == .platform {
                authenticatorAttachment = "platform"
            } else {
                authenticatorAttachment = "NA"
            }
        } else {
            authenticatorAttachment = "platform"
        }
        responseJson["authenticatorAttachment"] = authenticatorAttachment
        return responseJson
    }
}
