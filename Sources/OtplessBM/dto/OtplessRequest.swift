//
//  File.swift
//  otpless-iOS-headless-sdk
//
//  Created by Sparsh on 16/01/25.
//

import Foundation

@objc public class OtplessRequest: NSObject, @unchecked Sendable {
    private var authenticationMedium: AuthenticationMedium?
    private var phoneNumber: String?
    private var email: String?
    private var otp: String?
    private var code: String?
    private var channelType: OtplessChannelType?
    private var countryCode: String?
    private var otpLength: String?
    private var expiry: String?
    private var deliveryChannel: String?
    private var locale: String?
    private var requestId: String?
    private var extras: [String: String]?
    private var oneTapValue: String?
    private var tid: String?
    
    public func set(phoneNumber: String, withCountryCode countryCode: String) {
        self.phoneNumber = phoneNumber
        self.countryCode = countryCode
        self.authenticationMedium = .PHONE
        self.email = nil
    }
    
    public func set(email: String) {
        self.email = email
        self.authenticationMedium = .EMAIL
        self.phoneNumber = nil
        self.countryCode = nil
    }
    
    public func set(channelType: OtplessChannelType) {
        self.channelType = channelType
        self.authenticationMedium = .OAUTH
        self.phoneNumber = nil
        self.countryCode = nil
        self.email = nil
    }
    
    public func set(requestIdForWebAuthn requestId: String) {
        self.requestId = requestId
        self.authenticationMedium = .WEB_AUTHN
    }
    
    public func set(otp: String) {
        self.otp = otp
    }
    
    public func set(otpExpiry: String) {
        self.expiry = otpExpiry
    }
    
    public func set(otpLength: String) {
        self.otpLength = otpLength
    }
    
    public func set(deliveryChannelForTransaction deliveryChannel: String) {
        self.deliveryChannel = deliveryChannel
    }
    
    public func set(locale: String) {
        self.locale = locale
    }
    
    public func set(code: String) {
        self.code = code
    }
    
    public func set(extras: [String: String]) {
        self.extras = extras
    }
    
    public func set(tid: String) {
        self.tid = tid
    }
    
    public func getRequestId() -> String {
        return self.requestId ?? ""
    }
}

/// All the internal functions to be placed here
internal extension OtplessRequest {
    
    func set(oneTapValue: String) {
        self.oneTapValue = oneTapValue
    }
    
    func getDictForIntent() -> [String: String?] {
        if let oneTapValue = oneTapValue {
            return [
                "value": oneTapValue,
                RequestKeys.channelKey: "ONETAP",
                RequestKeys.typeKey: RequestKeys.buttonValue
            ]
        }
        
        var requestDict: [String: String?] = [:]
        
        switch authenticationMedium {
        case .PHONE:
            requestDict[RequestKeys.valueKey] = self.phoneNumber
            requestDict[RequestKeys.countryCodeKey] = self.countryCode
            requestDict[RequestKeys.mobileKey] = (countryCode?.trimmingCharacters(in: .init(charactersIn: "+")) ?? "") + (self.phoneNumber ?? "")
            requestDict[RequestKeys.identifierTypeKey] = RequestKeys.mobileValue
            requestDict[RequestKeys.typeKey] = RequestKeys.inputValue
            break
        case .EMAIL:
            requestDict[RequestKeys.emailKey] = self.email
            requestDict[RequestKeys.valueKey] = self.email
            
            requestDict[RequestKeys.identifierTypeKey] = RequestKeys.emailValue
            requestDict[RequestKeys.typeKey] = RequestKeys.inputValue
            break
        case .OAUTH:
            requestDict[RequestKeys.channelKey] = self.channelType?.rawValue
            requestDict[RequestKeys.typeKey] = RequestKeys.buttonValue
            requestDict[RequestKeys.valueKey] = ""
            
            if self.channelType == .WHATSAPP || self.channelType == .TRUE_CALLER{
                requestDict[RequestKeys.identifierTypeKey] = RequestKeys.mobileValue
            } else {
                requestDict[RequestKeys.identifierTypeKey] = RequestKeys.emailValue
            }
            break
        case .WEB_AUTHN:
            requestDict[RequestKeys.requestIdKey] = self.requestId
            requestDict[RequestKeys.channelKey] = RequestKeys.deviceValue
            requestDict[RequestKeys.typeKey] = RequestKeys.buttonValue
            break
        case nil:
            break
        }
        
        if let otp = otp {
            requestDict[RequestKeys.otpKey] = otp
        }
        if let code = code {
            requestDict[RequestKeys.codeKey] = code
        }
        if let otpLength = otpLength {
            requestDict[RequestKeys.otpLengthKey] = otpLength
        }
        if let deliveryChannel = deliveryChannel {
            requestDict[RequestKeys.deliveryChannelKey] = deliveryChannel
        }
        if let expiry = expiry {
            requestDict[RequestKeys.expiryKey] = expiry
        }
        if let locale = locale {
            requestDict[RequestKeys.localeKey] = locale
        }
        if let tid = tid {
            requestDict[RequestKeys.tidKey] = tid
        }
        
        for (key, value) in extras ?? [:] {
            requestDict[key] = value
        }
        
        return requestDict
    }
    
