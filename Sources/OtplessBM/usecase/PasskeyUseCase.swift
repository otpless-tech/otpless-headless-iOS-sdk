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

internal class  PasskeyUseCase: NSObject {
    
    private let usecaseProvider: UsecaseProvider
    
    init(others usecaseProvider: UsecaseProvider) {
        self.usecaseProvider = usecaseProvider
    }
    
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
                let registrationResult = await performAuthWithiOS(request: platfromKeyRequest)
                switch registrationResult {
                case .success(let data):
                    return await submitWebAuthnData(data: Utils.convertStringToDictionary(data)!)
                case .failure(let error):
                    return .failure(error)
                }
            case .failure(let error):
                return .failure(error)
            }
        } else {
            switch createSignInRequest(from: data) {
            case .success(let platformKeyRequest):
                let signInResult = await performAuthWithiOS(request: platformKeyRequest)
                switch signInResult {
                case .success(let data):
                    return await submitWebAuthnData(data: Utils.convertStringToDictionary(data)!)
                case .failure(let error):
                    return .failure(error)
                }
            case .failure(let error):
                return .failure(error)
            }
        }
    }
    
    @available(iOS 15.0, *)
    private func performAuthWithiOS(request: ASAuthorizationRequest) async -> Result<String, Error> {
        let passkeyAuthView = await MainActor.run { PasskeyASAuthorizationView() }
        return await passkeyAuthView.performAuthWithiOS(request: request)
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
        let base64EncodeChallenge = Data(base64Encoded: Utils.convertBase64UrlToBase64(base64Url: challenge))
        guard let challenge = base64EncodeChallenge,
              let userId = (user["id"] as? String)?.data(using: .utf8),
              let name = (user["name"] as? String) else {
            return .failure(NSError(domain: "unable to parse platformKeyRequest", code: 5207))
        }
        let registrationRequest = platformProvider.createCredentialRegistrationRequest(challenge: challenge, name: name, userID: userId)
        // setting attestation
        if let attestation = request["attestation"] as? String {
            switch attestation.lowercased() {
            case "direct":
                registrationRequest.attestationPreference = .direct
            case "enterprise":
                if #available(iOS 16.0, *) {
                    registrationRequest.attestationPreference = .enterprise
                } else {
                    registrationRequest.attestationPreference = .direct // fallback
                }
            default:
                registrationRequest.attestationPreference = .none
            }
        }
        // setting authenticator selection
        if let authenticatorSelection = request["authenticatorSelection"] as? [String: Any], let uv = authenticatorSelection["userVerification"] as? String {
            switch uv.lowercased() {
            case "required": registrationRequest.userVerificationPreference = .required
            case "discouraged": registrationRequest.userVerificationPreference = .discouraged
            default: registrationRequest.userVerificationPreference = .preferred
            }
        }
        // setting excludeCredentials
        if #available(iOS 17.4, *), let excludeCreds = request["excludeCredentials"] as? [[String: Any]] {
            let descriptors: [ASAuthorizationPlatformPublicKeyCredentialDescriptor] =
            excludeCreds.compactMap { item in
                guard let idB64Url = item["id"] as? String else { return nil }
                let idB64 = Utils.convertBase64UrlToBase64(base64Url: idB64Url)
                guard let credId = Data(base64Encoded: idB64) else { return nil }
                return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: credId)
            }
            if !descriptors.isEmpty {
                registrationRequest.excludedCredentials = descriptors
            }
        }
        return .success(registrationRequest)
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
        let assertionRequest = platformProvider.createCredentialAssertionRequest(challenge: challenge)
        // allowCredentials
        if let allowCreds = request["allowCredentials"] as? [[String: Any]] {
            var descriptors: [ASAuthorizationPlatformPublicKeyCredentialDescriptor] = []
            descriptors.reserveCapacity(allowCreds.count)
            for item in allowCreds {
                guard let idB64Url = item["id"] as? String else { continue }
                let idB64 = Utils.convertBase64UrlToBase64(base64Url: idB64Url)
                guard let credId = Data(base64Encoded: idB64) else { continue }
                // iOS descriptor only needs credentialID (no "type" / "transports")
                descriptors.append(ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: credId))
            }
            if !descriptors.isEmpty {
                assertionRequest.allowedCredentials = descriptors
            }
        }
        // WebAuthn "userVerification": required / preferred / discouraged
        if let uv = request["userVerification"] as? String {
            switch uv.lowercased() {
            case "required":
                assertionRequest.userVerificationPreference = .required
            case "discouraged":
                assertionRequest.userVerificationPreference = .discouraged
            default:
                assertionRequest.userVerificationPreference = .preferred
            }
        }
        return .success(assertionRequest)
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
@MainActor
internal class PasskeyASAuthorizationView: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    
    private var continuation: CheckedContinuation<Result<String, Error>, Never>? = nil
    
    func performAuthWithiOS(request: ASAuthorizationRequest) async -> Result<String, Error> {
        await withCheckedContinuation { cont in
            self.continuation = cont
            let authController = ASAuthorizationController(authorizationRequests: [request])
            authController.delegate = self
            authController.presentationContextProvider = self
            authController.performRequests()
        }
    }
    
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
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return ASPresentationAnchor(windowScene: scene)
        }
        return ASPresentationAnchor()
    }
    
    /// Handles the successful completion of an authorization request.
    ///
    /// - parameter controller: The authorization controller handling the authorization.
    /// - parameter authorization: The authorization result.
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
            // A new passkey was registered
            let registrationResponse = createRegistrationResponse(from: credential)
            self.continuation?.resume(returning: .success(Utils.convertDictionaryToString(registrationResponse)))
            self.continuation = nil
        } else if let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            let signInResponse = createSignInResponse(from: credential)
            self.continuation?.resume(returning: .success(Utils.convertDictionaryToString(signInResponse)))
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
