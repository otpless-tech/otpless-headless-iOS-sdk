//
//  DeviceInfoUtils.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//

import Foundation
import UIKit
import Foundation
import CommonCrypto
import WebKit

@MainActor
class DeviceInfoUtils : @unchecked Sendable {
    static let shared: DeviceInfoUtils = {
        let instance = DeviceInfoUtils()
        return instance
    }()
    public var isIntialised = false
    public var hasWhatsApp : Bool = false
    public var hasGmailInstalled : Bool = false
    public var hasOTPLESSInstalled : Bool = false
    public var appHash = ""
    private var inid: String?
    private var tsid: String?
    private var deviceInfo: [String: String]? = nil
    
    func initialise () {
        if (!isIntialised){
            hasWhatsApp = isWhatsappInstalled()
            hasGmailInstalled = isGmailInstalled()
            hasOTPLESSInstalled = isOTPLESSInstalled()
            appHash = getAppHash() ?? "noapphash"
            isIntialised = true
            generateTrackingId()
        }
    }

    func getAppHash() -> String? {
        if let executablePath = Bundle.main.executablePath {
            let fileURL = URL(fileURLWithPath: executablePath)
            if let fileData = try? Data(contentsOf: fileURL) {
                var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
                fileData.withUnsafeBytes {
                    _ = CC_SHA256($0.baseAddress, CC_LONG(fileData.count), &hash)
                }
                let hashData = Data(hash)
                let hashString = hashData.map { String(format: "%02hhx", $0) }.joined()
                return hashString
            }
        }
        return nil
    }

    func isWhatsappInstalled() -> Bool{
        if UIApplication.shared.canOpenURL(URL(string: "whatsapp://")! as URL) {
            return true
        } else {
            return false
        }
    }
    
    func isGmailInstalled() -> Bool{
        if UIApplication.shared.canOpenURL(URL(string: "googlegmail://")! as URL) {
            return true
        } else {
            return false
        }
    }
    func isOTPLESSInstalled() -> Bool{
        if (UIApplication.shared.canOpenURL(URL(string: "com.otpless.ios.app.otpless://")! as URL)){
            return true
        } else {
            return false
        }
    }
    
    func getAppInfo() -> [String: String] {
        initialise()
        var udid : String!
        var appVersion : String!
        var manufacturer : String!
        var model : String!
        var params = [String: String]()
        
        let bundleIdentifier = Bundle.main.bundleIdentifier
        if let pName = bundleIdentifier {
            Otpless.shared.setPackageName(pName)
        }
        
        model = UIDevice.modelName
        manufacturer = "Apple"
        if let app_version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            appVersion = app_version
        }
        if let _udid = UIDevice.current.identifierForVendor?.uuidString as String? {
            udid = _udid
        }
        let os = ProcessInfo().operatingSystemVersion
        
        if udid != nil{
            params["deviceId"] = udid
        }
        if appVersion != nil{
            params["appVersion"] = appVersion
        }
        if manufacturer != nil{
            params["manufacturer"] = manufacturer
        }
        if model != nil {
            params["model"] = model
        }
        if inid != nil {
            params["inid"] = inid
        }
        if tsid != nil {
            params["tsid"] = tsid
        }
        
        params["sdkVersion"] = "1.1.3"
        
        params["osVersion"] = os.majorVersion.description + "." + os.minorVersion.description
        params["hasWhatsapp"] = hasWhatsApp.description
        params["hasOtplessApp"] = hasOTPLESSInstalled.description
        params["hasGmailApp"] = hasGmailInstalled.description
        
        if #available(iOS 12.0, *) {
            params["isSilentAuthSupported"] = "true"
        } 
        
        if #available(iOS 16.0, *) {
            params["isWebAuthnSupported"] = "true"
        }
        
        if let teamId = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String {
            params["appleTeamId"] = teamId
        }
        
        params["isDeviceSimulator"] = "\(isDeviceSimulator())"
        
        return params
    }
    
    func generateTrackingId() {
        if let savedInid: String = SecureStorage.shared.getFromUserDefaults(key: Constants.INID_KEY, defaultValue: "") {
            self.inid = savedInid
        } else {
            inid = generateId(withTimeStamp: true)
            SecureStorage.shared.saveToUserDefaults(key: Constants.INID_KEY, value: inid!)
        }
        
        if tsid == nil {
            tsid = generateId(withTimeStamp: true)
        }
    }
    
    private func generateId(withTimeStamp: Bool) -> String {
        let uuid = UUID().uuidString
        if !withTimeStamp {
            return uuid
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let uniqueString = "\(uuid)-\(timestamp)"
        return uniqueString
    }
    
    func getInstallationId() -> String? {
        if inid != nil {
            return inid
        }
        let savedInid: String = SecureStorage.shared.getFromUserDefaults(key: Constants.INID_KEY, defaultValue: "")
        return savedInid
    }
    
    func getTrackingSessionId() -> String? {
        return tsid
    }

    func getDeviceInfoDict() -> [String: String] {
        if let deviceInfo = deviceInfo {
            return deviceInfo
        }
        
        let os = ProcessInfo().operatingSystemVersion
        let device = UIDevice.current
        
        let screenWidth = String(Int(UIScreen.main.bounds.width))
        let screenHeight = String(Int(UIScreen.main.bounds.height))
        let userAgent = WKWebView().value(forKey: "userAgent") as? String
        var nonNullUserAgent: String = "otplesssdk"
        if let userAgent = userAgent {
            nonNullUserAgent = userAgent.replacingOccurrences(of: "\"", with: "\\\"") + " otplesssdk"
        }
        
        let deviceInfo = [
            "platform": "iOS",
            "vendor": "Apple",
            "device": device.name,
            "model": UIDevice.modelName,
            "iOS_version": os.majorVersion.description + "." + os.minorVersion.description,
            "product": device.systemName,
            "hardware": hardwareString(),
            "screenHeight": screenHeight,
            "screenWidth": screenWidth,
            "userAgent":  nonNullUserAgent
        ]
        
        self.deviceInfo = deviceInfo
        return deviceInfo
    }

    
    private func hardwareString() -> String {
          var systemInfo = utsname()
          uname(&systemInfo)
          return String(bytes: Data(bytes: &systemInfo.machine, count: Int(_SYS_NAMELEN)), encoding: .utf8)?
              .trimmingCharacters(in: .controlCharacters) ?? "Unknown"
      }
    
    /// Determines whether the device is simulator.
    ///
    /// - returns: Boolean indicating whether device is simulator or not. Returns true if the device is simulator, else false.
    func isDeviceSimulator() -> Bool {
        #if swift(>=4.1)
            #if targetEnvironment(simulator)
                return true
            #else
                return false
            #endif
        #else
            #if (arch(i386) || arch(x86_64)) && os(iOS)
                return true
            #else
                return false
            #endif
        #endif
    }
}

extension UIDevice {
    static var modelName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            buffer.compactMap { $0 == 0 ? nil : String(UnicodeScalar(UInt8($0))) }.joined()
        }
        return identifier
    }
}

