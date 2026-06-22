//
//  OtplessBMEvents.swift
//  OtplessBM
//
//  Facade over OtplessEventIO — mirrors Android LongClawEvents.kt.
//

import Foundation
import OtplessEventIO

internal enum OtplessBMEvents {

    fileprivate static func trackEvent(
        name: String,
        type: EventType,
        action: EventAction,
        url: String? = nil,
        statusCode: Int? = nil,
        data: [String: Any]? = nil,
        requestId: String? = nil,
        errorCode: String? = nil
    ) {
        let token = Otpless.shared.token.isEmpty ? nil : Otpless.shared.token
        let asId = Otpless.shared.asId.isEmpty ? nil : Otpless.shared.asId
        OtplessEventIO.push(
            OtplessTrackEvent(
                eventType: type,
                action: action,
                eventName: name,
                url: url,
                statusCode: statusCode,
                data: data,
                requestId: requestId,
                errorCode: errorCode,
                token: token,
                asId: asId
            )
        )
    }

    // MARK: - Init

    enum Init {
        private static let INIT_CALLED = "sdk_init_called"
        private static let STATE_FROM_CACHE = "sdk_init_state_from_cache"
        private static let STATE_READY = "sdk_init_state_ready"
        private static let STATE_FAILED = "sdk_init_state_failed"

        static func initCalled(hasApiBaseUrlOverride: Bool) {
            trackEvent(
                name: INIT_CALLED,
                type: .CLIENT_TO_SDK,
                action: .REQUEST,
                data: ["hasApiBaseUrlOverride": hasApiBaseUrlOverride]
            )
        }

        static func stateFromCache() {
            trackEvent(name: STATE_FROM_CACHE, type: .SDK, action: .RESPONSE)
        }

        static func stateReady(isAuthRetry: Bool = false) {
            trackEvent(
                name: STATE_READY,
                type: .SDK,
                action: .RESPONSE,
                statusCode: 200,
                data: isAuthRetry ? ["isAuthRetry": true] : nil
            )
        }

        static func stateFailed(isAuthRetry: Bool = false) {
            trackEvent(
                name: STATE_FAILED,
                type: .SDK,
                action: .RESPONSE,
                data: isAuthRetry ? ["isAuthRetry": true] : nil,
                errorCode: "5003"
            )
        }
    }

    // MARK: - Auth

    enum Auth {
        private static let START_CALLED = "sdk_start_called"
        private static let CALLBACK_SET = "sdk_set_callback"

        static func startCalled(request: OtplessRequest) {
            var data: [String: Any] = [:]
            for (k, v) in request.getEventDict() { data[k] = v }
            data["isMobileDataActive"] = Otpless.shared.isMobileDataEnabled
            trackEvent(name: START_CALLED, type: .CLIENT_TO_SDK, action: .REQUEST, data: data)
        }

        static func callbackSet() {
            trackEvent(name: CALLBACK_SET, type: .CLIENT_TO_SDK, action: .REQUEST)
        }
    }

    // MARK: - Sna

    enum Sna {
        private static let STARTED = "sna_started"
        private static let STATUS_CHECK_STARTED = "sna_status_check_started"
        private static let REDIRECTED = "sna_redirected"
        private static let RESPONSE = "sna_response"
        private static let INIT_TERMINAL = "sna_init_terminal_response"
        private static let AUTH_TERMINAL = "sna_auth_terminal_response"

        static func statusCheckStarted(isMfaEnabled: Bool) {
            trackEvent(
                name: STATUS_CHECK_STARTED,
                type: .SDK,
                action: .REQUEST,
                data: ["isMfaEnabled": isMfaEnabled]
            )
        }

        static func started(url: String) {
            trackEvent(name: STARTED, type: .SDK, action: .REQUEST, url: url)
        }

        static func redirected(location: String, statusCode: Int) {
            trackEvent(
                name: REDIRECTED,
                type: .SDK,
                action: .RESPONSE,
                statusCode: statusCode,
                data: ["location": location]
            )
        }

