//
//  PinnedSessionProvider.swift
//  OtplessBM
//

import Foundation

/// Owns the single pinned `URLSession` shared by `ApiManager` and `CoreHTTPClient`/
/// `SessionServiceImpl` — every host OtplessBM controls goes through this one session so pin
/// enforcement is consistent across both networking chokepoints. Hosts outside the pin set
/// (api.otpless.com, the plain-HTTP Sekura SNA host, staging) pass through on system trust.
///
/// The session and its delegate are created once, eagerly, so `ApiManager`/`CoreHTTPClient`
/// default parameters can capture them at construction time; the *behavior* is driven by the
/// `OtplessSslKind` applied via `configure(sslKind:)` at each `initialise` (mirroring Android's
/// `OtplessService` recreating its pinning stack per init):
///
/// - `.sslEnabled`  — baseline pins from `OtplessKeyVault` are installed immediately and an
///   `OtplessSslPinManager` refreshes them from the signed CloudFront envelope
///   (`bootstrap()` runs inside the SDK init task; `isOkSsl` gates `start()`).
/// - `.customSsl`   — the merchant-supplied pins are installed as-is; no envelope refresh.
/// - `.sslDisabled` — pin comparison is skipped; system TLS validation still applies.
///
/// Fail-closed: on an unrecoverable pin mismatch (`onPinFailure`), `isPinFailedPersistent`
/// latches for the rest of the process and `start()` short-circuits with the 5004 response.
internal final class PinnedSessionProvider: @unchecked Sendable {
    static let shared = PinnedSessionProvider()

    let session: URLSession
    private let pinner = DynamicSPKIPinner()
    private let pinningDelegate: PinningURLSessionDelegate

    private let stateLock = NSLock()
    private var _isPinFailedPersistent = false
    private var sslKind: OtplessSslKind = .sslDisabled
    private var manager: OtplessSslPinManager?

    private init() {
        let pinningDelegate = PinningURLSessionDelegate(pinner: pinner)
        self.pinningDelegate = pinningDelegate
        self.session = URLSession(configuration: .default, delegate: pinningDelegate, delegateQueue: nil)
        pinningDelegate.onPinFailure = { [weak self] host in
            self?.handlePersistentPinFailure(host: host)
        }
        pinningDelegate.managerProvider = { [weak self] in
            self?.currentManager()
        }
        pinningDelegate.isPinningDisabled = { [weak self] in
            guard let self = self else { return false }
            if case .sslDisabled = self.currentSslKind() { return true }
            return false
        }
    }

    /// Applies the merchant's SSL mode. Called synchronously at the top of every
    /// `Otpless.initialise` so the pin set is in place before any request can fire; for
    /// `.sslEnabled` the (async) envelope bootstrap is then driven by `bootstrap()` from the
    /// init task. Re-initialising resets the persistent-failure latch, matching Android where
    /// each `initialise` builds a fresh pinning stack.
    func configure(sslKind: OtplessSslKind) {
        stateLock.lock()
        self.sslKind = sslKind
        self._isPinFailedPersistent = false
        switch sslKind {
        case .sslDisabled:
            self.manager = nil
            stateLock.unlock()
            pinner.setPins([:])
            log(message: "[Pin] SSL pinning disabled by merchant", type: .PIN_VALIDATION)
            OtplessBMEvents.Pin.disabledByOverride(reason: "ssl_disabled")
        case .sslEnabled:
            let manager = OtplessSslPinManager(pinner: pinner)
            self.manager = manager
            stateLock.unlock()
            pinner.setPins(OtplessKeyVault.baselinePins)
            log(message: "[Pin] Baseline pins installed for hosts: \(OtplessKeyVault.baselinePins.keys.sorted().joined(separator: ", "))", type: .PIN_VALIDATION)
        }
    }

    /// Runs the cache-first envelope bootstrap for `.sslEnabled`; no-op in other modes. Called
    /// from the SDK init task, before init resolves, so `start()`'s `isOkSsl` gate observes the
    /// outcome.
    func bootstrap() async {
        await currentManager()?.bootstrap()
    }

    /// Gate `Otpless.start` checks before dispatching a request — mirror of Android's
    /// `OtplessService.isOkSsl()`. `.sslDisabled` and `.customSsl` are always ready;
    /// `.sslEnabled` is ready only once the initial envelope load succeeded.
    var isOkSsl: Bool {
        switch currentSslKind() {
        case .sslDisabled:
            return true
        case .sslEnabled:
            return currentManager()?.isSslDone ?? false
        }
    }

    var isPinFailedPersistent: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isPinFailedPersistent
    }

    private func currentSslKind() -> OtplessSslKind {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sslKind
    }

    private func currentManager() -> OtplessSslPinManager? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return manager
    }

    private func handlePersistentPinFailure(host: String) {
        stateLock.lock()
        _isPinFailedPersistent = true
        stateLock.unlock()
        log(
            message: "[Pin] Validation failed for host: \(host) — failing closed for the rest of this session",
            type: .PIN_VALIDATION
        )
    }
}
