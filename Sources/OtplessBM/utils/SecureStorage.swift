//
//  SecureStorageError.swift
//  OtplessSDK
//
//  Created by Sparsh on 26/01/25.
//


import Foundation
import Security

/// Keychain operations behind SecureStorage, so tests (which run without a keychain entitlement) can swap in memory.
internal protocol KeychainStore: AnyObject {
    func save(key: String, value: String)
    func retrieve(key: String) -> String?
    func delete(key: String)
    func clearAll()
}

internal final class SystemKeychainStore: KeychainStore {
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
}

internal final class SecureStorage: @unchecked Sendable {
    static let shared = SecureStorage()
    /// Replaced only by tests.
    var keychain: KeychainStore = SystemKeychainStore()
    
    func save(key: String, value: String) {
        keychain.save(key: key, value: value)
    }
    
    func retrieve(key: String) -> String? {
        keychain.retrieve(key: key)
    }
    
    func delete(key: String) {
        keychain.delete(key: key)
    }
    
    func clearAll() {
        keychain.clearAll()
    }

    /// Keychain survives uninstall but UserDefaults don't, so a missing marker means a fresh install: drop every
    /// stale keychain item (state, uid, session, session state). Called from every SDK entry point before any read.
    func clearStaleDataOnFreshInstall() {
        guard !getFromUserDefaults(key: Constants.INSTALL_MARKER_KEY, defaultValue: false) else { return }
        log(message: "[Storage] Fresh install detected — clearing stale keychain data", type: .SDK_STATE_FETCH)
        clearAll()
        saveToUserDefaults(key: Constants.INSTALL_MARKER_KEY, value: true)
    }
    
    func saveToUserDefaults<T>(key: String, value: T) {
        UserDefaults.standard.set(value, forKey: key)
    }
    
    func getFromUserDefaults<T>(key: String, defaultValue: T) -> T {
        return UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
    }
}
