//
//  models.swift
//  OtplessSwiftLP
//
//  Created by Digvijay Singh on 18/09/25.
//

internal enum StorageKeys {
    static let session = "otpless_session_info"
    static let state   = "otpless_state"
}

// MARK: - Session info to be created from successful login response
internal struct OtplessSessionInfo: Codable, Equatable {
    public let sessionToken: String
    public let refreshToken: String
    public let jwtToken: String

    enum CodingKeys: String, CodingKey {
        case sessionToken
        case refreshToken
        case jwtToken = "sessionTokenJWT"
    }
}

// MARK: - Authenticate Session Response
internal struct AuthenticateSessionResponse: Codable, Equatable {
    public let sessionTokenJWT: String
}

// MARK: - Delete Session Response
internal struct DeleteSessionResponse: Codable, Equatable {
    public let message: String
    public let success: Bool
}

// Mark: Otpless Session state to be passed to client
public enum OtplessSessionState: Equatable {
    case active(String)   // jwtToken
    case inactive
}
