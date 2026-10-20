//
//  AppAttestUseCase.swift
//  OtplessBM
//
//  Registers an Apple App Attest key with the backend, once per install, when the merchant
//  config asks for it. Contract: `POST /v3/lp/user/device/attestation/{state}` — the
//  transaction `state` is the challenge, so `clientDataHash = SHA256(utf8(state))`.
//
//  Design rules, all deliberate:
//   * Never on the request path — the caller fires this in the background after config.
//   * Fail open — every failure is telemetry only; it can never fail or delay merchant auth.
//   * A key is persisted only after the backend answers SUCCESS. A key that Apple has
//     attested but the backend has not accepted is useless and cannot be re-attested, so it
//     is dropped and the next attempt mints a fresh one.
//   * Backoff, so a broken backend or an unsupported device does not cost an Apple round
//     trip on every init.
//

import CryptoKit
import DeviceCheck
import Foundation

// MARK: - Seams

/// Apple's side of App Attest. `DCAppAttestService` is never supported on the simulator,
/// so the orchestration is tested against a fake behind this protocol.
@available(iOS 14.0, *)
internal protocol AppAttestPlatform: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

@available(iOS 14.0, *)
internal struct LiveAppAttestPlatform: AppAttestPlatform {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}

internal enum AppAttestRegistration: Equatable {
    case accepted
    /// The server understood the request and said no (`status != SUCCESS`, or a 4xx).
    case rejected(reason: String)
    /// Network, timeout, 5xx, 429 or an undecodable body — worth retrying later.
    case failed(reason: String)

    /// Maps the repository result onto the three outcomes. Pure, so it is unit-tested
    /// without a network.
    static func from(_ result: Result<AppAttestResponse, Error>) -> AppAttestRegistration {
        switch result {
        case .success(let response):
            return response.status?.uppercased() == "SUCCESS"
                ? .accepted
                : .rejected(reason: "status_\(response.status?.lowercased() ?? "missing")")
        case .failure(let error):
            if let apiError = error as? ApiError {
                let code = apiError.statusCode
                // 408 / 429 are the client-error codes that mean "try again later".
                if (400..<500).contains(code) && code != 408 && code != 429 {
                    return .rejected(reason: "http_\(code)")
                }
                return .failed(reason: "http_\(code)")
            }
            if error is DecodingError { return .failed(reason: "undecodable_response") }
            return .failed(reason: "network")
        }
    }
}

internal protocol AppAttestBackend: Sendable {
    func register(state: String, keyId: String, attestationObject: Data) async -> AppAttestRegistration
}

internal struct LiveAppAttestBackend: AppAttestBackend {
    func register(state: String, keyId: String, attestationObject: Data) async -> AppAttestRegistration {
        let result = await Otpless.shared.apiRepository.postDeviceAttestation(
            state: state,
            keyId: keyId,
            attestationObject: attestationObject.base64EncodedString()
        )
        return AppAttestRegistration.from(result)
    }
}

/// Where the confirmed key lives. The key id sits in the Keychain, which **survives an app
/// reinstall** — but App Attest keys do not. UserDefaults is wiped on uninstall, so a key id
/// with no install marker means the key it names no longer exists on this device.
internal protocol AppAttestStore: Sendable {
    func keyId() -> String?
    func saveKeyId(_ keyId: String)
    func clearKeyId()
    var hasInstallMarker: Bool { get }
    func setInstallMarker()
}

internal struct LiveAppAttestStore: AppAttestStore {
    private static let keyIdKey = "otpless_bm_attest_key_id"
    private static let installMarkerKey = "otpless_bm_attest_install_marker"

    func keyId() -> String? {
        SecureStorage.shared.retrieve(key: Self.keyIdKey)
    }

    func saveKeyId(_ keyId: String) {
        SecureStorage.shared.save(key: Self.keyIdKey, value: keyId)
    }

    func clearKeyId() {
        SecureStorage.shared.delete(key: Self.keyIdKey)
    }

    var hasInstallMarker: Bool {
        UserDefaults.standard.bool(forKey: Self.installMarkerKey)
    }

    func setInstallMarker() {
        UserDefaults.standard.set(true, forKey: Self.installMarkerKey)
    }
}

internal struct AppAttestTelemetry: Sendable {
    var success: @Sendable () -> Void
    var failure: @Sendable (String) -> Void
    var skipped: @Sendable (String) -> Void
    var assertionFailure: @Sendable (String) -> Void = { _ in }
    var assertionSkipped: @Sendable (String) -> Void = { _ in }

