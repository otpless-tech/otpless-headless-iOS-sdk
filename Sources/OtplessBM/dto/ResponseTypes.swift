//
//  class.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//


public enum ResponseTypes: String {
    case INITIATE,
         VERIFY,
         ONETAP,
         FALLBACK_TRIGGERED,
         FAILED,
         SDK_READY
}
