//
//  for.swift
//  OtplessBM
//
//  Created by Sparsh on 25/04/25.
//


/// This is the model struct for the request body required for verifying OTP.
struct VerifyOTPRequestBody: Codable {
    let isOTPAutoRead: String
    let mobile: String?
    let otp: String
    let email: String?
    
    func toDict() -> [String: Any] {
        return [
            "isOTPAutoRead": isOTPAutoRead,
            "mobile": mobile ?? "",
            "otp": otp,
            "email": email ?? ""
        ]
    }
}