    static let live = AppAttestTelemetry(
        success: { OtplessBMEvents.AppAttest.success() },
        failure: { OtplessBMEvents.AppAttest.failure(reason: $0) },
        skipped: { OtplessBMEvents.AppAttest.skipped(reason: $0) },
        assertionFailure: { OtplessBMEvents.AppAttest.assertionFailure(reason: $0) },
        assertionSkipped: { OtplessBMEvents.AppAttest.assertionSkipped(reason: $0) }
    )
}

// MARK: - Assertion in the request body

/// The `appAttestInfo` member that carries a per-request assertion in the intent body. It is
/// only ever added when attestation is enabled for the merchant, so a merchant without it sends
/// exactly the body it sent before.
///
///     "appAttestInfo": { "status": "ok", "keyId": "...", "assertion": "...", "challenge": "..." }
///
/// `status` is `ok`, or the reason no assertion was produced (`unsupported`, `no_key`,
/// `invalid_key`, `timeout`, `error`, `dcerror_N`); the other three appear only with `ok`.
internal enum AppAttestInfo {
    static let bodyKey = "appAttestInfo"
    static let status = "status"
    static let keyId = "keyId"
    static let assertion = "assertion"
    static let challenge = "challenge"

    /// Version tag of the canonical-string format below. Bump it if the field list changes.
    static let hashVersion = "v1"

    /// The body fields the assertion is bound to, in this order. Together they pin the request
    /// to one app, one session and one OTP destination, so a captured assertion cannot be
    /// replayed to send an OTP somewhere else.
    ///
    /// Deliberately NOT included: `loginUri` and `packageName` (the backend's state interceptor
    /// rewrites them before anything else sees them, so the two sides would disagree), and
    /// everything that is free-form (`deviceInfo`, `metadata`, ...).
    static let signedFields = ["appId", "tsId", "channel", "identifierType", "value"]

    /// `clientDataHash = SHA256( UTF8( v1|challenge|appId|tsId|channel|identifierType|value ) )`.
    /// A missing field is an empty string. `value` is last on purpose: it is the only free-form
    /// member, so a `|` inside it cannot shift the fields in front of it.
    static func canonicalString(challenge: String, fields: [String: String]) -> String {
        ([hashVersion, challenge] + signedFields.map { fields[$0] ?? "" }).joined(separator: "|")
    }
}

private struct AssertionTimeout: Error {}

/// Lets exactly one of two racing tasks resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Races `operation` against a timer. Unlike a task group this returns as soon as the timer
/// fires even if `operation` never finishes: Apple's call is not cancellable, and a hung
/// assertion must not hang the merchant's request.
private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce()
        Task {
            do {
                let value = try await operation()
                if once.claim() { continuation.resume(returning: value) }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            if once.claim() { continuation.resume(throwing: AssertionTimeout()) }
        }
    }
}

// MARK: - Use case

