//
//  internal.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//


import Foundation

internal enum ApiResponse<T> {
    case success(data: T?)
    case error(error: ApiError)
}

internal final class ApiError: Error, @unchecked Sendable {
    let message: String
    let statusCode: Int
    let responseJson: [String: Any]?

    init(message: String, statusCode: Int = 0, responseJson: [String: Any]? = nil) {
        self.message = message
        self.statusCode = statusCode
        self.responseJson = responseJson
    }

    var description: String {
        return "message: \(message)\nstatusCode: \(statusCode)\(responseJson != nil ? "\n\(responseJson!)" : "")"
    }
    
    func getResponse() -> [String: String] {
        let errorCode = responseJson?["errorCode"] as? String ?? String(statusCode)
        
        return [
            "errorCode": errorCode,
            "errorMessage": responseJson?["description"] as? String ?? message
        ]
    }
}
