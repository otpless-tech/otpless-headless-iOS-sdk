import Foundation

// MARK: - Models (see outbound-sms-binding-sdk-contract.md)

internal struct SmsBindingStartRequest: Sendable {
    let msisdn: String
    let osVersion: String
    let appVersion: String
    let sdkVersion: String
    let deviceFingerprintHash: String?
    let rules: SmsBindingRules
    let previousAttemptId: String?
    let upiEntitlementDeclared: Bool
    let iccidTokenSupported: Bool

    func toDict() -> [String: Any] {
        var body: [String: Any] = [
            "msisdn": msisdn,
            // Not `platform`: the standard SDK body parameters already carry `platform: HEADLESS`
            // and overwrite a field of that name.
            "device_platform": "ios",
            "os_version": osVersion,
            "app_version": appVersion,
            "sdk_version": sdkVersion,
            "config_version": rules.configVersion,
            "rules_hash": rules.rulesHash,
            "capabilities": [
                "upi_entitlement": upiEntitlementDeclared,
                "iccid_token_supported": iccidTokenSupported
            ]
        ]
        if let deviceFingerprintHash { body["device_fp_hash"] = deviceFingerprintHash }
        if let previousAttemptId { body["previous_attempt_id"] = previousAttemptId }
        return body
    }
}

/// The token and VMN the backend issued for one attempt.
internal struct SmsBindingIssued: Equatable, Sendable {
    let attemptId: String
    let smsBody: String
    let vmn: String
    let ttlSeconds: Int
    let configVersion: Int
    let rulesHash: String
}

internal struct SmsBindingReport: Sendable {
    enum Event: String, Sendable { case sent = "SENT", failed = "FAILED", cancelled = "CANCELLED", aborted = "ABORTED" }

    struct IOS: Sendable {
        let composerResult: String
        let sendCompletion: Bool?
        let composerPresentedAt: Date
        let appRegainedControlAt: Date
        let returnSeconds: TimeInterval
        let iccidToken: String?
        /// `OK`, `NIL`, `UNSUPPORTED` or `NOT_REQUIRED`.
        let iccidTokenStatus: String
    }

    let event: Event
    let at: Date
    let reason: SmsBindingFailure?
    let ios: IOS?

    func toDict() -> [String: Any] {
        var body: [String: Any] = ["event": event.rawValue, "at": Self.iso(at)]
        if let reason { body["reason"] = reason.rawValue }
        if let ios {
            var fields: [String: Any] = [
                "composer_result": ios.composerResult,
                "composer_presented_at": Self.iso(ios.composerPresentedAt),
                "app_regained_control_at": Self.iso(ios.appRegainedControlAt),
                "return_seconds": ios.returnSeconds,
                "iccid_token_status": ios.iccidTokenStatus
            ]
            if let sendCompletion = ios.sendCompletion { fields["send_completion"] = sendCompletion }
            if let token = ios.iccidToken { fields["iccid_token"] = token }
            body["ios"] = fields
        }
        return body
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

internal struct SmsBindingVerdict: Equatable, Sendable {
    let state: SmsBindingState
    let reason: String?
    let bindingId: String?
    let stateVersion: Int
}

/// How a backend call failed. `rejected` is the backend saying no with a reason; `transport` is
/// everything else (network, timeout, undecodable response), which the caller may retry.
internal enum SmsBindingBackendError: Error, Equatable, Sendable {
    case rejected(SmsBindingFailure, retryAfterSeconds: Int?)
    case transport
}

// MARK: - Seam

internal protocol SmsBindingBackend: Sendable {
    func fetchRules(state: String) async throws -> SmsBindingRules
    func startAttempt(state: String, request: SmsBindingStartRequest) async throws -> SmsBindingIssued
    func report(state: String, attemptId: String, report: SmsBindingReport) async throws
    func verdict(state: String, attemptId: String, sinceVersion: Int?, waitSeconds: Int) async throws -> SmsBindingVerdict
}

// MARK: - Live

internal struct LiveSmsBindingBackend: SmsBindingBackend {
    static let rulesPath = "/v3/lp/user/binding/sms/rules/{state}"
    static let startPath = "/v3/lp/user/binding/sms/attempts/{state}"
    static let reportPath = "/v3/lp/user/binding/sms/attempts/{attempt_id}/report/{state}"
    static let verdictPath = "/v3/lp/user/binding/sms/attempts/{attempt_id}/result/{state}"

    let apiManager: ApiManager

    func fetchRules(state: String) async throws -> SmsBindingRules {
        let data = try await call(state: state, path: Self.rulesPath, method: "GET")
        guard let rules = SmsBindingRules.decode(data) else { throw SmsBindingBackendError.transport }
        return rules
    }

    func startAttempt(state: String, request: SmsBindingStartRequest) async throws -> SmsBindingIssued {
        let data = try await call(state: state, path: Self.startPath, method: "POST", body: request.toDict())
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let attemptId = json["attempt_id"] as? String,
              let smsBody = json["sms_body"] as? String,
              let vmn = json["vmn"] as? String,
              let ttl = json["ttl_seconds"] as? Int else { throw SmsBindingBackendError.transport }
        return SmsBindingIssued(
            attemptId: attemptId,
            smsBody: smsBody,
            vmn: vmn,
            ttlSeconds: ttl,
            configVersion: (json["config_version"] as? Int) ?? request.rules.configVersion,
            rulesHash: (json["rules_hash"] as? String) ?? request.rules.rulesHash
        )
    }

    func report(state: String, attemptId: String, report: SmsBindingReport) async throws {
        _ = try await call(
            state: state,
            path: Self.reportPath.replacingOccurrences(of: "{attempt_id}", with: attemptId),
            method: "POST",
            body: report.toDict()
        )
    }

    func verdict(state: String, attemptId: String, sinceVersion: Int?, waitSeconds: Int) async throws -> SmsBindingVerdict {
        // `constructURL` only renders string values; an Int here arrives as an empty parameter.
        var query: [String: Any] = ["wait": String(waitSeconds)]
        if let sinceVersion { query["since"] = String(sinceVersion) }
        let data = try await call(
            state: state,
            path: Self.verdictPath.replacingOccurrences(of: "{attempt_id}", with: attemptId),
            method: "GET",
            query: query
        )
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = json["state"] as? String,
              let parsedState = SmsBindingState(rawValue: raw) else { throw SmsBindingBackendError.transport }
        return SmsBindingVerdict(
            state: parsedState,
            reason: json["reason"] as? String,
            bindingId: json["binding_id"] as? String,
            stateVersion: (json["state_version"] as? Int) ?? 0
        )
    }

    /// Runs one call and folds every failure into `SmsBindingBackendError`.
    private func call(
        state: String,
        path: String,
        method: String,
        body: [String: Any]? = nil,
        query: [String: Any]? = nil
    ) async throws -> Data {
        do {
            return try await apiManager.performUserAuthRequest(
                state: state, path: path, method: method, body: body, queryParameters: query
            )
        } catch let error as ApiError {
            let json = error.responseJson
            // A 4xx that names a reason is the backend refusing the attempt; anything else (5xx,
            // gateway errors, no reason) is treated as transport so the caller may retry.
            guard (400..<500).contains(error.statusCode), let reason = json?["reason"] as? String else {
                throw SmsBindingBackendError.transport
            }
            throw SmsBindingBackendError.rejected(
                SmsBindingFailure(backendReason: reason),
                retryAfterSeconds: json?["retry_after_seconds"] as? Int
            )
        } catch {
            throw SmsBindingBackendError.transport
        }
    }
}
