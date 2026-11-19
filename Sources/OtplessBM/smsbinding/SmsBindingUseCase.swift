import Foundation

internal enum SmsBindingOutcome: Equatable, Sendable {
    case verified(bindingId: String?, mobile: String? = nil, userId: String? = nil)
    case failed(SmsBindingFailure)
}

/// One outbound SMS binding attempt on iOS (PRD sections 11 and 13).
///
/// Order: fetch the client's effective rules, run the device rules, ask the backend for a token
/// and VMN, show the composer, apply the rules that depend on how the user sent it (R19, R20,
/// R21), report what the device saw, then wait for the backend's verdict. Every decision comes
/// from the rules; nothing here knows which template a client was onboarded with.
internal final class SmsBindingUseCase: @unchecked Sendable {

    /// R21: the ICCID token must be requested within this long of sending.
    static let iccidWindow: TimeInterval = 30
    /// How long one verdict long-poll may be held open (the backend keeps it at or under 20 s).
    static let longPollSeconds = 20
    /// Cadence when the backend answers without waiting, or a call fails.
    static let fallbackPollInterval: TimeInterval = 1.5
    /// Extra time after the token expires for the backend to publish the final state.
    static let verdictGrace: TimeInterval = 10
    private static let reportAttempts = 2

    private let backend: SmsBindingBackend
    private let composer: SmsBindingComposer
    private let iccid: IccidTokenProvider
    private let device: SmsBindingDevice
    private let prompter: SmsBindingPrompter
    private let lastAttempt: SmsBindingLastAttempt
    private let boundNumbers: BoundNumberStore
    private let blockMemory: SmsBindingBlockMemory
    private let makeSessionGuard: @Sendable () -> SmsBindingSessionGuard
    private let planStatusSupported: @Sendable () -> Bool
    private let sdkVersion: String
    private let deviceFingerprintHash: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void

