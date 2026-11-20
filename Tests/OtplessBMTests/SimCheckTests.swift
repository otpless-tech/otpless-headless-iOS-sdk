//
//  SimCheckTests.swift
//  OtplessBMTests
//
//  ENG-628: the plan status mapping, the permission helper, the change listener and the user copy.
//  Every expectation for Apple's values comes from what an iOS 27.0.1 device returned (ENG-626).
//

import XCTest
@testable import OtplessBM

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private final class FakePlanStatus: PlanStatusProvider, @unchecked Sendable {
    private let lock = NSLock()
    var supported = true
    var authorization: Result<PlanAuthorization, PlanStatusError> = .success(.authorized)
    var requestAnswer: Result<PlanAuthorization, PlanStatusError> = .success(.authorized)
    var hintAnswer: Result<PlanHint, PlanStatusError> = .success(PlanHint(available: true, highConfidence: true))
    private var _requests = 0
    private var _hints = 0
    var requests: Int { lock.locked { _requests } }
    var hints: Int { lock.locked { _hints } }

    var isSupported: Bool { supported }
    func authorizationStatus(for phoneNumber: String) async throws -> PlanAuthorization { try lock.locked { authorization }.get() }
    func requestAuthorization(for phoneNumber: String) async throws -> PlanAuthorization {
        lock.locked { _requests += 1 }
        return try lock.locked { requestAnswer }.get()
    }
    func hint(for phoneNumber: String) async throws -> PlanHint {
        lock.locked { _hints += 1 }
        return try lock.locked { hintAnswer }.get()
    }
    func set(_ authorization: PlanAuthorization) { lock.locked { self.authorization = .success(authorization) } }
    func set(hint: PlanHint) { lock.locked { hintAnswer = .success(hint) } }
}

private final class MemoryStore: SimBindingStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func last(for phoneNumber: String) -> String? { lock.locked { values[phoneNumber] } }
    func save(_ signature: String, for phoneNumber: String) { lock.locked { values[phoneNumber] = signature } }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var _checks: [OtplessSimBindingCheck] = []
    var checks: [OtplessSimBindingCheck] { lock.locked { _checks } }
    func add(_ check: OtplessSimBindingCheck) { lock.locked { _checks.append(check) } }
}

private final class MemoryBound: BoundNumberStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    var current: String? { lock.locked { value } }
    func save(_ e164: String) { lock.locked { value = e164 } }
}

private let number = "+918980994455"

final class SimCheckTests: XCTestCase {

    private func check(_ fake: FakePlanStatus, _ phone: String = number) async -> Result<OtplessSimBindingCheck, OtplessSimCheckError> {
        await SimBindingChecker(provider: fake).check(phoneNumber: phone)
    }

    // MARK: checkSimBinding mapping

    func testAuthorizedAvailableHighConfidenceIsBound() async throws {
        let fake = FakePlanStatus()
        let v1 = try await check(fake).get()
        XCTAssertEqual(v1, OtplessSimBindingCheck(.bound))
    }

    func testAuthorizedUnavailableHighConfidenceIsNotBound() async throws {
        let fake = FakePlanStatus()
        fake.set(hint: PlanHint(available: false, highConfidence: true))
        let v2 = try await check(fake).get()
        XCTAssertEqual(v2, OtplessSimBindingCheck(.notBound))
    }

    func testLowConfidenceIsUnknownWhicheverWayTheHintPoints() async throws {
        for available in [true, false] {
            let fake = FakePlanStatus()
            fake.set(hint: PlanHint(available: available, highConfidence: false))
            let v3 = try await check(fake).get()
            XCTAssertEqual(v3, .unknown(.lowConfidence))
        }
    }

    func testNotAuthorizedIsUnknownAndTheHintIsNeverRead() async throws {
        // On device an unauthorized number still got `unavailable` + high confidence from the hint.
        // Reading it would call a number "not bound" that nobody was allowed to check.
        let fake = FakePlanStatus()
        fake.set(.notAuthorized)
        fake.set(hint: PlanHint(available: false, highConfidence: true))
        let v4 = try await check(fake).get()
        XCTAssertEqual(v4, .unknown(.notAuthorized))
        XCTAssertEqual(fake.hints, 0)
    }

