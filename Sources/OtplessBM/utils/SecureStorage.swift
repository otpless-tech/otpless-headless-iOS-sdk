//
//  SecureStorageError.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//


import Foundation
import Security

internal final class SecureStorage: @unchecked Sendable {
    static let shared = SecureStorage()
    private let service = "com.otpless.bmum.secure"
    
    func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else {
            return
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        SecItemDelete(query as CFDictionary) // Delete before adding a new entry
        SecItemAdd(query as CFDictionary, nil)
    }
    
    func retrieve(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            return nil
        }
        
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return value
    }
    
    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return
        }
    }
    
    func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
    
    func saveToUserDefaults<T>(key: String, value: T) {
        UserDefaults.standard.set(value, forKey: key)
        UserDefaults.standard.synchronize()
    }
    
    func getFromUserDefaults<T>(key: String, defaultValue: T) -> T {
        return UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
    }
    
    func deleteFromUserDefaults(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.synchronize()
    }
}
