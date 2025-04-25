//
//  DeviceIDRequestBody.swift
//  OtplessBM
//
//  Created by Sparsh on 25/04/25.
//

import Foundation


struct DeviceIDRequestBody {
    let metadata: String
    let device: [String: Any]

    init() {
        let appInfoString = Utils.convertDictionaryToString(Otpless.shared.appInfo)
        let deviceInfo = Otpless.shared.deviceInfo
        let deviceInfoString = Utils.convertDictionaryToString(deviceInfo)

        let metadataDict: [String: String] = [
            "appInfo": appInfoString,
            "deviceInfo": deviceInfoString
        ]
        self.metadata = Utils.convertDictionaryToString(metadataDict)
        self.device = deviceInfo
    }

    func toDict() -> [String: Any] {
        return [
            "metadata": metadata,
            "device": device
        ]
    }
}
