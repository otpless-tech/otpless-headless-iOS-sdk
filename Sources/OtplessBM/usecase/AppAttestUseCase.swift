//
//  AppAttestUseCase.swift
//  OtplessBM
//
//  Registers an Apple App Attest key with the backend, once per install, when the merchant
//  config asks for it. Contract: `POST /v3/device/attestation/{state}` — the
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
internal protocol AppAttestPlatform: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(id keyId: String, data clientDataHash: Data) async throws -> Data
    func generateAssertion(id keyId: String, data clientDataHash: Data) async throws -> Data
}

/// App Attest is iOS 14+. Below that `isSupported` is false, so the use case never reaches
/// the other three; they throw rather than crash if it ever does.
private struct LiveAppAttestPlatform: AppAttestPlatform {
    var isSupported: Bool {
        guard #available(iOS 14.0, *) else { return false }
        return DCAppAttestService.shared.isSupported
    }

    func generateKey() async throws -> String {
        guard #available(iOS 14.0, *) else { throw DCError(.featureUnsupported) }
        return try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(id keyId: String, data clientDataHash: Data) async throws -> Data {
        guard #available(iOS 14.0, *) else { throw DCError(.featureUnsupported) }
        return try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }

    func generateAssertion(id keyId: String, data clientDataHash: Data) async throws -> Data {
        guard #available(iOS 14.0, *) else { throw DCError(.featureUnsupported) }
        return try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}

/// Where the confirmed key lives. The key id sits in the Keychain, which **survives an app
/// reinstall** — but App Attest keys do not. UserDefaults is wiped on uninstall, so a key id
/// with no install marker means the key it names no longer exists on this device.
///
/// The backend records a key against one merchant appId, so the key id is kept per appId; the
/// install marker is per install.
internal protocol AppAttestStore: Sendable {
    func keyId() -> String?
    /// False while the store cannot be read (locked device); an empty read is then not "no key".
    func isReadable() -> Bool
    func saveKeyId(_ keyId: String)
    func clearKeyId()
    var hasInstallMarker: Bool { get }
    func setInstallMarker()
}

private struct LiveAppAttestStore: AppAttestStore {
    private static let keyIdKeyPrefix = "otpless_bm_attest_key_id"
    private static let installMarkerKey = "otpless_bm_attest_install_marker"

    /// One Keychain item per merchant app: `otpless_bm_attest_key_id.<appId>`.
    private var keyName: String { "\(Self.keyIdKeyPrefix).\(Otpless.shared.merchantAppId)" }

    func keyId() -> String? {
        SecureStorage.shared.retrieve(key: keyName)
    }

    func isReadable() -> Bool {
        SecureStorage.shared.isReadable(key: keyName)
    }

    func saveKeyId(_ keyId: String) {
        SecureStorage.shared.save(key: keyName, value: keyId)
    }

    func clearKeyId() {
        SecureStorage.shared.delete(key: keyName)
    }

    var hasInstallMarker: Bool {
        UserDefaults.standard.bool(forKey: Self.installMarkerKey)
    }

    func setInstallMarker() {
        UserDefaults.standard.set(true, forKey: Self.installMarkerKey)
    }
}

// MARK: - Use case

internal final class AppAttestUseCase: @unchecked Sendable {

    /// First retry after 30 s, doubling per consecutive failure, capped at one hour.
    /// In-memory on purpose: it bounds work within a process, and a fresh launch gets a
    /// fresh attempt.
    private static let baseBackoff: TimeInterval = 30
    private static let maxBackoff: TimeInterval = 3600
    /// How long an intent waits for Apple to sign it.
    private static let assertionTimeout: TimeInterval = 1.0
    /// How long an intent waits for a missing key to be registered.
    private static let registrationTimeout: TimeInterval = 3.0

    private let platform: AppAttestPlatform
    private let store: AppAttestStore

    /// Guards the three fields below; the attempt and the intent requests reach them concurrently.
    private let lock = NSLock()
    private var inFlight: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var nextAttemptAt: Date?

    init(
        platform: AppAttestPlatform = LiveAppAttestPlatform(),
        store: AppAttestStore = LiveAppAttestStore()
    ) {
        self.platform = platform
        self.store = store
    }

    /// Attests if — and only if — this install has no confirmed key yet. Safe to call on
    /// every init: concurrent callers share one attempt, and repeat calls are cheap.
    func attestIfNeeded(state: String) async {
        let task: Task<Void, Never> = locked {
            if let running = inFlight { return running }
            let task = Task { await self.attest(state: state) }
            inFlight = task
            return task
        }
        await task.value
        locked { if inFlight == task { inFlight = nil } }
    }

    /// Signs `SHA256(challenge)` with the registered key: proof that the request comes from the
    /// app install that registered it. The caller builds the challenge; `state` is only used to
    /// register a key when there is none yet. Never throws and never
    /// blocks the request for long; if no assertion can be produced, `status` says why and the
    /// caller sends the request anyway (fail open).
    ///
    ///     "appAttestInfo": { "status": "ok", "keyId": "...", "assertion": "...", "challenge": "..." }
    ///
    /// `status` is `ok`, or the reason no assertion was produced (`unsupported`, `no_key`,
    /// `invalid_key`, `timeout`, `error`, `dcerror_N`); the other three appear only with `ok`.
    @available(iOS 14.0, *)
    func assertionInfo(challenge: String, state: String) async -> [String: String] {
        func unavailable(_ reason: String) -> [String: String] { ["status": reason] }

        guard platform.isSupported else {
            OtplessBMEvents.AppAttest.assertionSkipped(reason: "unsupported")
            return unavailable("unsupported")
        }
        guard let keyId = await registeredKeyId(state: state) else {
            OtplessBMEvents.AppAttest.assertionSkipped(reason: "no_key")
            return unavailable("no_key")
        }

        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let platform = self.platform
        do {
            let assertion = try await AsyncUtils.withTimeout(seconds: Self.assertionTimeout) {
                try await platform.generateAssertion(id: keyId, data: clientDataHash)
            }
            return [
                "status": "ok",
                "keyId": keyId,
                "assertion": assertion.base64EncodedString(),
                "challenge": challenge
            ]
        } catch is TimeoutError {
            OtplessBMEvents.AppAttest.assertionFailure(reason: "timeout")
            return unavailable("timeout")
        } catch let error as DCError where error.code == .invalidKey {
            // The key no longer exists on this device. Forget it so the next init re-attests.
            store.clearKeyId()
            OtplessBMEvents.AppAttest.assertionFailure(reason: "invalid_key")
            return unavailable("invalid_key")
        } catch {
            let reason = Self.reason(for: error)
            OtplessBMEvents.AppAttest.assertionFailure(reason: reason)
            return unavailable(reason)
        }
    }

    // MARK: - Internals

    private func attest(state: String) async {
        guard platform.isSupported else {
            DLog("[AppAttest] Not supported on this device — skipping")
            OtplessBMEvents.AppAttest.skipped(reason: "unsupported")
            return
        }

        // Locked device (e.g. a background launch): the Keychain reads as empty, which would
        // register a new key that then could not be saved. Wait for the next launch instead.
        guard store.isReadable() else {
            DLog("[AppAttest] Keychain not readable (device locked) — skipping")
            OtplessBMEvents.AppAttest.skipped(reason: "store_unavailable")
            return
        }

        discardStaleKeyIfNeeded()
        if store.keyId() != nil {
            return
        }

        if let next = locked({ nextAttemptAt }), Date() < next {
            DLog("[AppAttest] Backing off until \(next)")
            OtplessBMEvents.AppAttest.skipped(reason: "backoff")
            return
        }

        do {
            let keyId = try await platform.generateKey()
            let clientDataHash = Data(SHA256.hash(data: Data(state.utf8)))
            let attestationObject = try await platform.attestKey(id: keyId, data: clientDataHash)

            switch await saveAttestationKeyIdRemote(state: state, keyId: keyId, attestationObject: attestationObject) {
            case .success:
                // Marker first: a crash between the two writes then leaves a marker with no
                // key (harmless) rather than a key with no marker (treated as stale).
                store.setInstallMarker()
                store.saveKeyId(keyId)
                locked {
                    consecutiveFailures = 0
                    nextAttemptAt = nil
                }
                DLog("[AppAttest] Attested — keyId: \(keyId.prefix(8))…")
                OtplessBMEvents.AppAttest.success()
            case .failure(let error):
                recordFailure(reason: Self.reason(for: error))
            }
        } catch {
            recordFailure(reason: Self.reason(for: error))
        }
    }

    /// Registers the attested key with the backend. A 200 without a `SUCCESS` status is a failure too.
    private func saveAttestationKeyIdRemote(state: String, keyId: String, attestationObject: Data) async -> Result<AppAttestResponse, Error> {
        let repository = Otpless.shared.apiRepository
        let result = await repository.postDeviceAttestation(
            state: state, keyId: keyId, attestationObject: attestationObject.base64EncodedString()
        )
        if case .success(let response) = result, response.status?.uppercased() != "SUCCESS" {
            return .failure(ApiError(message: "Attestation status \(response.status ?? "missing")", statusCode: 200))
        }
        return result
    }

    /// The confirmed key id. With none (never registered, discarded as stale, or registration
    /// still running from init), joins or starts a registration and waits up to
    /// `registrationTimeout` for it, so the request can still be signed. The attempt keeps
    /// running past the wait, for the next request.
    private func registeredKeyId(state: String) async -> String? {
        discardStaleKeyIfNeeded()
        if let keyId = store.keyId() { return keyId }
        try? await AsyncUtils.withTimeout(seconds: Self.registrationTimeout) { await self.attestIfNeeded(state: state) }
        return store.keyId()
    }

    /// A key id in the Keychain with no install marker survived an uninstall; the key it
    /// names does not exist any more, so forget it and re-attest.
    private func discardStaleKeyIfNeeded() {
        if store.keyId() != nil && !store.hasInstallMarker {
            DLog("[AppAttest] Key id predates this install — discarding")
            store.clearKeyId()
        }
    }

    private func recordFailure(reason: String) {
        let delay: TimeInterval = locked {
            consecutiveFailures += 1
            let delay = min(Self.baseBackoff * pow(2, Double(consecutiveFailures - 1)), Self.maxBackoff)
            nextAttemptAt = Date().addingTimeInterval(delay)
            return delay
        }
        DLog("[AppAttest] Attestation failed (\(reason)) — retry in \(Int(delay))s")
        OtplessBMEvents.AppAttest.failure(reason: reason)
    }

    /// `NSLock.withLock` is iOS 16+. Synchronous, so the lock is never held across an `await`.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Fixed tokens only: no messages from Apple, no key ids.
    static func reason(for error: Error) -> String {
        if let dcError = error as? DCError {
            return "dcerror_\(dcError.code.rawValue)"
        }
        if let apiError = error as? ApiError {
            return apiError.statusCode > 0 ? "http_\(apiError.statusCode)" : "network"
        }
        return "error"
    }
}