    func testRestrictedAndNotSupportedAndErrorsMap() async throws {
        let restricted = FakePlanStatus(); restricted.set(.restricted)
        let v5 = try await check(restricted).get()
        XCTAssertEqual(v5, .unknown(.restricted))

        let unsupported = FakePlanStatus(); unsupported.set(.notSupported)
        let v6 = try await check(unsupported).get()
        XCTAssertEqual(v6, .unknown(.apiError))

        let authError = FakePlanStatus(); authError.authorization = .failure(.system)
        let v7 = try await check(authError).get()
        XCTAssertEqual(v7, .unknown(.apiError))

        let hintError = FakePlanStatus(); hintError.hintAnswer = .failure(.timeout)
        let v8 = try await check(hintError).get()
        XCTAssertEqual(v8, .unknown(.apiError))
    }

    func testBeforeIOS27ItIsAnErrorNotAStatus() async throws {
        let fake = FakePlanStatus(); fake.supported = false
        let v9 = await SimBindingChecker(provider: fake).check(phoneNumber: number)
        XCTAssertEqual(v9, .failure(.notSupported))
        XCTAssertEqual(OtplessSimCheckError.notSupported.code, "SIM_CHECK_NOT_SUPPORTED")
    }

    func testANumberThatIsNotE164IsRejectedBeforeAppleIsCalled() async throws {
        let fake = FakePlanStatus()
        for bad in ["8980994455", "+0123456789", "+91 8980994455", "+12", "", "+9189809944551234"] {
            let v10 = await SimBindingChecker(provider: fake).check(phoneNumber: bad)
            XCTAssertEqual(v10, .failure(.invalidPhoneNumber), bad)
        }
        XCTAssertEqual(fake.hints, 0)
    }

    func testAppleRawValuesMatchWhatTheDeviceReturned() {
        XCTAssertEqual(PlanAuthorization(rawValue: 0), .notAuthorized)
        XCTAssertEqual(PlanAuthorization(rawValue: 1), .authorized)
        XCTAssertEqual(PlanAuthorization(rawValue: 2), .restricted)
        XCTAssertEqual(PlanAuthorization(rawValue: 99), .notSupported)
        XCTAssertEqual(PlanHint(availabilityRaw: 1, confidenceRaw: 1), PlanHint(available: true, highConfidence: true))
        XCTAssertEqual(PlanHint(availabilityRaw: 0, confidenceRaw: 1), PlanHint(available: false, highConfidence: true))
    }

    // MARK: Permission helper

    func testAlreadyGrantedNeverShowsAppleDialogAgain() async throws {
        // Asking again on device re-showed the dialog, and "Not Now" then took the permission away.
        let fake = FakePlanStatus()
        let v11 = try await SimBindingChecker(provider: fake).requestPermission(phoneNumber: number).get()
        XCTAssertEqual(v11, .granted)
        XCTAssertEqual(fake.requests, 0)
    }

    func testAskingWhenNotYetAuthorizedReportsTheAnswer() async throws {
        let allow = FakePlanStatus(); allow.set(.notAuthorized); allow.requestAnswer = .success(.authorized)
        let v12 = try await SimBindingChecker(provider: allow).requestPermission(phoneNumber: number).get()
        XCTAssertEqual(v12, .granted)
        XCTAssertEqual(allow.requests, 1)

        let deny = FakePlanStatus(); deny.set(.notAuthorized); deny.requestAnswer = .success(.notAuthorized)
        let v13 = try await SimBindingChecker(provider: deny).requestPermission(phoneNumber: number).get()
        XCTAssertEqual(v13, .denied)

        let restrictedAfter = FakePlanStatus(); restrictedAfter.set(.notAuthorized); restrictedAfter.requestAnswer = .success(.restricted)
        let v14 = try await SimBindingChecker(provider: restrictedAfter).requestPermission(phoneNumber: number).get()
        XCTAssertEqual(v14, .unavailable)

        let failed = FakePlanStatus(); failed.set(.notAuthorized); failed.requestAnswer = .failure(.system)
        let v15 = try await SimBindingChecker(provider: failed).requestPermission(phoneNumber: number).get()
        XCTAssertEqual(v15, .unavailable)
    }

