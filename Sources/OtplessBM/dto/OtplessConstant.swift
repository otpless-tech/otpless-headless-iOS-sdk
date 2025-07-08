//
//  OtplessConstant.swift
//  OtplessBM
//
//  Created by Digvijay Singh on 07/07/25.
//

internal enum OtplessConstant {
    
    enum EC {
        static let SNA_AUTH_INIT_FAILED = 7160
        static let SNA_AUTH_FAILED = 7161
    }
    
    static let terminalErrorCodes: [String] = [
        String(EC.SNA_AUTH_INIT_FAILED),
        String(EC.SNA_AUTH_FAILED)
    ]
}