    init(
        backend: SmsBindingBackend,
        composer: SmsBindingComposer = LiveSmsBindingComposer(),
        iccid: IccidTokenProvider = LiveIccidTokenProvider(),
        device: SmsBindingDevice = LiveSmsBindingDevice(),
        prompter: SmsBindingPrompter = HeadlessSmsBindingPrompter(),
        planStatusSupported: @escaping @Sendable () -> Bool = { LivePlanStatusProvider().isSupported },
        lastAttempt: SmsBindingLastAttempt = SmsBindingLastAttempt(),
        boundNumbers: BoundNumberStore = InMemoryBoundNumberStore(),
        blockMemory: SmsBindingBlockMemory = SmsBindingBlockMemory(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard),
        sessionGuard: @escaping @Sendable () -> SmsBindingSessionGuard = { LiveSmsBindingSessionGuard() },
        sdkVersion: String = Constants.SDK_VERSION,
        deviceFingerprintHash: @escaping @Sendable () -> String? = { nil },
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        }
    ) {
        self.backend = backend
        self.composer = composer
        self.iccid = iccid
        self.device = device
        self.prompter = prompter
        self.lastAttempt = lastAttempt
        self.boundNumbers = boundNumbers
        self.blockMemory = blockMemory
        self.makeSessionGuard = sessionGuard
        self.planStatusSupported = planStatusSupported
        self.sdkVersion = sdkVersion
        self.deviceFingerprintHash = deviceFingerprintHash
        self.now = now
        self.sleep = sleep
    }

    /// Set by `run` when it ends in "device blocked": seconds until the user may try again, if known.
    /// Read after `run` returns.
    private(set) var lastRetryAfterSeconds: Int?

    func run(
        state: String,
        msisdn: String,
        countryCode: String? = nil,
        upiEntitlementDeclared: Bool,
        previousAttemptId: String? = nil,
        onState: (@Sendable (SmsBindingState) -> Void)? = nil
    ) async -> SmsBindingOutcome {

        lastRetryAfterSeconds = nil

        // 1. Explain the step, and on a dual-SIM phone name the line to send from. Asked before the
        // attempt exists, so declining costs nothing (R10 counts attempts). Headless mode skips it.
        if await !prompter.confirmBeforeSend(
            lastDigits: String(msisdn.filter { $0.isNumber }.suffix(4)),
            dualSim: device.activeLineCount > 1
        ) {
            return .failed(.smsSendFailed)
        }

        // 2. Token, number and rules. The rules the client is on come back with the token, so the
        // device rules can only run after the attempt exists.
        let started: SmsBindingStarted
        do {
            started = try await backend.startAttempt(
                state: state,
                request: SmsBindingStartRequest(
                    msisdn: msisdn,
                    countryCode: countryCode,
                    osVersion: device.osVersion,
                    appVersion: device.appVersion,
                    sdkVersion: sdkVersion,
                    deviceFingerprintHash: deviceFingerprintHash(),
                    previousAttemptId: previousAttemptId ?? lastAttempt.previous(for: msisdn),
                    upiEntitlementDeclared: upiEntitlementDeclared,
                    iccidTokenSupported: device.supportsIccidToken,
                    planStatusSupported: planStatusSupported()
                )
            )
        } catch {
            lastRetryAfterSeconds = retryHint(for: error)
            return .failed(Self.failure(from: error))
        }
        blockMemory.remember(started.rules.attemptBlockHours)
        let issued = started.issued
        let rules = started.rules
        let issuedAt = now()
        var attempt = SmsBindingAttempt(
            attemptId: issued.attemptId, vmn: issued.vmn, smsBody: issued.smsBody, ttlSeconds: issued.ttlSeconds
        )
        let expiresAt = issuedAt.addingTimeInterval(TimeInterval(issued.ttlSeconds))
        lastAttempt.record(issued.attemptId, for: msisdn)

        // 3. Device rules. The attempt exists by now, so a failure is reported and the token dies.
        if let failure = SmsBindingPrechecks.evaluate(
            rules: rules, device: device, upiEntitlementDeclared: upiEntitlementDeclared
        ) {
            await reportEnd(state, issued.attemptId, event: .failed, reason: failure)
            return .failed(failure)
        }
        onState?(.issued)

        // R9: from here the app must stay in front. Going to the background abandons the attempt.
        let session: SmsBindingSessionGuard = rules.isOn(.singleSession) ? makeSessionGuard() : InactiveSessionGuard()
        session.begin { [self] done in
            Task {
                await reportEnd(state, issued.attemptId, event: .aborted, reason: .sessionInterrupted)
                done()
            }
        }
        defer { session.end() }

        // 4. Composer
        let sent = await composer.present(
            recipient: issued.vmn, body: issued.smsBody, upiValidation: rules.requiresUpiEntitlement
        )

        if session.interrupted { return .failed(.sessionInterrupted) }

        // 5. What the way it was sent means
        switch sent.result {
        case .cancelled:
            await reportBestEffort(state, issued.attemptId, event: .cancelled, reason: .smsSendFailed, outcome: sent)
            return .failed(.smsSendFailed)
        case .failed:
            await reportBestEffort(state, issued.attemptId, event: .failed, reason: .smsSendFailed, outcome: sent)
            return .failed(.smsSendFailed)
        case .sent:
            break
        }
        // R19: Apple's completion is the proof the SMS reached the carrier. Composer ".sent"
        // alone only means the user tapped Send.
        if rules.requiresUpiEntitlement && sent.sendCompletion != true {
            await reportBestEffort(state, issued.attemptId, event: .failed, reason: .smsSendFailed, outcome: sent)
            return .failed(.smsSendFailed)
        }
        // R20
        if let limit = rules.composerReturnLimit, sent.returnSeconds > limit {
            await reportBestEffort(state, issued.attemptId, event: .failed, reason: .tokenExpired, outcome: sent)
            return .failed(.tokenExpired)
        }
        // R3, measured locally from when the token arrived
        if now() >= expiresAt {
            await reportBestEffort(state, issued.attemptId, event: .failed, reason: .tokenExpired, outcome: sent)
            return .failed(.tokenExpired)
        }

        // 6. R21: ICCID token, within the window after sending. A nil token is marked, not failed.
        var tokenResult: IccidTokenResult?
        if rules.requiresIccidToken {
            let remaining = max(0, Self.iccidWindow - now().timeIntervalSince(sent.returnedAt))
            tokenResult = (try? await AsyncUtils.withTimeout(seconds: remaining) { [iccid] in await iccid.fetch() }) ?? .nilToken
        }

        // 7. Tell the backend what the device saw
        await reportBestEffort(
            state, issued.attemptId, event: .sent, reason: nil, outcome: sent,
            iccid: tokenResult, iccidRequired: rules.requiresIccidToken
        )
        attempt.advance(to: .sent)
        onState?(.sent)
        prompter.showProgress(expiresAt: expiresAt)

        // 8. Wait for the verdict
        return await awaitVerdict(state: state, msisdn: msisdn, attempt: &attempt, issuedAt: issuedAt, session: session, onState: onState)
    }

    // MARK: - Verdict

    private func awaitVerdict(
        state: String,
        msisdn: String,
        attempt: inout SmsBindingAttempt,
        issuedAt: Date,
        session: SmsBindingSessionGuard,
        onState: (@Sendable (SmsBindingState) -> Void)?
    ) async -> SmsBindingOutcome {
        let deadline = issuedAt.addingTimeInterval(TimeInterval(attempt.ttlSeconds) + Self.verdictGrace)
        var sinceVersion: Int?

        while now() < deadline {
            if session.interrupted { return .failed(.sessionInterrupted) }
            let remaining = Int(deadline.timeIntervalSince(now()).rounded(.up))
            do {
                let verdict = try await backend.verdict(
                    state: state,
                    attemptId: attempt.attemptId,
                    sinceVersion: sinceVersion,
                    waitSeconds: max(1, min(Self.longPollSeconds, remaining))
                )
                let progressed = verdict.stateVersion != sinceVersion
                sinceVersion = verdict.stateVersion

                switch verdict.state {
                case .verified:
                    lastAttempt.clear()
                    // The number is bound: from now on `checkSimBinding()` and the listener know it.
                    boundNumbers.save(msisdn)
                    attempt.advance(to: .verified)
                    prompter.updateProgress(.verified)
                    onState?(.verified)
                    return .verified(bindingId: verdict.bindingId, mobile: verdict.mobile, userId: verdict.userId)
                case .rejected:
                    onState?(.rejected)
                    return .failed(SmsBindingFailure(backendReason: verdict.reason))
                case .expired:
                    onState?(.expired)
                    return .failed(.tokenExpired)
                case .aborted:
                    onState?(.aborted)
                    return .failed(verdict.reason.map { SmsBindingFailure(backendReason: $0) } ?? .sessionInterrupted)
                case .issued, .sent, .received:
                    // `advance` accepts a repeat of the current state, so compare: progress is
                    // reported when the state changes, not on every poll that confirms it.
                    let before = attempt.state
                    attempt.advance(to: verdict.state)
                    if attempt.state != before {
                        prompter.updateProgress(attempt.state)
                        onState?(attempt.state)
                    }
                    // A backend that answers at once (no long-poll) must not be hammered.
                    if !progressed { await sleep(Self.fallbackPollInterval) }
                }
            } catch SmsBindingBackendError.rejected(let failure, _) {
                return .failed(failure)
            } catch {
                await sleep(Self.fallbackPollInterval)
            }
        }
        return .failed(.tokenExpired)
    }

    // MARK: - Reporting

    /// A report that fails must not end the attempt: the VMN callback is the deciding proof and
    /// may still verify it. Tries twice, then moves on.
    private func reportBestEffort(
        _ state: String,
        _ attemptId: String,
        event: SmsBindingReport.Event,
        reason: SmsBindingFailure?,
        outcome: SmsComposerOutcome,
        iccid: IccidTokenResult? = nil,
        iccidRequired: Bool = false
    ) async {
        let iccidStatus: String
        var iccidToken: String?
        switch iccid {
        case .token(let value)?: iccidStatus = "OK"; iccidToken = value
        case .nilToken?: iccidStatus = "NIL"
        case .unsupported?: iccidStatus = "UNSUPPORTED"
        case nil: iccidStatus = iccidRequired ? "NIL" : "NOT_REQUIRED"
        }
        let report = SmsBindingReport(
            event: event,
            at: now(),
            reason: reason,
            ios: SmsBindingReport.IOS(
                composerResult: outcome.result.rawValue,
                sendCompletion: outcome.sendCompletion,
                composerPresentedAt: outcome.presentedAt,
                appRegainedControlAt: outcome.returnedAt,
                returnSeconds: outcome.returnSeconds,
                iccidToken: iccidToken,
                iccidTokenStatus: iccidStatus
            )
        )
        for _ in 0..<Self.reportAttempts {
            if (try? await backend.report(state: state, attemptId: attemptId, report: report)) != nil { return }
        }
    }

    /// Tells the backend the attempt ended without the device sending, which invalidates the token at
    /// once: R9 (the app left the foreground) and a device rule that failed after the token was issued.
    private func reportEnd(_ state: String, _ attemptId: String, event: SmsBindingReport.Event, reason: SmsBindingFailure) async {
        let report = SmsBindingReport(event: event, at: now(), reason: reason, ios: nil)
        for _ in 0..<Self.reportAttempts {
            if (try? await backend.report(state: state, attemptId: attemptId, report: report)) != nil { return }
        }
    }

    /// How long the user must wait after a "device blocked" refusal: the backend's figure when it
    /// gives one, else the block length last seen in the rules.
    private func retryHint(for error: Error) -> Int? {
        guard case SmsBindingBackendError.rejected(.deviceBlocked, let after)? = error as? SmsBindingBackendError else { return nil }
        return after ?? blockMemory.hours.map { $0 * 3600 }
    }

    private static func failure(from error: Error) -> SmsBindingFailure {
        if case SmsBindingBackendError.rejected(let failure, _)? = error as? SmsBindingBackendError { return failure }
        return .internalError
    }
}
