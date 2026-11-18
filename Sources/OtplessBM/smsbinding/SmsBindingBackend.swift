import Foundation

// MARK: - Models
//
// The backend's contract: SIM binding is a channel of the intent call. The intent request carries a
// `simBinding` block; the response (`quantumLeap`) carries the token, the number to send to, the
// message and the client's rules together. Then the device reports, and the SDK polls a status
// endpoint until the attempt is verified, rejected or expired.

internal struct SmsBindingStartRequest: Sendable {
    /// E.164, `+919812345621`.
    let msisdn: String
    /// `+91`. The intent body wants it apart from the national number.
    var countryCode: String? = nil
    let osVersion: String
    let appVersion: String
    let sdkVersion: String
    let deviceFingerprintHash: String?
    let previousAttemptId: String?
    let upiEntitlementDeclared: Bool
    /// The device can produce Apple's ICCID token (iOS 26+). Whether it is used is up to the rules.
    let iccidTokenSupported: Bool
    /// ENG-628: this device has Apple's plan status API (iOS 27+). Lets orchestration route on
    /// capability rather than on the OS version alone.
    var planStatusSupported: Bool = false

    /// Country code and national number, apart. Without a country code the digits are all national.
    var numberParts: (countryCode: String, national: String) {
        let digits = msisdn.filter { $0.isNumber }
        if let code = countryCode?.filter({ $0.isNumber }), !code.isEmpty, digits.hasPrefix(code) {
            return ("+" + code, String(digits.dropFirst(code.count)))
        }
        return ("", digits)
    }

    /// The `simBinding` member of the intent request. Android's `sim { subscriptionId, slot, ... }`
    /// and `apiLevel` have no iOS counterpart, so they are not sent.
    func simBindingDict() -> [String: Any] {
        var body: [String: Any] = [
            "platform": "IOS",
            "osVersion": osVersion,
            "appVersion": appVersion,
            "sdkVersion": sdkVersion,
            "upiEntitlement": upiEntitlementDeclared,
            "iccidTokenSupported": iccidTokenSupported,
            "planStatusSupported": planStatusSupported
        ]
        if let deviceFingerprintHash { body["deviceFingerprint"] = deviceFingerprintHash }
        if let previousAttemptId { body["previousAttemptId"] = previousAttemptId }
        return body
    }
}

/// The token and number the backend issued for one attempt. There is no separate attempt id: the
/// token identifies the attempt (`attemptId` holds it).
internal struct SmsBindingIssued: Equatable, Sendable {
    let attemptId: String
    let smsBody: String
    let vmn: String
    let ttlSeconds: Int
}

/// What starting an attempt returns: the issued token and the rules it was issued under.
internal struct SmsBindingStarted: Equatable, Sendable {
    let issued: SmsBindingIssued
    let rules: SmsBindingRules
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

    /// The `simBinding` member of the report. `sentAck` and `sentAt` are the fields Android sends;
    /// the iOS-specific facts travel in `ios`.
    func toDict() -> [String: Any] {
        var body: [String: Any] = ["event": event.rawValue, "sentAt": Self.millis(at)]
        if event == .sent { body["sentAck"] = "RESULT_OK" }
        if let reason { body["reason"] = reason.rawValue }
        if let ios {
            var fields: [String: Any] = [
                "composerResult": ios.composerResult,
                "composerPresentedAt": Self.millis(ios.composerPresentedAt),
                "appRegainedControlAt": Self.millis(ios.appRegainedControlAt),
                "returnSeconds": ios.returnSeconds,
                "iccidTokenStatus": ios.iccidTokenStatus
            ]
            if let sendCompletion = ios.sendCompletion { fields["sendCompletion"] = sendCompletion }
            if let token = ios.iccidToken { fields["iccidToken"] = token }
            body["ios"] = fields
        }
        return body
    }

    private static func millis(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }
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
    /// Creates the attempt. The rules the client is on come back with the token.
    func startAttempt(state: String, request: SmsBindingStartRequest) async throws -> SmsBindingStarted
    func report(state: String, attemptId: String, report: SmsBindingReport) async throws
    /// `sinceVersion` and `waitSeconds` are for backends that can hold a request open; the live
    /// one answers at once and the caller polls.
    func verdict(state: String, attemptId: String, sinceVersion: Int?, waitSeconds: Int) async throws -> SmsBindingVerdict
}

// MARK: - Live

internal struct LiveSmsBindingBackend: SmsBindingBackend {
    /// Starting an attempt is the normal intent call.
    static let startPath = ApiManager.POST_INTENT_PATH
    static let reportPath = "/v3/lp/user/transaction/sim-binding-report/{state}"
    /// The token's place in this path is not confirmed by the backend yet (their example was cut off).
    static let statusPath = "/v3/lp/user/transaction/sim-binding-status/{state}/{token}"
    /// The channel the intent response names when it routed the request to SIM binding.
    static let channel = "SIM_BINDING"
    /// The channel the intent asks for; the backend decides the request becomes SIM binding.
    static let requestedChannel = "OTP"

    let apiManager: ApiManager

