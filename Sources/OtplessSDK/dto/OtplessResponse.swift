//
//  OtplessResponse.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//

public struct OtplessResponse: @unchecked Sendable {
    let responseType: ResponseTypes
    let response: [String: Any]?
    let statusCode: Int
    
    internal static func createNoInternetResponse() -> OtplessResponse {
        let json: [String: Any] = [
            "errorMessage": "Internet Error",
            "errorCode": "-1009"
        ]
        return OtplessResponse(
            responseType: .INTERNET_ERR,
            response: json,
            statusCode: 5002
        )
    }
    
    internal static func createUnauthorizedResponse(
        errorCode: String = "401",
        errorMessage: String = "UnAuthorized request! Please check your appId."
    ) -> OtplessResponse {
        let json: [String: Any] = [
            "errorMessage": errorMessage,
            "errorCode": errorCode
        ]
        return OtplessResponse(
            responseType: .INITIATE,
            response: json,
            statusCode: 401
        )
    }
    
    internal static func createInactiveOAuthChannelError(channel: String) -> OtplessResponse {
        let details: [String: Any] = [
            "channelType": "\(channel) channel is not active. Please enable it from the OTPLESS Dashboard"
        ]
        let json: [String: Any] = [
            "errorCode": 4003,
            "errorMessage": "The request channel is incorrect, see details.",
            "details": details
        ]
        return OtplessResponse(
            responseType: .INITIATE,
            response: json,
            statusCode: 4003
        )
    }
    
    internal static func create2FAEnabledError() -> OtplessResponse {
        let json: [String: Any] = [
            "errorCode": "4001",
            "errorMessage": "OTPless headless SDK doesn't support 2FA as of now."
        ]
        return OtplessResponse(
            responseType: .INITIATE,
            response: json,
            statusCode: 4001
        )
    }
    
    internal static func createInvalidRequestError(
        request: OtplessRequest?,
        details: [String: Any]? = nil,
        errorCode: String = "4000"
    ) -> OtplessResponse {
        var json: [String: Any] = [
            "errorCode": errorCode,
            "errorMessage": "The request values are incorrect, see details."
        ]
        
        if let request = request {
            var requestDetails: [String: String] = [:]
            if request.isPhoneAuth() && !request.isPhoneNumberWithCountryCodeValid() {
                requestDetails["phone"] = "Please enter a valid phone number"
            }
            if request.isEmailAuth(), !request.isEmailValid() {
                requestDetails["email"] = "Please enter a valid email address"
            }
            json["details"] = requestDetails
        } else {
            json["details"] = details
        }
        
        return OtplessResponse(
            responseType: .INITIATE,
            response: json,
            statusCode: 4000
        )
    }
    
    internal static func createSuccessfulInitiateResponse(
        requestId: String,
        channel: String,
        authType: String,
        deliveryChannel: String?
    ) -> OtplessResponse {
        var json: [String: Any] = [
            "requestId": requestId,
            "channel": channel,
            "authType": authType
        ]
        if let deliveryChannel = deliveryChannel, !deliveryChannel.isEmpty {
            json["deliveryChannel"] = deliveryChannel
        }
        return OtplessResponse(
            responseType: .INITIATE,
            response: json,
            statusCode: 200
        )
    }
    
    internal static func createUnsupportedIOSVersionResponse(
        forFeature feature: String,
        supportedFrom: String
    ) -> OtplessResponse {
        let response = [
            "errorMessage": "\(feature.replacingOccurrences(of: " ", with: "_").lowercased()) not supported because it requires iOS version \(supportedFrom) and above.",
            "errorCode": "5900"
        ]
        
        return OtplessResponse(responseType: .INITIATE, response: response, statusCode: 5900)
    }
    
    public func toString() -> String {
        return """
        Status Code: \(statusCode)\n
        ReponseType: \(responseType)\n
        Response: \(response ?? [:])
        """
    }
}