    func testRestrictedNumberIsUnavailableWithoutAsking() async throws {
        let fake = FakePlanStatus(); fake.set(.restricted)
        let v16 = try await SimBindingChecker(provider: fake).requestPermission(phoneNumber: "+14155550123").get()
        XCTAssertEqual(v16, .unavailable)
        XCTAssertEqual(fake.requests, 0, "restricted numbers get no dialog")
    }

    func testPermissionHelperBeforeIOS27() async throws {
        let fake = FakePlanStatus(); fake.supported = false
        let v17 = await SimBindingChecker(provider: fake).requestPermission(phoneNumber: number)
        XCTAssertEqual(v17, .failure(.notSupported))
    }

    // MARK: Change listener

    private func monitor(_ fake: FakePlanStatus, _ store: MemoryStore, _ out: Collected) -> SimBindingMonitor {
        SimBindingMonitor(phoneNumber: number, checker: SimBindingChecker(provider: fake), store: store, deliver: { out.add($0) })
    }

    func testTheFirstResultIsRememberedWithoutACallback() async throws {
        let out = Collected(), store = MemoryStore()
        await monitor(FakePlanStatus(), store, out).evaluate()
        XCTAssertTrue(out.checks.isEmpty)
        XCTAssertEqual(store.last(for: number), "BOUND")
    }

    func testOnlyAChangeCallsBack() async throws {
        let fake = FakePlanStatus(), out = Collected(), store = MemoryStore()
        let m = monitor(fake, store, out)
        await m.evaluate()
        await m.evaluate()
        XCTAssertTrue(out.checks.isEmpty, "same result twice is not a change")

        fake.set(hint: PlanHint(available: false, highConfidence: true))
        await m.evaluate()
        XCTAssertEqual(out.checks, [OtplessSimBindingCheck(.notBound)])

        await m.evaluate()
        XCTAssertEqual(out.checks.count, 1, "and it does not repeat")
    }

    func testAChangeWhileTheAppWasSuspendedIsReportedAtTheNextLaunch() async throws {
        let fake = FakePlanStatus(), out = Collected(), store = MemoryStore()
        await monitor(fake, store, out).evaluate()                         // launch 1 saves BOUND

        fake.set(.notAuthorized)                                           // changed while suspended
        await monitor(fake, store, out).evaluate()                         // launch 2: a new monitor, same store
        XCTAssertEqual(out.checks, [.unknown(.notAuthorized)])
    }

    func testAChangeOfReasonInsideUnknownIsNotAChange() async throws {
        // The ticket: fire when the STATUS changes. unknown stays unknown.
        let fake = FakePlanStatus(), out = Collected(), store = MemoryStore()
        fake.set(.notAuthorized)
        let m = monitor(fake, store, out)
        await m.evaluate()
        fake.set(.restricted)
        await m.evaluate()
        XCTAssertTrue(out.checks.isEmpty, "NOT_AUTHORIZED to RESTRICTED is still unknown")
        XCTAssertEqual(store.last(for: number), "UNKNOWN")

        fake.set(.authorized)
        await m.evaluate()
        XCTAssertEqual(out.checks, [OtplessSimBindingCheck(.bound)], "unknown to bound is a change")
    }

    func testATransientApiErrorIsNeitherSavedNorReported() async throws {
        let fake = FakePlanStatus(), out = Collected(), store = MemoryStore()
        let m = monitor(fake, store, out)
        await m.evaluate()

        fake.authorization = .failure(.system)
        await m.evaluate()
        XCTAssertTrue(out.checks.isEmpty)
        XCTAssertEqual(store.last(for: number), "BOUND")

        fake.set(.authorized)
        await m.evaluate()
        XCTAssertTrue(out.checks.isEmpty, "recovering to the same result is still not a change")
    }