    func isCustomRequest() -> Bool {
        return self.deliveryChannel != nil || self.expiry != nil || self.otpLength != nil
    }
    
    func getAuthenticationMedium() -> AuthenticationMedium? {
        return self.authenticationMedium
    }
    
    func isPhoneAuth() -> Bool {
        if (phoneNumber != nil && countryCode != nil) {
            return true
        }
        if (channelType == OtplessChannelType.TRUE_CALLER || channelType == OtplessChannelType.WHATSAPP) {
            return true
        }
        return false
    }
    
    func isEmailAuth() -> Bool {
        return email != nil
    }
    
    func getQueryParams() -> [String: String] {
        var queryParams = [String: String]()
        
        if let otp = self.otp {
            queryParams["otp"] = otp
        }
        
        if let mobile = self.phoneNumber {
            queryParams["mobile"] = mobile
            queryParams["selectedCountryCode"] = self.countryCode?.replacingOccurrences(of: "+", with: "") ?? ""
            queryParams["value"] = (self.countryCode?.replacingOccurrences(of: "+", with: "") ?? "") + (self.phoneNumber ?? "nil_num")
        } else {
            queryParams["email"] = self.email ?? ""
            queryParams["value"] = self.email ?? ""
        }
        
        return queryParams
    }
    
    func isEmailValid() -> Bool {
        guard let email = self.email, !email.isEmpty else {
            return false
        }
        let emailRegex = "^[A-Za-z0-9+_.-]+@[A-Za-z0-9.-]+$"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
    
    func isPhoneNumberWithCountryCodeValid() -> Bool {
        guard let phoneNumber = self.phoneNumber, !phoneNumber.isEmpty else {
            return false
        }
        guard let countryCode = self.countryCode, !countryCode.isEmpty else {
            return false
        }
        
        // Check if the phone number starts with the country code
        let fullPhoneNumber = countryCode.replacingOccurrences(of: "+", with: "") + phoneNumber
        let phoneNumberRegex = "^[0-9]+$"  // Basic check for numeric characters only
        let phoneNumberPredicate = NSPredicate(format: "SELF MATCHES %@", phoneNumberRegex)
        
        return phoneNumberPredicate.evaluate(with: fullPhoneNumber)
    }
    
    func getRequestId() -> String? {
        return self.requestId
    }
    
    func getSelectedChannelType() -> OtplessChannelType? {
        return self.channelType
    }
    
    func isIntentRequest() -> Bool {
        return otp == nil
    }
    
    func hasOtp() -> Bool {
        return self.otp != nil && (self.otp?.count ?? 0) > 0
    }
    
    func getEmail() -> String? {
        return self.email
    }
    
    func getPhone() -> String? {
        return self.phoneNumber
    }
    
    func getCountryCode() -> String? {
        return self.countryCode
    }
    
    func getEventDict() -> [String: String] {
        var requestJson = [String: String]()
        requestJson["channel"] = authenticationMedium?.rawValue ?? ""
        
        if let phoneNumber = phoneNumber {
            requestJson["phone"] = phoneNumber
        }
        
        switch authenticationMedium {
        case .PHONE:
            if let phoneNumber = phoneNumber,
               let countryCode = countryCode
            {
                requestJson["phone"] = phoneNumber
                requestJson["countryCode"] = countryCode
            }
            break
            
        case .EMAIL:
            if let email = email {
                requestJson["email"] = email
            }
            break
            
        case .OAUTH:
            if let channelType = channelType {
                requestJson["channelType"] = channelType.rawValue
            }
            break
            
        default:
            break
        }
        
        if let otp = otp {
            requestJson["otp"] = otp
        }
        
        if let code = code {
            requestJson["code"] = code
        }
        
        if let otpLength = otpLength {
            requestJson["otpLength"] = otpLength
        }
        
        if let expiry = expiry {
            requestJson["expiry"] = expiry
        }
        
        if let deliveryChannel = deliveryChannel {
            requestJson["deliveryChannel"] = deliveryChannel
        }
        
        if let locale = locale {
            requestJson["locale"] = locale
        }
        
        return requestJson
    }
    
    func getOtpLength() -> Int {
        switch self.otpLength {
        case "4":
            return 4
        case "6":
            return 6
        default:
            return -1
        }
    }
    
}

internal struct RequestKeys {
    static let mobileKey = "mobile"
    static let countryCodeKey = "countryCode"
    static let emailKey = "email"
    static let identifierTypeKey = "identifierType"
    static let typeKey = "type"
    static let channelKey = "channel"
    static let requestIdKey = "requestId"
    static let otpKey = "otp"
    static let codeKey = "code"
    static let otpLengthKey = "otpLength"
    static let expiryKey = "expiry"
    static let deliveryChannelKey = "deliveryChannel"
    static let localeKey = "locale"
    static let valueKey = "value"
    static let tidKey = "tid"
    
    // Values
    static let mobileValue = "MOBILE"
    static let emailValue = "EMAIL"
    static let inputValue = "INPUT"
    static let buttonValue = "BUTTON"
    static let deviceValue = "DEVICE"
}

