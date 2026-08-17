//
//  OtplessSslPinManager.swift
//  OtplessBM
//

import Foundation
import Security

/// Coordinator for the signed, refreshable SSL pin envelope — the iOS mirror of Android's
/// `OtplessSslPinManager` (otpless-headless-android-lite PR #39). Owns the full lifecycle of the
/// pin set:
///
/// - **Bootstrap** (`bootstrap()`): try a cached envelope first so the first API call doesn't
///   wait on a network round-trip; fall back to a remote fetch if the cache is missing,
///   unverifiable, expired, or older than `PinConstants.refreshIntervalSeconds`.
/// - **Verification** (`verify(_:)`): every envelope is authenticated against
///   `OtplessKeyVault.verifyAnchors` (hardcoded ECDSA P-256 public keys) before its pins are
///   trusted. Compromising the CDN alone cannot forge a manifest — the signer's private key is
///   also required.
/// - **Defense in depth** (`union` + `restrictToKnownHosts`): a manifest can only refine pins
///   for hosts already in `OtplessKeyVault.baselinePins` — never install pins for arbitrary
///   hosts — and can only ADD to the baseline trust, never remove it.
/// - **Failure recovery** (`handlePinFailure()`): one-shot per SDK process, invoked by
///   `PinningURLSessionDelegate` when a live pin check fails, to attempt a fresh fetch before
///   giving up.
///
/// `isSslDone` is the readiness flag `PinnedSessionProvider.isOkSsl` consumes to gate
/// `Otpless.start(withRequest:)`.
internal final class OtplessSslPinManager: @unchecked Sendable {

    private let pinner: DynamicSPKIPinner

    private let lock = NSLock()
    private var _isSslDone = false
    private var sessionRefreshed = false
    private var inFlightRefresh: Task<Bool, Never>?

    /// Bootstrap fetch client. Deliberately unpinned (see `PinConstants.manifestURL`) and
    /// ephemeral so nothing about the manifest transport is cached at the URL layer.
    private let fetchSession: URLSession

