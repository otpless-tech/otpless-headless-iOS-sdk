//
//  StateRefreshTests.swift
//  OtplessBMTests
//
//  Covers the 7005 (invalid state) detection, cached-state loading / refresh gating in
//  GetStateUseCase, and the fresh-install keychain cleanup in SecureStorage.
//  Hermetic: no network, no `initialise()`.
//

import XCTest
@testable import OtplessBM

/// The test bundle has no keychain entitlement (SecItemAdd returns -34018), so keychain items live in memory.
private final class InMemoryKeychainStore: KeychainStore {
    private var items: [String: String] = [:]
    func save(key: String, value: String) { items[key] = value }
    func retrieve(key: String) -> String? { items[key] }
    func delete(key: String) { items[key] = nil }
    func clearAll() { items.removeAll() }
}

final class StateRefreshTests: XCTestCase {

    private let storage = SecureStorage.shared
    private let sessionKeys = [SessionStorageKeys.session, SessionStorageKeys.state]
    private var originalKeychain: KeychainStore!

    override func setUp() {
        super.setUp()
        originalKeychain = storage.keychain
        storage.keychain = InMemoryKeychainStore()
        UserDefaults.standard.removeObject(forKey: Constants.INSTALL_MARKER_KEY)
    }

    override func tearDown() {
        storage.keychain = originalKeychain
        UserDefaults.standard.removeObject(forKey: Constants.INSTALL_MARKER_KEY)
        super.tearDown()
    }

    private func seedKeychain() {
        storage.save(key: Constants.STATE_KEY, value: "cached-state")
        storage.save(key: Constants.UID_KEY, value: "cached-uid")
        for key in sessionKeys {
            storage.save(key: key, value: "cached-\(key)")
        }
    }

    // MARK: - ApiError.isStateInvalid

    func testStringErrorCode7005IsStateInvalid() {
        XCTAssertTrue(ApiError(message: "", statusCode: 400, responseJson: ["errorCode": "7005"]).isStateInvalid)
    }

    func testNumericErrorCode7005IsStateInvalid() {
        XCTAssertTrue(ApiError(message: "", statusCode: 400, responseJson: ["errorCode": 7005]).isStateInvalid)
    }

    func testOtherErrorCodesAreNotStateInvalid() {
        XCTAssertFalse(ApiError(message: "", statusCode: 400, responseJson: ["errorCode": "7006"]).isStateInvalid)
        XCTAssertFalse(ApiError(message: "", statusCode: 400, responseJson: ["errorCode": 500]).isStateInvalid)
    }

    /// A 7005 HTTP status without a 7005 errorCode body must not trigger a refresh.
    func testMissingErrorCodeIsNotStateInvalid() {
        XCTAssertFalse(ApiError(message: "", statusCode: 7005, responseJson: nil).isStateInvalid)
        XCTAssertFalse(ApiError(message: "", statusCode: 7005, responseJson: ["description": "x"]).isStateInvalid)
    }

    // MARK: - SecureStorage.clearStaleDataOnFreshInstall

    /// The uid is intentionally kept across reinstalls; state and session must not be.
    func testFreshInstallClearsStateAndSessionButKeepsUid() {
        seedKeychain()
        storage.clearStaleDataOnFreshInstall()
        XCTAssertNil(storage.retrieve(key: Constants.STATE_KEY))
        XCTAssertEqual(storage.retrieve(key: Constants.UID_KEY), "cached-uid")
        for key in sessionKeys {
            XCTAssertNil(storage.retrieve(key: key), "\(key) survived a fresh install")
        }
        XCTAssertTrue(storage.getFromUserDefaults(key: Constants.INSTALL_MARKER_KEY, defaultValue: false))
    }

    func testExistingInstallKeepsKeychainData() {
        UserDefaults.standard.set(true, forKey: Constants.INSTALL_MARKER_KEY)
        seedKeychain()
        storage.clearStaleDataOnFreshInstall()
        XCTAssertEqual(storage.retrieve(key: Constants.STATE_KEY), "cached-state")
        XCTAssertEqual(storage.retrieve(key: Constants.UID_KEY), "cached-uid")
        for key in sessionKeys {
            XCTAssertEqual(storage.retrieve(key: key), "cached-\(key)")
        }
    }

    /// Otpless.initialise and OtplessSessionManager.initialize both call it: only the first call may clear.
    func testSecondCallAfterFreshInstallDoesNotClearNewData() {
        storage.clearStaleDataOnFreshInstall()
        storage.save(key: Constants.STATE_KEY, value: "new-state")
        storage.save(key: SessionStorageKeys.session, value: "new-session")
        storage.clearStaleDataOnFreshInstall()
        XCTAssertEqual(storage.retrieve(key: Constants.STATE_KEY), "new-state")
        XCTAssertEqual(storage.retrieve(key: SessionStorageKeys.session), "new-session")
    }

    // MARK: - GetStateUseCase.loadCachedState

    func testLoadCachedStateReturnsCachedStateAndAllowsRefresh() {
        storage.save(key: Constants.STATE_KEY, value: "cached-state")
        let useCase = GetStateUseCase()
        XCTAssertEqual(useCase.loadCachedState(), "cached-state")
        XCTAssertTrue(useCase.isStateRefreshRequired)
    }

    func testLoadCachedStateWithoutCacheReturnsNilAndDisallowsRefresh() {
        let useCase = GetStateUseCase()
        XCTAssertNil(useCase.loadCachedState())
        XCTAssertFalse(useCase.isStateRefreshRequired)
    }

    func testEmptyCachedStateIsTreatedAsMissing() {
        storage.save(key: Constants.STATE_KEY, value: "")
        let useCase = GetStateUseCase()
        XCTAssertNil(useCase.loadCachedState())
        XCTAssertFalse(useCase.isStateRefreshRequired)
    }

    // MARK: - GetStateUseCase.retryStateLoading gating

    /// A state fetched from the server this session must not be refreshed on 7005: no attempt, cache untouched.
    func testRetryIsSkippedWhenStateWasNotLoadedFromCache() async {
        let useCase = GetStateUseCase()
        XCTAssertNil(useCase.loadCachedState())
        storage.save(key: Constants.STATE_KEY, value: "remote-state")
        let result = await useCase.retryStateLoading(queryParams: [:])
        XCTAssertNil(result)
        XCTAssertEqual(storage.retrieve(key: Constants.STATE_KEY), "remote-state")
    }

    func testRetryIsSkippedBeforeAnyStateIsLoaded() async {
        let result = await GetStateUseCase().retryStateLoading(queryParams: [:])
        XCTAssertNil(result)
    }
}
