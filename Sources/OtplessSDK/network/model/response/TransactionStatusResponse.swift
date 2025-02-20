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

struct Subdivisions: Codable {
    let code: String
    let name: String
    
    func toDict() -> [String: Any] {
        ["code": code, "name": name]
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
    let token: String
    let uiId: String?
    let user: User?
    let webauthnRegistered: Bool
    let communicationMode: String?
    let errorDetails: String?
}

struct City: Codable {
    let name: String
    
    func toDict() -> [String: Any] {
        return ["name": name]
    }
}

struct Continent: Codable {
    let code: String
    
    func toDict() -> [String: Any] {
        return ["code": code]
    }
}

struct DeviceInfo: Codable {
    let browser: String?
    let connection: String?
    let cookieEnabled: Bool?
    let cpuArchitecture: String?
    let devicePixelRatio: Double?
    let fontFamily: String?
    let language: String?
    let platform: String?
    let screenColorDepth: Int?
    let screenHeight: Int?
    let screenWidth: Int?
    let timezoneOffset: Int?
    let userAgent: String?
    let vendor: String?
    
    func toDict() -> [String: Any] {
        [
            "browser": browser as Any,
            "connection": connection as Any,
            "cookieEnabled": cookieEnabled as Any,
            "cpuArchitecture": cpuArchitecture as Any,
            "devicePixelRatio": devicePixelRatio as Any,
            "fontFamily": fontFamily as Any,
            "language": language as Any,
            "platform": platform as Any,
            "screenColorDepth": screenColorDepth as Any,
            "screenHeight": screenHeight as Any,
            "screenWidth": screenWidth as Any,
            "timezoneOffset": timezoneOffset as Any,
            "userAgent": userAgent as Any,
            "vendor": vendor as Any
        ].compactMapValues { $0 }
    }
}

struct Country: Codable {
    let code: String
    let name: String
    
    func toDict() -> [String: Any] {
        return ["code": code, "name": name]
    }
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
    let channel: String
    let identityType: String?
    let identityValue: String?
    let methods: [String]?
    let verified: Bool
    let verifiedAt: String
    let type: String?
    
    func toDict() -> [String: Any] {
        [
            "channel": channel,
            "identityType": identityType as Any,
            "identityValue": identityValue as Any,
            "methods": methods as Any,
            "verified": verified,
            "verifiedAt": verifiedAt,
            "type": type as Any
        ].compactMapValues { $0 }
    }
}

struct IpLocation: Codable {
    let city: City
    let continent: Continent
    let country: Country
    let latitude: Double
    let longitude: Double
    let postalCode: String
    let subdivisions: Subdivisions
    
    func toDict() -> [String: Any] {
        return [
            "city": city.toDict(),
            "continent": continent.toDict(),
            "country": country.toDict(),
            "latitude": latitude,
            "longitude": longitude,
            "postalCode": postalCode,
            "subdivisions": subdivisions.toDict()
        ]
    }
}


struct MerchantUserInfo: Codable {
    let deviceInfo: DeviceInfo?
    let idToken: String?
    let identities: [Identity]
    let network: Network
    let status: String
    let timestamp: String
    let token: String
    let userId: String?
    
    func toDict() -> [String: Any] {
        [
            "deviceInfo": deviceInfo?.toDict() as Any,
            "idToken": idToken as Any,
            "identities": identities.map { $0.toDict() },
            "network": network.toDict(),
            "status": status,
            "timestamp": timestamp,
            "token": token,
            "userId": userId as Any
        ].compactMapValues { $0 }
    }
}

struct Network: Codable {
    let ip: String
    let ipLocation: IpLocation
    let timezone: String
    
    func toDict() -> [String: Any] {
        return [
            "ip": ip,
            "ipLocation": ipLocation.toDict(),
            "timezone": timezone
        ]
    }
}

struct OneTap: Codable {
    let firebaseInfo: FirebaseInfo?
    let merchantUserInfo: MerchantUserInfo?
    let sessionInfo: SessionInfo?
    let status: String
    let token: String
    
    func toDict() -> [String: Any] {
        [
            "firebaseInfo": firebaseInfo?.toDict() as Any,
            "data": merchantUserInfo?.toDict() as Any,
            "sessionInfo": sessionInfo?.toDict() as Any,
            "status": status,
            "token": token
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
