//
//  PinningURLSessionDelegate.swift
//  OtplessBM
//

import Foundation

/// Evaluates default system trust first (pinning is additive, never a replacement for normal CA
/// validation — reject immediately on failure without even reaching pin comparison), then checks
/// the presented chain's SPKI against the live pin set in `DynamicSPKIPinner`. Hosts with no
/// configured pins pass through untouched.
///
/// On a pin mismatch this mirrors Android's `PinEnforcementNetworkInterceptor`: if the envelope
/// manager exists and finished its initial load (`isSslDone`), delegate to
/// `OtplessSslPinManager.handlePinFailure()` for a one-shot envelope refresh, then re-check the
/// same server trust against the refreshed pins. Before the initial load — or in modes with no
/// refreshable source (`.customSsl` / `.sslDisabled`) — there is no safe recovery, so the
/// challenge is cancelled outright. The connection is never allowed to proceed under an
/// unverified pin set.
internal final class PinningURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pinner: DynamicSPKIPinner

    /// Both set once, immediately after construction, by `PinnedSessionProvider` — they need to
    /// reference the provider/manager, which is what constructs this delegate in the first place.
    var onPinFailure: (@Sendable (String) -> Void)?
    var managerProvider: (@Sendable () -> OtplessSslPinManager?)?
    /// True while the SDK runs in `.sslDisabled` mode — pin comparison is skipped entirely and
    /// only system trust applies.
    var isPinningDisabled: (@Sendable () -> Bool)?

    init(pinner: DynamicSPKIPinner) {
        self.pinner = pinner
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if isPinningDisabled?() == true {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        let host = challenge.protectionSpace.host
        if pinner.check(trust: trust, host: host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard let manager = managerProvider?(), manager.isSslDone else {
            onPinFailure?(host)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // One-shot self-heal: refresh the envelope, then re-check the SAME server trust against
        // the refreshed pins. The completion handler is deliberately called asynchronously —
        // URLSession keeps the connection parked until we answer.
        let pinner = self.pinner
        let onPinFailure = self.onPinFailure
        Task {
            let action = await manager.handlePinFailure()
            OtplessBMEvents.Pin.validationFailedAndEnvelopeRefreshed(host: host, data: [
                "sslDone": true,
                "refreshAction": action == .retryWithNewPins ? "RETRY_WITH_NEW_PINS" : "FAIL_CLOSED"
            ])
            if action == .retryWithNewPins, pinner.check(trust: trust, host: host) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                onPinFailure?(host)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