    func startAttempt(state: String, request: SmsBindingStartRequest) async throws -> SmsBindingStarted {
        let parts = request.numberParts
        var body = PostIntentRequestBody(
            channel: Self.requestedChannel,
            email: nil,
            hasWhatsapp: (Otpless.shared.appInfo["hasWhatsapp"] as? String) ?? "",
            identifierType: "MOBILE",
            mobile: parts.countryCode.trimmingCharacters(in: CharacterSet(charactersIn: "+")) + parts.national,
            selectedCountryCode: parts.countryCode,
            // A silent-auth attempt would answer on a different channel; this is SMS binding only.
            silentAuthEnabled: false,
            triggerWebauthn: false,
            type: "INPUT",
            uid: nil,
            value: parts.national,
            expiry: nil,
            deliveryMethod: nil,
            otpLength: nil,
            uiIds: nil,
            fireIntent: false,
            requestId: nil,
            clientMetaData: nil,
            asId: Otpless.shared.asId
        ).toDict()
        body["simBinding"] = request.simBindingDict()

        let data = try await call(state: state, path: Self.startPath, method: "POST", body: body)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let leap = root["quantumLeap"] as? [String: Any] else { throw SmsBindingBackendError.transport }

        // The intent can come back on another channel (the app is not set up for SIM binding). That
        // request has already been acted on by the backend, but nothing was sent to the user by us.
        guard (leap["channel"] as? String) == Self.channel else {
            throw SmsBindingBackendError.rejected(.notAvailable, retryAfterSeconds: nil)
        }
        guard let sim = leap["simBinding"] as? [String: Any],
              let token = (sim["token"] as? String) ?? (leap["channelAuthToken"] as? String),
              let smsBody = sim["smsBody"] as? String,
              let vmn = sim["vmn"] as? String,
              let ruleMap = sim["rules"] as? [String: Any] else { throw SmsBindingBackendError.transport }

        return SmsBindingStarted(
            issued: SmsBindingIssued(attemptId: token, smsBody: smsBody, vmn: vmn, ttlSeconds: Self.ttlSeconds(sim, leap)),
            rules: SmsBindingRules.decodeInline(rules: ruleMap, rulesHash: sim["rulesHash"] as? String)
        )
    }

    func report(state: String, attemptId: String, report: SmsBindingReport) async throws {
        _ = try await call(
            state: state,
            path: Self.reportPath,
            method: "POST",
            body: ["token": attemptId, "simBinding": report.toDict()]
        )
    }

    func verdict(state: String, attemptId: String, sinceVersion: Int?, waitSeconds: Int) async throws -> SmsBindingVerdict {
        let data: Data
        do {
            data = try await call(
                state: state,
                path: Self.statusPath.replacingOccurrences(of: "{token}", with: attemptId),
                method: "GET"
            )
        } catch SmsBindingBackendError.rejected(let failure, _) where failure == .tokenExpired {
            // An expired attempt answers with an error, not with a state.
            return SmsBindingVerdict(state: .expired, reason: nil, bindingId: nil, stateVersion: 0)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let detail = root["authDetail"] as? [String: Any],
              let status = detail["status"] as? String else { throw SmsBindingBackendError.transport }

        switch status {
        case "PENDING":
            // The backend does not say which of issued, sent or received. The device has already
            // sent, so this is at least `sent`.
            return SmsBindingVerdict(state: .sent, reason: nil, bindingId: nil, stateVersion: 0)
        case "SUCCESS":
            return SmsBindingVerdict(state: .verified, reason: nil, bindingId: detail["token"] as? String, stateVersion: 0)
        case "FAILED":
            let reason = (detail["errorCode"] as? String) ?? (detail["errorDetails"] as? String)
            return SmsBindingVerdict(state: .rejected, reason: reason, bindingId: nil, stateVersion: 0)
        default:
            throw SmsBindingBackendError.transport
        }
    }

    // MARK: -

    /// Seconds the token lives: the response's own figure, else the time left to `expiresAt`, else
    /// the polling timeout.
    private static func ttlSeconds(_ sim: [String: Any], _ leap: [String: Any]) -> Int {
        if let seconds = sim["expiresInSeconds"] as? Int, seconds > 0 { return seconds }
        if let expiresAt = sim["expiresAt"] as? Double {
            let left = Int(expiresAt - Date().timeIntervalSince1970)
            if left > 0 { return left }
        }
        if let timeout = (leap["timerSettings"] as? [String: Any])?["timeout"] as? Int, timeout > 0 { return timeout / 1000 }
        return 120
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
            guard (400..<500).contains(error.statusCode), let failure = Self.refusal(json) else {
                throw SmsBindingBackendError.transport
            }
            throw SmsBindingBackendError.rejected(failure, retryAfterSeconds: json?["retry_after_seconds"] as? Int)
        } catch {
            throw SmsBindingBackendError.transport
        }
    }

    /// The reason a refusal carries. The backend's error body is `{ errorCode, message }`, and
    /// `errorCode` is numeric (`7xxx`), so a name is taken from `reason` or `errorDetails` (or
    /// `errorCode` when it is a name), and an expired attempt is recognised by its message.
    private static func refusal(_ json: [String: Any]?) -> SmsBindingFailure? {
        for key in ["reason", "errorDetails", "errorCode"] {
            if let value = json?[key] as? String, let known = SmsBindingFailure(rawValue: value) { return known }
        }
        if let message = json?["message"] as? String, message.lowercased().contains("expired") { return .tokenExpired }
        if let reason = json?["reason"] as? String { return SmsBindingFailure(backendReason: reason) }
        return nil
    }
}