        static func response(statusCode: Int, body: [String: Any]? = nil) {
            trackEvent(
                name: RESPONSE,
                type: .SDK,
                action: .RESPONSE,
                statusCode: statusCode,
                data: body
            )
        }

        static func initTerminal() {
            trackEvent(name: INIT_TERMINAL, type: .SDK, action: .RESPONSE)
        }

        static func authTerminal() {
            trackEvent(name: AUTH_TERMINAL, type: .SDK, action: .RESPONSE)
        }
    }

    // MARK: - Api

    enum Api {
        private static let STATE = "api_state"
        private static let INTENT = "api_intent"
        private static let TRANSACTION_STATUS = "api_transaction_status"
        private static let SNA_STATUS = "api_sna_status"
        private static let MFA_SNA_STATUS = "api_mfa_sna_status"
        private static let VERIFY_OTP = "api_verify_otp"
        private static let UNKNOWN = "api_unknown"
        private static let TRANSACTION_STATUS_CHECK_STARTED = "transaction_status_check_started"
        private static let RESPONSE_ERROR = "api_response_error"

        private static func nameFromPath(_ path: String) -> String {
            let p = path
            if p.contains(ApiManager.GET_STATE_PATH.replacingOccurrences(of: "{state}", with: "")) { return STATE }
            if p.contains(ApiManager.SNA_TRANSACTION_STATUS_PATH.replacingOccurrences(of: "{state}", with: "")) { return SNA_STATUS }
            if p.contains(ApiManager.MFA_SNA_STATUS_PATH.replacingOccurrences(of: "{state}", with: "")) { return MFA_SNA_STATUS }
            if p.contains(ApiManager.TRANSACTION_STATUS_PATH.replacingOccurrences(of: "{state}", with: "")) { return TRANSACTION_STATUS }
            if p.contains(ApiManager.POST_INTENT_PATH.replacingOccurrences(of: "{state}", with: "")) { return INTENT }
            if p.contains(ApiManager.OTP_VERIFICATION_PATH.replacingOccurrences(of: "{state}", with: "")) { return VERIFY_OTP }
            return UNKNOWN
        }

        static func transactionStatusCheckStarted() {
            trackEvent(name: TRANSACTION_STATUS_CHECK_STARTED, type: .SDK, action: .REQUEST)
        }

        static func request(path: String, data: [String: Any]? = nil) {
            trackEvent(
                name: nameFromPath(path),
                type: .SDK_TO_OTPLESS,
                action: .REQUEST,
                url: path,
                data: data
            )
        }

        static func response(
            path: String,
            statusCode: Int,
            errorCode: String? = nil,
            data: [String: Any]? = nil,
            xRequestId: String? = nil
        ) {
            trackEvent(
                name: nameFromPath(path),
                type: .SDK_TO_OTPLESS,
                action: .RESPONSE,
                url: path,
                statusCode: statusCode,
                data: data,
                requestId: xRequestId,
                errorCode: errorCode
            )
        }

        static func errorResponse(
            path: String,
            method: String,
            statusCode: Int?,
            xRequestId: String?
        ) {
            trackEvent(
                name: RESPONSE_ERROR,
                type: .SDK_TO_OTPLESS,
                action: .RESPONSE,
                url: path,
                statusCode: statusCode,
                data: ["method": method],
                requestId: xRequestId
            )
        }
    }

    // MARK: - Response

    enum Response {
        private static let NOT_DELIVERED = "sdk_response_not_delivered"
        static let REASON_CALLBACK_NOT_SET = "callback_not_initialized"
        static let REASON_LEGACY_SILENT_AUTH = "legacy_mode_silent_auth"
        static let REASON_STATUS_CODE_SUPPRESSED = "status_code_suppressed"

