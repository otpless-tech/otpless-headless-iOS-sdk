//
//  Utility.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//

import SystemConfiguration
import Foundation

final internal class Utils {
    
    /// Convert base64Url to base64.
    ///
    /// - parameter string: Base64Url String that has to be converted into base64.
    /// - returns: A string that is base64 encoded.
    static func convertBase64UrlToBase64(base64Url: String) -> String {
        var base64 = base64Url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        if base64.count % 4 != 0 {
            base64.append(String(repeating: "=", count: 4 - base64.count % 4))
        }
        
        return base64
    }
    
    /// Converts String to base64Url
    ///
    /// - parameter string: Base64 String that has to be converted into base64Url.
    /// - returns: A string that is base64Url encoded.
    static func base64UrlEncode(base64String: String) -> String {
        // Replace characters to make it URL-safe
        var base64UrlString = base64String
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        
        // Remove padding characters
        base64UrlString = base64UrlString.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        
        return base64UrlString
    }
    
    /// Fetches SNA URLs on which we make request while performing SNA.
    ///
    /// - returns: An array of URLs on which we make request.
    static func getSNAPreLoadingURLs() -> [String] {
        return [
            "https://in.safr.sekuramobile.com/v1/.well-known/jwks.json",
            "https://partnerapi.jio.com",
            "http://80.in.safr.sekuramobile.com"
        ]
    }
    
    static func formatCurrentTimeToDateString() -> String {
        let currentEpoch = Date().timeIntervalSince1970
        let date = Date(timeIntervalSince1970: currentEpoch)
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.locale = Locale(identifier: "en_IN")
        
        return dateFormatter.string(from: date)
    }
    
    static func convertDictionaryToString(_ dictionary: [String: Any], options: JSONSerialization.WritingOptions = .prettyPrinted) -> String {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: dictionary, options: options)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
        } catch {
            return ("Error converting dictionary to JSON string: \(error)")
        }
        
        return ""
    }
    
    static func createErrorDictionary(errorCode: String, errorMessage: String) -> [String: String] {
        return [
            "errorCode": errorCode,
            "errorMessage": errorMessage
        ]
    }
    
    static func convertStringToDictionary(_ text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8) {
            do {
                return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            } catch {
                
            }
        }
        return nil
    }
    
    static func convertToEventParamsJson(
        otplessResponse: OtplessResponse?,
        callback: @escaping (
            [String: String],
            _ requestId: String?,
            _ musId: String?
        ) -> Void
    ) {
        var eventParam = [String: String]()
        var requestId: String? = nil
        var musId: String? = nil
        
        var response = [String: String]()
        
        if otplessResponse == nil {
            response["statusCode"] = "-1"
            response["responseType"] = "null"
            response["response"] = "{}"
            callback(response, nil, nil)
            return
        }
        
        response["statusCode"] = "\(otplessResponse?.statusCode ?? -1)"
        response["responseType"] = otplessResponse?.responseType.rawValue ?? "null"
        
        if otplessResponse?.statusCode != 200 {
            if let responseBody = otplessResponse?.response {
                response["response"] = "\(responseBody)"
            } else {
                response["response"] = "{}"
            }
        } else {
            if let dataJson = otplessResponse?.response?["data"] as? [String: Any] {
                requestId = dataJson["token"] as? String
                musId = dataJson["userId"] as? String
            } else {
                response["response"] = "{}"
            }
        }
        
        // Convert response dictionary to JSON string
        if let jsonData = try? JSONSerialization.data(withJSONObject: response, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            eventParam["response"] = jsonString
        }
        
        callback(eventParam, requestId, musId)
    }
    
}
