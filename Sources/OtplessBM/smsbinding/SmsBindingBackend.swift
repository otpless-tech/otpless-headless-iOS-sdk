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

    /// The `simBinding` member of the intent request: the four fields the backend documents for iOS
    /// (Android adds `apiLevel` and `sim`). Nothing else is sent, so the backend never meets a field
    /// it did not define. The UPI entitlement declaration, plan-status support and the previous
    /// attempt are known to the SDK but have no field in the contract yet.
    func simBindingDict() -> [String: Any] {
        var body: [String: Any] = [
            "platform": "IOS",
            "osVersion": osVersion,
            "appVersion": appVersion
        ]
        if let deviceFingerprintHash { body["deviceFingerprint"] = deviceFingerprintHash }
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

/// Why an attempt ended without a binding, sent to the backend on the status call as `lapseMeta`.
/// A non-null `lapseMeta` fails the transaction and closes the attempt as aborted, so the token stops
/// working at once. The backend asks for these codes: `USER_CANCELLED`, `SESSION_INTERRUPTED` (R9),
/// `TOKEN_EXPIRED` (R20) and `SMS_SEND_FAILED`. It does not need the send time or the composer return
/// time: the app enforces R20 itself and reports a failure this way.
internal struct SmsBindingLapse: Equatable, Sendable {
    let error: String
    let description: String

    static let userCancelled = SmsBindingLapse(error: "USER_CANCELLED", description: "User cancelled")

    /// A failure the app decided on, under its own name.
    static func failure(_ failure: SmsBindingFailure) -> SmsBindingLapse {
        SmsBindingLapse(error: failure.rawValue, description: description(for: failure))
    }

    /// The JSON the status call carries: `{"error": …, "error_description": …}`.
    var json: String {
        let object: [String: Any] = ["error": error, "error_description": description]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func description(for failure: SmsBindingFailure) -> String {
        switch failure {
        case .smsSendFailed: return "SMS could not be sent"
        case .tokenExpired: return "Token expired"
        case .sessionInterrupted: return "App left the foreground"
        case .noSim: return "No SIM or no cellular signal"
        case .upgradeRequired: return "App or OS version too low"
        case .entitlementMissing: return "UPI entitlement not declared"
        default: return "Attempt ended"
        }
    }
}

internal struct SmsBindingVerdict: Equatable, Sendable {
    let state: SmsBindingState
    let reason: String?
    /// On success, the token the backend returned (`authDetail.token`).
    let bindingId: String?
    let stateVersion: Int
    /// On success, who was verified (`authDetail.user`).
    var mobile: String? = nil
    var userId: String? = nil
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
    /// Ends the attempt at the backend, as a failure the app decided on.
    func lapse(state: String, attemptId: String, lapse: SmsBindingLapse) async throws
    /// `sinceVersion` and `waitSeconds` are for backends that can hold a request open; the live
    /// one answers at once and the caller polls.
    func verdict(state: String, attemptId: String, sinceVersion: Int?, waitSeconds: Int) async throws -> SmsBindingVerdict
}

// MARK: - Live

internal struct LiveSmsBindingBackend: SmsBindingBackend {
    /// Starting an attempt is the normal intent call.
    static let startPath = ApiManager.POST_INTENT_PATH
    /// The general status API, as the other channels use. The attempt is named by `token`, passed
    /// explicitly: the SDK's stored token, asId and uid are deliberately left alone, because a stored
    /// asId makes the next intent continue the same auth session. This is the only place the path is
    /// written.
    static let statusPath = ApiManager.TRANSACTION_STATUS_PATH
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
            // Country code and number together, as every other phone intent sends it. The backend's
            // sample had the national number only; staging answered that with 7102 (invalid phone number).
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
        body["sdkPlatform"] = "IOS"
        body["simBinding"] = request.simBindingDict()
        body["deviceContext"] = SimDeviceContext.dictionary(
            osVersion: request.osVersion,
            planStatusSupported: request.planStatusSupported,
            upiEntitlement: request.upiEntitlementDeclared
        )

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

    func lapse(state: String, attemptId: String, lapse: SmsBindingLapse) async throws {
        // The same status call, with `lapseMeta` added. The answer is the failed transaction and is
        // not needed.
        _ = try await call(
            state: state,
            path: Self.statusPath,
            method: "GET",
            query: ["token": attemptId, "lapseMeta": lapse.json]
        )
    }

    func verdict(state: String, attemptId: String, sinceVersion: Int?, waitSeconds: Int) async throws -> SmsBindingVerdict {
        let data: Data
        do {
            data = try await call(
                state: state,
                path: Self.statusPath,
                method: "GET",
                query: ["token": attemptId]
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
            let user = detail["user"] as? [String: Any]
            return SmsBindingVerdict(
                state: .verified, reason: nil, bindingId: detail["token"] as? String, stateVersion: 0,
                mobile: user?["mobile"] as? String, userId: user?["uid"] as? String
            )
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

    /// The backend's own codes for SIM binding refusals (`ErrorConstant`, otpless-common).
    /// 7184 is an HTTP 429; the others are 400s.
    private static let numericCodes: [String: SmsBindingFailure] = [
        "7102": .invalidPhoneNumber,
        "7184": .deviceBlocked,
        "7185": .vmnPoolUnavailable,
        "7186": .upgradeRequired
    ]

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// The reason a refusal carries. The backend's error body is `{ errorCode, message }`, and
    /// `errorCode` is numeric (`7xxx`), so a name is taken from `reason` or `errorDetails` (or
    /// `errorCode` when it is a name), and an expired attempt is recognised by its message.
    private static func refusal(_ json: [String: Any]?) -> SmsBindingFailure? {
        if let code = Self.string(json?["errorCode"]), let known = numericCodes[code] { return known }
        for key in ["reason", "errorDetails", "errorCode"] {
            if let value = json?[key] as? String, let known = SmsBindingFailure(rawValue: value) { return known }
        }
        if let message = json?["message"] as? String, message.lowercased().contains("expired") { return .tokenExpired }
        if let reason = json?["reason"] as? String { return SmsBindingFailure(backendReason: reason) }
        return nil
    }
}