    var isSslDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isSslDone
    }

    init(pinner: DynamicSPKIPinner) {
        self.pinner = pinner
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = PinConstants.manifestFetchTimeoutSeconds
        config.timeoutIntervalForResource = PinConstants.manifestFetchTimeoutSeconds
        self.fetchSession = URLSession(configuration: config)
    }

    /// Cache-first bootstrap, called once from the SDK init task before the first pinned request
    /// can fire. A cached envelope is used only when it (a) still verifies against the anchors,
    /// (b) has not passed its `exp`, and (c) was written no more than
    /// `PinConstants.refreshIntervalSeconds` ago. If any of those fails the cache is cleared and
    /// a blocking remote refresh runs; no cache at all goes straight to remote. The outcome
    /// lands in `isSslDone` — a failure here means pins were not applied and `start()` will
    /// refuse to send user-auth requests.
    func bootstrap() async {
        let done: Bool
        if let cachedEnvelope = readCachedEnvelope() {
            let verified = verify(cachedEnvelope)
            let passesFreshness = (verified != nil) && !(verified!.isExpired)
            let nowEpoch = Date().timeIntervalSince1970
            let lastFetchedAt = lastFetchAtEpoch()
            let isNewerCache = (nowEpoch - lastFetchedAt) < PinConstants.refreshIntervalSeconds

            if let verified = verified, passesFreshness, isNewerCache {
                log(message: "[Pin] Pins applied from cached envelope (ver \(verified.ver))", type: .PIN_VALIDATION)
                pinner.setPins(Self.union(OtplessKeyVault.baselinePins, Self.restrictToKnownHosts(verified.pins)))
                OtplessBMEvents.Pin.applied(extra: ["srcSsl": "cached", "version": verified.ver])
                done = true
            } else {
                log(message: "[Pin] Cached envelope invalid/expired/stale — refreshing from remote", type: .PIN_VALIDATION)
                clearEnvelopeCache()
                done = await refreshFromRemote()
                OtplessBMEvents.Pin.manifestFetchFailed(reason: "cache_invalid", data: [
                    "verified": verified != nil,
                    "passesFreshness": passesFreshness,
                    "currentTime": Int(nowEpoch),
                    "lastFetchedTime": Int(lastFetchedAt),
                    "isNewerCache": isNewerCache,
                    "refreshIntervalSeconds": Int(PinConstants.refreshIntervalSeconds)
                ])
            }
        } else {
            done = await refreshFromRemote()
        }
        setSslDone(done)
    }

    /// Invoked by `PinningURLSessionDelegate` when a live pin check fails, to attempt a one-shot
    /// recovery by fetching a fresh envelope.
    ///
    /// Runs at most once per SDK process (`sessionRefreshed`) — a repeated call returns
    /// `.failClosed` to avoid a refresh-retry loop when the server is genuinely presenting a
    /// certificate that no reachable envelope covers. Concurrent failures on parallel requests
    /// collapse onto the single in-flight refresh instead of firing N of them.
    func handlePinFailure() async -> PinFailureAction {
        guard let slot = acquireRefreshSlot() else { return .failClosed }
        let refreshed = await slot.task.value
        if slot.startedHere {
            setSslDone(refreshed)
        }
        return refreshed ? .retryWithNewPins : .failClosed
    }

    /// Synchronous critical section for the one-shot refresh: returns the in-flight refresh to
    /// await (starting it if this caller is first), or nil when the per-process refresh has
    /// already been consumed.
    private func acquireRefreshSlot() -> (task: Task<Bool, Never>, startedHere: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        if let inFlight = inFlightRefresh {
            return (inFlight, false)
        }
        if sessionRefreshed {
            return nil
        }
        sessionRefreshed = true
        let task = Task { await self.refreshFromRemote() }
        inFlightRefresh = task
        return (task, true)
    }

    private func setSslDone(_ value: Bool) {
        lock.lock()
        _isSslDone = value
        lock.unlock()
    }

    /// Full remote-refresh pipeline: fetch envelope → verify signature → check expiry →
    /// restrict to baseline hosts → union with baseline → apply to pinner → cache. Each stage
    /// emits a specific `manifestFetchFailed` telemetry variant so ops can distinguish network
    /// errors, HTTP errors, signature failures, expired envelopes, and "signer with no known
    /// hosts". Returns false at the first failing stage and — critically — leaves the live
    /// pinner untouched, so whatever pin set was active (usually the baseline) keeps enforcing.
    private func refreshFromRemote() async -> Bool {
        let envelope: String
        switch await fetchEnvelope() {
        case .success(let fetched):
            envelope = fetched
        case .httpError(let code):
            log(message: "[Pin] Envelope fetch failed — HTTP \(code)", type: .PIN_VALIDATION)
            OtplessBMEvents.Pin.manifestFetchFailed(reason: "http_\(code)")
            return false
        case .networkError:
            log(message: "[Pin] Envelope fetch failed — network error", type: .PIN_VALIDATION)
            OtplessBMEvents.Pin.manifestFetchFailed(reason: "network")
            return false
        }

        guard let verified = verify(envelope) else {
            log(message: "[Pin] Envelope signature verification failed", type: .PIN_VALIDATION)
            OtplessBMEvents.Pin.manifestFetchFailed(reason: "signature")
            return false
        }

        if verified.isExpired {
            log(message: "[Pin] Envelope expired (exp \(Int(verified.exp)))", type: .PIN_VALIDATION)
            OtplessBMEvents.Pin.manifestFetchFailed(reason: "expired", data: [
                "currentTime": Int(Date().timeIntervalSince1970),
                "envelopeExpiry": Int(verified.exp)
            ])
            return false
        }

        let restricted = Self.restrictToKnownHosts(verified.pins)
        if restricted.isEmpty {
            OtplessBMEvents.Pin.manifestFetchFailed(reason: "no_known_hosts")
            return false
        }

        pinner.setPins(Self.union(OtplessKeyVault.baselinePins, restricted))
        writeEnvelopeCache(envelope)
        log(message: "[Pin] Pins applied from remote envelope (ver \(verified.ver), \(restricted.count) host(s))", type: .PIN_VALIDATION)
        OtplessBMEvents.Pin.applied(extra: [
            "kid": verified.kid ?? "",
            "hostCount": restricted.count,
            "srcSsl": "remote",
            "version": verified.ver
        ])
        return true
    }

    private func fetchEnvelope() async -> SslEnvelopeResult {
        do {
            let (data, response) = try await fetchSession.data(for: URLRequest(url: PinConstants.manifestURL))
            guard let http = response as? HTTPURLResponse else { return .networkError }
            guard (200..<300).contains(http.statusCode) else { return .httpError(code: http.statusCode) }
            guard let envelope = String(data: data, encoding: .utf8) else { return .networkError }
            return .success(envelope: envelope)
        } catch {
            return .networkError
        }
    }

    // MARK: - Envelope verification

    /// Signature-verifies a raw envelope against the anchors and, only on success, parses the
    /// trusted payload into a `VerifiedManifest`. Envelope shape:
    /// `{ "payload": <base64url>, "sig": <base64url DER ECDSA> }`; the signature is checked with
    /// SHA256/ECDSA against each anchor in turn. Returns nil on any failure — malformed JSON,
    /// missing fields, undecodable base64, signature mismatch — so callers treat unverifiable
    /// envelopes as absent rather than trusted.
    func verify(_ envelopeJson: String) -> VerifiedManifest? {
        guard let envelopeData = envelopeJson.data(using: .utf8),
              let outer = (try? JSONSerialization.jsonObject(with: envelopeData)) as? [String: Any],
              let payloadStr = outer["payload"] as? String, !payloadStr.isEmpty,
              let sigStr = outer["sig"] as? String, !sigStr.isEmpty,
              let payloadBytes = Self.decodeBase64Url(payloadStr),
              let sigBytes = Self.decodeBase64Url(sigStr) else {
            return nil
        }

        let signatureValid = OtplessKeyVault.verifyAnchors.contains { anchor in
            guard let key = Self.loadAnchor(anchor) else { return false }
            return SecKeyVerifySignature(
                key,
                .ecdsaSignatureMessageX962SHA256,
                payloadBytes as CFData,
                sigBytes as CFData,
                nil
            )
        }
        guard signatureValid else { return nil }

        guard let json = (try? JSONSerialization.jsonObject(with: payloadBytes)) as? [String: Any],
              let ver = json["ver"] as? Int,
              let exp = (json["exp"] as? NSNumber)?.doubleValue,
              let domains = json["domains"] as? [String: Any] else {
            OtplessBMEvents.Exception.captured(where: "verifying_ssl_envelope", message: "verified payload is not a valid manifest")
            return nil
        }

        var pinsMap: [String: [String]] = [:]
        for (host, value) in domains {
            guard let hostObj = value as? [String: Any],
                  let pins = hostObj["pins"] as? [String] else { continue }
            pinsMap[host] = pins
        }

        return VerifiedManifest(
            ver: ver,
            iat: (json["iat"] as? NSNumber)?.doubleValue ?? 0,
            exp: exp,
            kid: (json["kid"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            pins: pinsMap
        )
    }

    /// Parse a base64 DER `SubjectPublicKeyInfo` anchor into a `SecKey` for signature
    /// verification. `SecKeyCreateWithData` wants the raw ANSI X9.63 point (`04 || X || Y`),
    /// not full SPKI DER, so the fixed 26-byte P-256 SPKI header is stripped first. Returns nil
    /// (instead of throwing) so a malformed anchor entry cannot crash the SDK — the verify loop
    /// just falls through to the next anchor.
    private static func loadAnchor(_ anchorBase64Der: String) -> SecKey? {
        guard let spki = Data(base64Encoded: anchorBase64Der), spki.count == 91 else { return nil }
        let rawPoint = spki.suffix(65)
        guard rawPoint.first == 0x04 else { return nil }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256
        ]
        return SecKeyCreateWithData(Data(rawPoint) as CFData, attributes as CFDictionary, nil)
    }

    /// Decode base64url (URL-safe, unpadded); also tolerates the standard `+/` alphabet and
    /// present padding, matching okio's behavior on Android.
    private static func decodeBase64Url(_ s: String) -> Data? {
        var normalized = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }

    // MARK: - Defense in depth

    /// Merge manifest pins into the baseline set, deduplicating per host. Baseline pins remain
    /// trusted even if the manifest omits them — a signed manifest can only ADD to trust.
    static func union(_ first: [String: [String]], _ second: [String: [String]]) -> [String: [String]] {
        var merged = first
        for (host, pins) in second {
            var combined = merged[host] ?? []
            for pin in pins where !combined.contains(pin) {
                combined.append(pin)
            }
            merged[host] = combined
        }
        return merged
    }

    /// Drop any manifest host not already in the baseline — a compromised manifest signer cannot
    /// install pins for arbitrary hosts and redirect trust to a domain they control.
    static func restrictToKnownHosts(_ hostToPins: [String: [String]]) -> [String: [String]] {
        return hostToPins.filter { OtplessKeyVault.baselinePins.keys.contains($0.key) }
    }

    // MARK: - Envelope cache

    private func readCachedEnvelope() -> String? {
        let cached: String = SecureStorage.shared.getFromUserDefaults(key: PinConstants.manifestEnvelopeKey, defaultValue: "")
        return cached.isEmpty ? nil : cached
    }

    private func lastFetchAtEpoch() -> TimeInterval {
        return SecureStorage.shared.getFromUserDefaults(key: PinConstants.manifestLastFetchAtKey, defaultValue: TimeInterval(0))
    }

    private func writeEnvelopeCache(_ envelope: String) {
        SecureStorage.shared.saveToUserDefaults(key: PinConstants.manifestEnvelopeKey, value: envelope)
        SecureStorage.shared.saveToUserDefaults(key: PinConstants.manifestLastFetchAtKey, value: Date().timeIntervalSince1970)
    }

    private func clearEnvelopeCache() {
        UserDefaults.standard.removeObject(forKey: PinConstants.manifestEnvelopeKey)
        UserDefaults.standard.removeObject(forKey: PinConstants.manifestLastFetchAtKey)
    }
}
