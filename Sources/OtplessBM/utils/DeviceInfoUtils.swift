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

class DeviceInfoUtils : @unchecked Sendable {
    static let shared: DeviceInfoUtils = {
        let instance = DeviceInfoUtils()
        return instance
    }()
    public var isIntialised = false
    public var hasWhatsApp : Bool = false
    public var appHash = ""
    private var inid: String?
    private var tsid: String?
    private var deviceInfo: [String: String]? = nil
    
    func initialise () async {
        if isIntialised {
            return
        }
        hasWhatsApp = await isWhatsappInstalled()
        appHash = getAppHash() ?? "noapphash"
        generateTrackingId()
        isIntialised = true
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

    func isWhatsappInstalled() async -> Bool{
        await MainActor.run {
            if UIApplication.shared.canOpenURL(URL(string: "whatsapp://")! as URL) {
                return true
            } else {
                return false
            }
        }
    }
    
    
    func getAppInfo() async -> [String: String] {
        await initialise()
        var params = [String: String]()
        
        let bundleIdentifier = Bundle.main.bundleIdentifier
        if let pName = bundleIdentifier {
            Otpless.shared.setPackageName(pName)
        }
        let ui = await MainActor.run { () -> (model: String, udid: String?) in
            let model = UIDevice.modelName ?? "UNKNOWN"
            let udid = UIDevice.current.identifierForVendor?.uuidString as String?
            return (model, udid)
        }
        
    
        params["manufacturer"] = "Apple"
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            params["appVersion"] = appVersion
        }
        if ui.udid != nil{
            params["deviceId"] = ui.udid!
        }
        
        params["model"] = ui.model
        if inid != nil {
            params["inid"] = inid
        }
        params["tsid"] = getTrackingSessionId()
        params["sdkVersion"] = Constants.SDK_VERSION
        
        let os = ProcessInfo().operatingSystemVersion
        params["osVersion"] = os.majorVersion.description + "." + os.minorVersion.description
        params["hasWhatsapp"] = hasWhatsApp.description
        
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
            if let cls = NSClassFromString("OTPlessIntelligence.OTPlessIntelligence") as? NSObject.Type {
                let sharedSelector = NSSelectorFromString("shared")

                guard cls.responds(to: sharedSelector),
                      let sharedObj = cls.perform(sharedSelector)?.takeUnretainedValue() as? NSObject
                else {
                    return
                }

                let gettsIDSelector = NSSelectorFromString("gettsID")

                if sharedObj.responds(to: gettsIDSelector),
                   let tsidValue = sharedObj.perform(gettsIDSelector)?.takeUnretainedValue() as? String {
                    tsid = !tsidValue.isEmpty ? tsidValue : generateId(withTimeStamp: true)
                    return
                }
            }
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
    
    func getInstallationId() -> String {
        if inid != nil {
            return inid!
        }
        let savedInid: String = SecureStorage.shared.getFromUserDefaults(key: Constants.INID_KEY, defaultValue: "")
        return savedInid
    }
    
    func getTrackingSessionId() -> String {
        if self.tsid == nil {
            self.tsid = generateId(withTimeStamp: true)
        }
        return self.tsid!
    }

    @MainActor
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