        static func delivered(_ response: OtplessResponse) {
            let name = "sdk_response_\(response.responseType.rawValue.lowercased())"
            let errorCode: String?
            switch response.responseType {
            case .VERIFY:
                errorCode = response.response?["errorCode"] as? String
            case .INITIATE:
                errorCode = response.statusCode != 200 ? response.response?["errorCode"] as? String : nil
            default:
                errorCode = nil
            }
            let data: [String: Any]? = (response.responseType != .ONETAP) ? response.response : nil
            trackEvent(
                name: name,
                type: .CLIENT_TO_SDK,
                action: .RESPONSE,
                statusCode: response.statusCode,
                data: data,
                errorCode: errorCode
            )
        }

        static func notDelivered(_ response: OtplessResponse, reason: String) {
            trackEvent(
                name: NOT_DELIVERED,
                type: .CLIENT_TO_SDK,
                action: .RESPONSE,
                statusCode: response.statusCode,
                data: [
                    "responseType": response.responseType.rawValue,
                    "reason": reason
                ]
            )
        }
    }

    // MARK: - Commit

    enum Commit {
        private static let MERCHANT_COMMIT = "merchant_response_commit"

        static func merchantCommit(_ response: OtplessResponse?) {
            var data: [String: Any] = [:]
            data["responseType"] = response?.responseType.rawValue ?? "null"
            if let sc = response?.statusCode { data["statusCode"] = sc }
            if let payload = response?.response {
                for (k, v) in payload { data[k] = v }
            }
            trackEvent(
                name: MERCHANT_COMMIT,
                type: .CLIENT_TO_SDK,
                action: .REQUEST,
                statusCode: response?.statusCode,
                data: data.isEmpty ? nil : data
            )
        }
    }

    // MARK: - Exception

    enum Exception {
        private static let CAPTURED = "sdk_exception"

        static func captured(where location: String, message: String? = nil) {
            var data: [String: Any] = ["where": location]
            if let message = message { data["message"] = message }
            trackEvent(
                name: CAPTURED,
                type: .SDK,
                action: .RESPONSE,
                data: data
            )
        }
    }

    // MARK: - Device

    enum Device {
        static func pushDeviceEvent() {
            let extras: [String: Any] = [
                "isMobileDataActive": Otpless.shared.isMobileDataEnabled,
                "deviceInfo": Otpless.shared.deviceInfo
            ]
            OtplessEventIO.pushDeviceEvent(
                sdkVersion: Constants.SDK_VERSION,
                platform: "otpless-headless(ios)",
                extras: extras
            )
        }
    }

    // MARK: - Intelligence

    enum Intelligence {
        private static let START = "intel_auth_start"
        private static let RESULT = "intel_auth_result"
        private static let ERROR = "intel_auth_error"
        private static let JOB_AWAITING = "intel_auth_job_awaiting"

        static func started(status: String, action description: String) {
            trackEvent(name: START, type: .SDK, action: .RESPONSE,
                       data: ["status": status, "action": description])
        }

        static func result(status: String, action description: String) {
            trackEvent(name: RESULT, type: .SDK, action: .RESPONSE,
                       data: ["status": status, "action": description])
        }

        static func error(status: String, action description: String) {
            trackEvent(name: ERROR, type: .SDK, action: .RESPONSE,
                       data: ["status": status, "action": description])
        }

        static func jobAwaiting(isSyncType: Bool, isCompleted: Bool, isIntelligenceInit: Bool) {
            trackEvent(
                name: JOB_AWAITING,
                type: .SDK,
                action: .RESPONSE,
                data: [
                    "isSyncType": isSyncType,
                    "isCompleted": isCompleted,
                    "isIntelligenceInit": isIntelligenceInit
                ]
            )
        }
    }

    // MARK: - UserAuth

    enum UserAuth {
        static func authEvent(
            event: AuthEvent,
            fallback: Bool,
            providerType: ProviderType,
            providerInfo: [String: String]
        ) {
            var data: [String: Any] = [
                "fallback": String(fallback),
                "providerType": providerType.nativeName
            ]
            if !providerInfo.isEmpty {
                data["providerInfo"] = providerInfo
            }
            trackEvent(
                name: event.nativeName,
                type: .CLIENT,
                action: .REQUEST,
                data: data
            )
        }
    }
}
