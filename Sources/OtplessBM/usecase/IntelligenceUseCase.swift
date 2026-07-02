//
//  IntelligenceUseCase.swift
//  OtplessBM
//
//  Runtime loader for the optional OTPlessIntelligence SDK. We deliberately
//  do NOT import OTPlessIntelligence anywhere in OtplessBM sources — the
//  SDK is discovered via NSClassFromString and its @objc fetch selector is
//  dispatched via Objective-C runtime primitives. Merchants who want
//  device intelligence add the OTPlessIntelligence pod / SPM package to
//  their own project AND call OTPlessIntelligence.shared.initialize(...)
//  themselves from their AppDelegate / App-struct init before triggering
//  any DI-enabled OtplessBM request. If init hasn't happened when we call
//  fetchIntelligence, the SDK's own guard returns success=false and this
//  use case's completion resolves to nil — the transaction proceeds
//  without DI.
//
//  Selector names are declared in the intelligence SDK's @objc(...)
//  attributes and must be kept in sync with releases of that SDK.
//

import Foundation
import os

internal final class IntelligenceUseCase {
    private static let className = "OTPlessIntelligence.OTPlessIntelligence"
    private static let sharedSelector = NSSelectorFromString("shared")
    private static let fetchSelector = NSSelectorFromString("fetchIntelligenceWithParams:updateInfo:completion:")

    @available(iOS 15.0, *)
    func fetchIntelligence(
        params: [String: String],
        updateInfo: [String: Any],
        completion: @escaping @Sendable (String?) -> Void
    ) {
        guard let shared = loadShared(),
              shared.responds(to: Self.fetchSelector)
        else {
            os_log("OTPLESS: OTPlessIntelligence not linked. Add pod 'OTPlessIntelligence' or the SPM package to enable device intelligence.")
            completion(nil)
            return
        }

        // Swift's NSObject.perform variants only accept up to 2 args; the
        // 3-arg fetch selector needs a typed IMP cast.
        typealias FetchIMP = @convention(c) (AnyObject, Selector, NSDictionary?, NSDictionary?, AnyObject) -> Void
        guard let imp = class_getMethodImplementation(type(of: shared), Self.fetchSelector) else {
            completion(nil)
            return
        }
        let fn = unsafeBitCast(imp, to: FetchIMP.self)

        let callback: @convention(block) (Bool, String?, NSDictionary?, String?) -> Void = { success, dfrId, _, errorMessage in
            if success, let dfrId = dfrId {
                OtplessBMEvents.Intelligence.fetchIntelligenceSuccess(dfrId: dfrId)
                completion(dfrId)
            } else {
                OtplessBMEvents.Intelligence.fetchIntelligenceFailure(message: errorMessage ?? "unknown")
                completion(nil)
            }
        }
        let callbackObj = unsafeBitCast(callback, to: AnyObject.self)

        fn(shared, Self.fetchSelector, params as NSDictionary, updateInfo as NSDictionary, callbackObj)
    }

    @available(iOS 15.0, *)
    private func loadShared() -> NSObject? {
        guard let cls = NSClassFromString(Self.className) as? NSObject.Type,
              cls.responds(to: Self.sharedSelector),
              let shared = cls.perform(Self.sharedSelector)?.takeUnretainedValue() as? NSObject
        else {
            return nil
        }
        return shared
    }
}
