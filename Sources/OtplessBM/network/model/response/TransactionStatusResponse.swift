//
//  TransactionStatusResponse.swift
//  otpless-iOS-headless-sdk
//
//  Created by Sparsh on 16/01/25.
//

import Foundation

struct TransactionStatusResponse: Codable {
    let authDetail: AuthDetail
    let config: Config?
    let oneTap: OneTap?
    let otpVerificationDetail: OtpVerificationDetail?
    let quantumLeap: QuantumLeap?
}

struct User: Codable {
    let email: String?
    let mobile: String?
    let name: String?
    let uid: String
    
    func toDict() -> [String: Any] {
        [
            "uid": uid,
            "email": email as Any,
            "mobile": mobile as Any,
            "name": name as Any
        ].compactMapValues { $0 }
    }
}

struct SessionInfo: Codable {
    let refreshToken: String?
    let sessionId: String?
    let sessionToken: String?
    
    func toDict() -> [String: Any] {
         [
            "refreshToken": refreshToken as Any,
            "sessionId": sessionId as Any,
            "sessionToken": sessionToken as Any
         ].compactMapValues { $0 }
    }
}

struct AuthDetail: Codable {
    let asId: String?
    let channel: String?
    let communicationDelivered: Bool
    let isCrossDevice: Bool?
    let status: String
    let token: String?
    let uiId: String?
    let user: User?
    let webauthnRegistered: Bool?
    let communicationMode: String?
    let errorDetails: String?
}

struct FirebaseInfo: Codable {
    let firebaseToken: String?
    
    func toDict() -> [String: Any] {
        if let firebaseToken = firebaseToken {
            return ["firebaseToken": firebaseToken]
        }

        return [:]
    }
}

struct Identity: Codable {
    let channel: String?
    let identityType: String?
    let identityValue: String?
    let methods: [String]?
    let verified: Bool?
    let verifiedAt: String?
    let type: String?
    let providerMetadata: [String: CodableValue]?
    let picture: String?
    let isCompanyEmail: Bool?
    
    func toDict() -> [String: Any] {
        var dict = [
            "channel": channel as Any,
            "identityType": identityType as Any,
            "identityValue": identityValue as Any,
            "methods": methods as Any,
            "verified": verified as Any,
            "verifiedAt": verifiedAt as Any,
            "type": type as Any,
            "picture": picture as Any,
            "isCompanyEmail": isCompanyEmail as Any
        ]
        
        if let additionalData = providerMetadata {
            dict["providerMetadata"] = additionalData.mapValues { $0.value }
        }
        
        return dict.compactMapValues { $0 }
    }
}


struct MerchantUserInfo: Codable {
    let idToken: String?
    let identities: [Identity]
    let timestamp: String?
    let token: String
    let userId: String?
    
    func toDict() -> [String: Any] {
        [
            "idToken": idToken as Any,
            "identities": identities.map { $0.toDict() ?? [:] },
            "timestamp": timestamp,
            "token": token,
            "userId": userId as Any
        ].compactMapValues { $0 }
    }
}

struct OneTap: Codable {
    let firebaseInfo: FirebaseInfo?
    let merchantUserInfo: MerchantUserInfo?
    let sessionInfo: SessionInfo?
    let status: String?
    
    func toDict() -> [String: Any] {
        [
            "firebaseInfo": firebaseInfo?.toDict() as Any,
            "data": merchantUserInfo?.toDict() as Any,
            "sessionInfo": sessionInfo?.toDict() as Any,
            "status": status,
        ].compactMapValues { $0 }
    }
}

struct OtpVerificationDetail: Codable {
    let code: String
    let isOTPVerified: Bool
    
    func toDict() -> [String: Any] {
        return [
            "code": code,
            "isOTPVerified": isOTPVerified
        ]
    }
}

enum CodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: CodableValue])
    case array([CodableValue])

    var value: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .dictionary(let value): return value.mapValues { $0.value }
        case .array(let value): return value.map { $0.value }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: CodableValue].self) {
            self = .dictionary(value)
        } else if let value = try? container.decode([CodableValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .dictionary(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        }
    }
}
