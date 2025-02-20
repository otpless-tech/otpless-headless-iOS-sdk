//
//  Logger.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//

import Foundation
import os

func log(message: String, type: LogType) {
    if type != .API_REQUEST_AND_RESPONSE {
        print("\n\n" + message + "\n\n")
    }
    DispatchQueue.main.async {
        Otpless.shared.loggerDelegate?.log(message: message, type: type)
    }
}

func log(error: Error, type: LogType) {
    if let urlError = error as? URLError {
        log(message: "StatusCode: \(urlError.errorCode)\nError: \(urlError.errorUserInfo)", type: type)
    } else {
        log(message: error.localizedDescription, type: type)
    }
}

public enum LogType: String, @unchecked Sendable {
    
    case API_RESPONSE_FAILURE = "API RESPONSE FAILURE"
    case CLASS_DEALLOC_IN_CLOSURE = "CLASSES DEALLOC IN CLOSURE"
    case API_REQUEST_AND_RESPONSE = "API REQUEST AND RESPONSE"
    case IS_PASSKEY_SUPPORTED = "Is Passkey Supported on Device"
    case POLLING_STOPPED = "Polling Stopped"
    case POLLING_STARTED = "Polling Started"
    case POLLING_RESPONSE = "Polling Response"
    case INVALID_DEEPLINK = "Invalid Deeplink"
    case SNA_RESPONSE = "SNA Response"
    case EVENT_API_ERROR = "EVENT API ERROR"
    
    public static func < (lhs: LogType, rhs: LogType) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

@MainActor
public protocol OtplessLoggerDelegate: NSObjectProtocol {
    func log(message: String, type: LogType)
}
