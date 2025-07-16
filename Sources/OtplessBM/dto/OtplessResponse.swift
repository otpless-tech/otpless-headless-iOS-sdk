//
//  OtplessResponse.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//

public struct OtplessResponse: @unchecked Sendable {
    public let responseType: ResponseTypes
    public let response: [String: Any]?
    public let statusCode: Int
    
    public init(
      responseType: ResponseTypes,
      response: [String: Any]?,
      statusCode: Int
    ) {
      self.responseType = responseType
      self.response = response
      self.statusCode = statusCode
    }
    
    internal func toJsonString() -> String {
        var dict: [String: Any] = [
            "responseType": responseType.rawValue
        ]
        if let response = response {
            dict["response"] = response
        }
        dict["statusCode"] = statusCode
        return Utils.convertDictionaryToString(dict)
    }
    
    internal static let failedToInitializeResponse = OtplessResponse(responseType: .FAILED, response: [
        "errorCode": "5003",
        "errorMessage": "Failed to initialize the SDK"
    ], statusCode: 5003)
    
    internal static let sdkReady = OtplessResponse(responseType: .SDK_READY, response: ["success" : true], statusCode: 200)
    
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
        if Otpless.shared.otpLength != -1 && (channel == "OTP" || channel == "OTP_LINK") {
            json["otpLength"] = Otpless.shared.otpLength
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
    
    internal static func makeTerminalResponse(status statusCode: Int, error errorCode: String, message errorMessage: String) -> OtplessResponse {
        return OtplessResponse(responseType: .AUTH_TERMINATED, response: ["errorCode": errorCode, "errorMessage": errorMessage], statusCode: statusCode)
    }
    
    public func toString() -> String {
        return """
        Status Code: \(statusCode)\n
        ReponseType: \(responseType)\n
        Response: \(response ?? [:])
        """
    }
}