@available(iOS 14.0, *)
internal actor AppAttestUseCase {

    enum Outcome: Equatable {
        case attested
        case alreadyAttested
        case unsupported
        case backingOff
        case failed
    }

    static let shared = AppAttestUseCase()

    /// First retry after 30 s, doubling per consecutive failure, capped at one hour.
    /// In-memory on purpose: it bounds work within a process, and a fresh launch gets a
    /// fresh attempt.
    static let baseBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 3600

    private let platform: AppAttestPlatform
    private let backend: AppAttestBackend
    private let store: AppAttestStore
    private let telemetry: AppAttestTelemetry
    private let now: @Sendable () -> Date
    private let assertionTimeout: TimeInterval

    private var inFlight: Task<Outcome, Never>?
    private var consecutiveFailures = 0
    private var nextAttemptAt: Date?

    init(
        platform: AppAttestPlatform = LiveAppAttestPlatform(),
        backend: AppAttestBackend = LiveAppAttestBackend(),
        store: AppAttestStore = LiveAppAttestStore(),
        telemetry: AppAttestTelemetry = .live,
        now: @escaping @Sendable () -> Date = { Date() },
        assertionTimeout: TimeInterval = 1.0
    ) {
        self.platform = platform
        self.backend = backend
        self.store = store
        self.telemetry = telemetry
        self.now = now
        self.assertionTimeout = assertionTimeout
    }

    /// Whether a confirmed key is stored for this install. Intended for the future
    /// assertion work, which builds on the persisted key id.
    func hasAttestedKey() -> Bool {
        discardStaleKeyIfNeeded()
        return store.keyId() != nil
    }

    /// Attests if — and only if — this install has no confirmed key yet. Safe to call on
    /// every init: concurrent callers share one attempt, and repeat calls are cheap.
    @discardableResult
    func attestIfNeeded(state: String) async -> Outcome {
        if let running = inFlight {
            return await running.value
        }
        let task = Task { await self.attest(state: state) }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    /// The `appAttestInfo` content for a request whose body has these string fields: proof that
    /// the request comes from the app install that registered the key. Never throws and never
    /// blocks the request for long; if no assertion can be produced, `status` says why and the
    /// caller sends the request anyway (fail open).
    func assertionInfo(forFields fields: [String: String], challenge: String) async -> [String: String] {
        func unavailable(_ reason: String) -> [String: String] { [AppAttestInfo.status: reason] }

        guard platform.isSupported else {
            telemetry.assertionSkipped("unsupported")
            return unavailable("unsupported")
        }
        discardStaleKeyIfNeeded()
        guard let keyId = store.keyId() else {
            telemetry.assertionSkipped("no_key")
            return unavailable("no_key")
        }

        let canonical = AppAttestInfo.canonicalString(challenge: challenge, fields: fields)
        let clientDataHash = Data(SHA256.hash(data: Data(canonical.utf8)))
        let platform = self.platform
        do {
            let assertion = try await withTimeout(seconds: assertionTimeout) {
                try await platform.generateAssertion(keyId, clientDataHash: clientDataHash)
            }
            return [
                AppAttestInfo.status: "ok",
                AppAttestInfo.keyId: keyId,
                AppAttestInfo.assertion: assertion.base64EncodedString(),
                AppAttestInfo.challenge: challenge
            ]
        } catch is AssertionTimeout {
            telemetry.assertionFailure("timeout")
            return unavailable("timeout")
        } catch let error as DCError where error.code == .invalidKey {
            // The key no longer exists on this device. Forget it so the next init re-attests.
            store.clearKeyId()
            telemetry.assertionFailure("invalid_key")
            return unavailable("invalid_key")
        } catch {
            let reason = Self.reason(for: error)
            telemetry.assertionFailure(reason)
            return unavailable(reason)
        }
    }

    // MARK: - Internals

    private func attest(state: String) async -> Outcome {
        guard platform.isSupported else {
            DLog("[AppAttest] Not supported on this device — skipping")
            telemetry.skipped("unsupported")
            return .unsupported
        }

        discardStaleKeyIfNeeded()
        if store.keyId() != nil {
            return .alreadyAttested
        }

        if let next = nextAttemptAt, now() < next {
            DLog("[AppAttest] Backing off until \(next)")
            telemetry.skipped("backoff")
            return .backingOff
        }

        do {
            let keyId = try await platform.generateKey()
            let clientDataHash = Data(SHA256.hash(data: Data(state.utf8)))
            let attestationObject = try await platform.attestKey(keyId, clientDataHash: clientDataHash)

            switch await backend.register(state: state, keyId: keyId, attestationObject: attestationObject) {
            case .accepted:
                // Marker first: a crash between the two writes then leaves a marker with no
                // key (harmless) rather than a key with no marker (treated as stale).
                store.setInstallMarker()
                store.saveKeyId(keyId)
                consecutiveFailures = 0
                nextAttemptAt = nil
                DLog("[AppAttest] Attested — keyId: \(keyId.prefix(8))…")
                telemetry.success()
                return .attested
            case .rejected(let reason), .failed(let reason):
                return recordFailure(reason: reason)
            }
        } catch {
            return recordFailure(reason: Self.reason(for: error))
        }
    }

    /// A key id in the Keychain with no install marker survived an uninstall; the key it
    /// names does not exist any more, so forget it and re-attest.
    private func discardStaleKeyIfNeeded() {
        if store.keyId() != nil && !store.hasInstallMarker {
            DLog("[AppAttest] Key id predates this install — discarding")
            store.clearKeyId()
        }
    }

    private func recordFailure(reason: String) -> Outcome {
        consecutiveFailures += 1
        let delay = min(Self.baseBackoff * pow(2, Double(consecutiveFailures - 1)), Self.maxBackoff)
        nextAttemptAt = now().addingTimeInterval(delay)
        DLog("[AppAttest] Attestation failed (\(reason)) — retry in \(Int(delay))s")
        telemetry.failure(reason)
        return .failed
    }

    /// Fixed tokens only: no messages from Apple, no key ids.
    static func reason(for error: Error) -> String {
        if let dcError = error as? DCError {
            return "dcerror_\(dcError.code.rawValue)"
        }
        return "error"
    }
}
