//
//  Constants.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//


internal struct Constants {
    // MARK: - Keychain & UserDefault keys
    static let STATE_KEY = "otpless_bm_state"
    static let INID_KEY = "otpless_bm_inid"
    static let UID_KEY = "otpless_bm_uid"
    
    // MARK: - Transaction Status
    static let SUCCESS = "SUCCESS"
    static let PENDING = "PENDING"
    static let FAILED = "FAILED"
    
    static let SDK_VERSION = "2.0.4"
}