    func testListenerHostRechecksOnAnEventAndStopsOnRemove() async throws {
        let fake = FakePlanStatus(), out = Collected(), store = MemoryStore()
        let center = NotificationCenter()
        let radioChange = Notification.Name("CTServiceRadioAccessTechnologyDidChangeNotification")
        let host = SimBindingListenerHost()
        host.start(
            phoneNumber: number, interval: 3600, checker: SimBindingChecker(provider: fake), store: store,
            listener: { out.add($0) }, center: center, isForeground: { true }
        )
        defer { host.stop() }
        try? await Task.sleep(nanoseconds: 300_000_000)        // launch check saves the baseline
        XCTAssertEqual(store.last(for: number), "BOUND")

        fake.set(hint: PlanHint(available: false, highConfidence: true))
        center.post(name: radioChange, object: nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        try? await Task.sleep(nanoseconds: 200_000_000)        // the callback hops to the main queue
        XCTAssertEqual(out.checks, [OtplessSimBindingCheck(.notBound)])

        host.stop()
        fake.set(hint: PlanHint(available: true, highConfidence: true))
        center.post(name: radioChange, object: nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(out.checks.count, 1, "no callback after the listener is removed")
    }

    // MARK: Copy

    func testEveryFailureHasUserTextAndAnUnknownCodeFallsBackToAGenericOne() {
        let all: [SmsBindingFailure] = [
            .permissionMissing, .noSim, .airplaneMode, .upgradeRequired, .entitlementMissing, .unsafeSmsApp,
            .smsSendFailed, .numberMismatch, .tokenExpired, .sessionInterrupted, .deviceBlocked,
            .vmnPoolUnavailable, .verificationFailed, .internalError
        ]
        for failure in all {
            XCTAssertFalse(SmsBindingCopy.failure(code: failure.rawValue).isEmpty, failure.rawValue)
        }
        XCTAssertEqual(SmsBindingCopy.failure(code: "SDK_NOT_READY"), SmsBindingCopy.failure(code: "INTERNAL_ERROR"))
        XCTAssertEqual(OtplessSmsBindingFailure(.numberMismatch).message, SmsBindingCopy.failure(code: "NUMBER_MISMATCH"))
    }

    func testHeadlessUIDoesNothingAndAlwaysContinues() async throws {
        let headless = HeadlessSmsBindingPrompter()
        let confirmed = await headless.confirmBeforeSend(lastDigits: "4455", dualSim: false)
        let retry = await headless.offerRetry(.tokenExpired, context: SmsBindingFailureContext())
        XCTAssertTrue(confirmed)
        XCTAssertFalse(retry)
    }
}


/// The forms the ENG-628 ticket describes: no number to pass, the SDK keeps the bound one.
final class SimCheckNoArgumentTests: XCTestCase {
    private var savedProvider: PlanStatusProvider!
    private var savedBound: BoundNumberStore!

    override func setUp() {
        super.setUp()
        savedProvider = SimCheckEnvironment.provider
        savedBound = SimCheckEnvironment.boundNumbers
    }

    override func tearDown() {
        SimCheckEnvironment.provider = savedProvider
        SimCheckEnvironment.boundNumbers = savedBound
        Otpless.shared.removeSimBindingListener()
        super.tearDown()
    }

    private func check() async -> Result<OtplessSimBindingCheck, OtplessSimCheckError> {
        await withCheckedContinuation { continuation in Otpless.shared.checkSimBinding { continuation.resume(returning: $0) } }
    }

    func testCheckUsesTheBoundNumber() async throws {
        SimCheckEnvironment.provider = FakePlanStatus()
        SimCheckEnvironment.boundNumbers = MemoryBound(number)
        let result = await check()
        XCTAssertEqual(try result.get(), OtplessSimBindingCheck(.bound))
    }

    func testNothingBoundYetIsAnErrorNotAStatus() async throws {
        SimCheckEnvironment.provider = FakePlanStatus()
        SimCheckEnvironment.boundNumbers = MemoryBound(nil)
        let result = await check()
        XCTAssertEqual(result, .failure(.noBoundNumber))
        XCTAssertEqual(OtplessSimCheckError.noBoundNumber.code, "NO_BOUND_NUMBER")
    }

    func testBeforeIOS27BothFormsAnswerNotSupportedWhateverIsBound() async throws {
        let unsupported = FakePlanStatus(); unsupported.supported = false
        SimCheckEnvironment.provider = unsupported
        SimCheckEnvironment.boundNumbers = MemoryBound(number)
        let result = await check()
        XCTAssertEqual(result, .failure(.notSupported))
        let registered = Otpless.shared.setSimBindingListener { _ in }
        guard case .failure(let error) = registered else { return XCTFail("registering must fail before iOS 27") }
        XCTAssertEqual(error, .notSupported)
    }

    func testTheListenerCanBeSetBeforeAnythingIsBoundAndThenWaits() async throws {
        let fake = FakePlanStatus(), out = Collected(), store = MemoryStore(), bound = MemoryBound(nil)
        let center = NotificationCenter()
        let radio = Notification.Name("CTServiceRadioAccessTechnologyDidChangeNotification")
        let host = SimBindingListenerHost()
        host.start(
            numberProvider: { bound.current }, interval: 3600, checker: SimBindingChecker(provider: fake), store: store,
            listener: { out.add($0) }, center: center, isForeground: { true }
        )
        defer { host.stop() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(store.last(for: number), "no number, so nothing is checked or saved")
        XCTAssertTrue(out.checks.isEmpty)

        bound.save(number)                                   // a binding verifies
        center.post(name: radio, object: nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(store.last(for: number), "BOUND", "now it checks, and records the first result silently")
        XCTAssertTrue(out.checks.isEmpty)

        fake.set(.notAuthorized)
        center.post(name: radio, object: nil)
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(out.checks, [.unknown(.notAuthorized)])
    }
}

/// ENG-628 item 4: what the verify-OTP call says about the SIM on iOS 27 and above.
final class SimBoundForOtpTests: XCTestCase {

    private func value(_ fake: FakePlanStatus, enabled: Bool = true, code: String? = "+91", phone: String? = "8980994455") async -> Bool? {
        await SimBoundForOtp.value(smsBindingEnabled: enabled, provider: fake, countryCode: code, phoneNumber: phone)
    }

    func testBoundIsTrueAndNotBoundIsFalse() async {
        let bound = FakePlanStatus()
        let isBound = await value(bound)
        XCTAssertEqual(isBound, true)

        let notBound = FakePlanStatus()
        notBound.set(hint: PlanHint(available: false, highConfidence: true))
        let isNotBound = await value(notBound)
        XCTAssertEqual(isNotBound, false)
    }

    /// `simBound = false` fails the login, so only a certain answer may produce a value.
    func testAnUncertainAnswerSendsNothing() async {
        for authorization in [PlanAuthorization.notAuthorized, .restricted, .notSupported] {
            let fake = FakePlanStatus(); fake.set(authorization)
            let result = await value(fake)
            XCTAssertNil(result, "\(authorization)")
        }
        let low = FakePlanStatus(); low.set(hint: PlanHint(available: false, highConfidence: false))
        let lowResult = await value(low)
        XCTAssertNil(lowResult, "low confidence")

        let broken = FakePlanStatus(); broken.authorization = .failure(.system)
        let brokenResult = await value(broken)
        XCTAssertNil(brokenResult, "an Apple error")
    }

    func testAppsAndDevicesThatDoNotTakePartSendNothing() async {
        let fake = FakePlanStatus()
        let off = await value(fake, enabled: false)
        XCTAssertNil(off, "SMS binding is not switched on for the app")

        let unsupported = FakePlanStatus(); unsupported.supported = false
        let before27 = await value(unsupported)
        XCTAssertNil(before27, "no plan status API before iOS 27")

        let noPhone = await value(fake, phone: nil)
        XCTAssertNil(noPhone, "an email request")
        let noCode = await value(fake, code: nil)
        XCTAssertNil(noCode)
        let emptyPhone = await value(fake, phone: "")
        XCTAssertNil(emptyPhone)
        XCTAssertEqual(fake.hints, 0, "Apple is not asked when the flow does not take part")
    }

    func testTheNumberIsBuiltFromCountryCodeAndPhone() {
        let fake = FakePlanStatus()
        for (code, expected) in [("+91", "+918980994455"), ("91", "+918980994455"), (" +91 ", "+918980994455")] {
            XCTAssertEqual(
                SimBoundForOtp.e164(smsBindingEnabled: true, provider: fake, countryCode: code, phoneNumber: "8980994455"),
                expected, code
            )
        }
    }

    func testTheVerifyBodyGainsARealBooleanOnlyWhenThereIsAnAnswer() {
        let base: [String: Any] = ["otp": "123456", "mobile": "8980994455"]
        XCTAssertEqual(SimBoundForOtp.body(base, simBound: nil).keys.sorted(), ["mobile", "otp"], "unchanged without an answer")
        let withTrue = SimBoundForOtp.body(base, simBound: true)
        XCTAssertEqual(withTrue["simBound"] as? Bool, true)
        XCTAssertEqual(withTrue["otp"] as? String, "123456")
        XCTAssertEqual(SimBoundForOtp.body(base, simBound: false)["simBound"] as? Bool, false)
    }
}


// MARK: - OTP_BIND: settle the permission before the OTP screen

final class OtpBindStepTests: XCTestCase {
    private let number = "+918980994455"

    func testOtpBindIsRecognisedFromTheDeliveryChannelStagingSends() {
        // What staging sent after SNA failed: the channel stays OTP and the communication mode is OTP_BIND.
        let staging = OtplessResponse(
            responseType: .INITIATE,
            response: ["deliveryChannel": "OTP_BIND", "requestId": "r", "channel": "OTP", "authType": "OTP"],
            statusCode: 200
        )
        XCTAssertTrue(OtpBindStep.isOtpBind(staging))
    }

    func testOtpBindIsAlsoRecognisedWhenTheChannelIsNamedOtpBind() {
        let named = OtplessResponse(responseType: .INITIATE, response: ["channel": "OTP_BIND"], statusCode: 200)
        XCTAssertTrue(OtpBindStep.isOtpBind(named))
    }

    func testOtherResponsesAreNotOtpBind() {
        func initiate(_ delivery: String) -> OtplessResponse {
            OtplessResponse(responseType: .INITIATE, response: ["deliveryChannel": delivery, "channel": "OTP", "authType": "OTP"], statusCode: 200)
        }
        XCTAssertFalse(OtpBindStep.isOtpBind(initiate("SMS")))
        XCTAssertFalse(OtpBindStep.isOtpBind(initiate("WHATSAPP")))
        XCTAssertFalse(OtpBindStep.isOtpBind(OtplessResponse(responseType: .VERIFY, response: ["deliveryChannel": "OTP_BIND"], statusCode: 400)),
                       "only an INITIATE starts the code step")
        XCTAssertFalse(OtpBindStep.isOtpBind(nil))
    }

    func testAnUndecidedNumberGetsAppleDialogOnce() async {
        let fake = FakePlanStatus()
        fake.set(.notAuthorized)
        fake.requestAnswer = .success(.authorized)
        let result = await OtpBindStep.settlePermission(provider: fake, e164: number)
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(fake.requests, 1)
    }

    func testAPermissionAlreadyHeldIsNeverAskedForAgain() async {
        let fake = FakePlanStatus()
        fake.set(.authorized)
        let result = await OtpBindStep.settlePermission(provider: fake, e164: number)
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(fake.requests, 0, "asking again would show the dialog again, and Not Now would remove the permission")
    }

    func testARefusalIsReportedAndDoesNotThrow() async {
        let fake = FakePlanStatus()
        fake.set(.notAuthorized)
        fake.requestAnswer = .success(.notAuthorized)
        let result = await OtpBindStep.settlePermission(provider: fake, e164: number)
        XCTAssertEqual(result, .denied)
    }

    func testARestrictedNumberIsUnavailableWithNoDialog() async {
        let fake = FakePlanStatus()
        fake.set(.restricted)
        let result = await OtpBindStep.settlePermission(provider: fake, e164: number)
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(fake.requests, 0)
    }

    func testBeforeIOS27ThereIsNothingToSettle() async {
        let fake = FakePlanStatus()
        fake.supported = false
        let result = await OtpBindStep.settlePermission(provider: fake, e164: number)
        XCTAssertNil(result)
        XCTAssertEqual(fake.requests, 0)
    }

    func testAnEmailRequestHasNoNumberToSettle() async {
        let result = await OtpBindStep.settlePermission(provider: FakePlanStatus(), e164: nil)
        XCTAssertNil(result)
    }

    func testANewNumberIsSettledAgain() async {
        let fake = FakePlanStatus()
        fake.set(.notAuthorized)
        fake.requestAnswer = .success(.authorized)
        _ = await OtpBindStep.settlePermission(provider: fake, e164: number)
        _ = await OtpBindStep.settlePermission(provider: fake, e164: "+917990283535")
        XCTAssertEqual(fake.requests, 2, "the provider is asked for each number the user enters")
    }
}
