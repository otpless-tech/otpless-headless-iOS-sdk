//
//  StateInvalidRetryTests.swift
//  OtplessBMTests
//
//  End-to-end 7005 (invalid state) handling: the intent and merchant config APIs must drop the
//  cached state, fetch a new one and retry once per session — only when the state came from the
//  local cache. Hermetic: every request is answered by StubURLProtocol, no real network.
//
//  The SDK's pinned URLSession isn't injectable and URLProtocol.registerClass only reaches
//  URLSession.shared, so the stub is put in front of every session by swizzling the
//  URLSessionConfiguration.protocolClasses getter (test-only; no SDK source change).
//

import XCTest
import UIKit
import ObjectiveC
@testable import OtplessBM

extension URLSessionConfiguration {
    /// Swapped with `protocolClasses`, so calling it here reaches the original getter.
    @objc fileprivate func stub_protocolClasses() -> [AnyClass]? {
        let original = stub_protocolClasses() ?? []
        return [StubURLProtocol.self] + original
    }
}

/// Answers every request in-process while active and records the user-auth paths it saw.
private final class StubURLProtocol: URLProtocol {
    private static let installSwizzle: Void = {
        let getter = #selector(getter: URLSessionConfiguration.protocolClasses)
        guard let original = class_getInstanceMethod(URLSessionConfiguration.self, getter),
              let stub = class_getInstanceMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.stub_protocolClasses)) else { return }
        method_exchangeImplementations(original, stub)
    }()
    nonisolated(unsafe) private static var _isActive = false
    /// Installs the swizzle once; while inactive the stub declines every request, so other tests hit the network as usual.
    static var isActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isActive }
        set { _ = installSwizzle; lock.lock(); _isActive = newValue; lock.unlock() }
    }
    typealias Route = (_ path: String) -> (status: Int, json: [String: Any])
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _route: Route = { _ in (200, [:]) }
    nonisolated(unsafe) private static var _paths: [String] = []
    static var route: Route {
        get { lock.lock(); defer { lock.unlock() }; return _route }
        set { lock.lock(); _route = newValue; lock.unlock() }
    }
    static var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return _paths
    }
    static func reset() {
        lock.lock()
        _route = { _ in (200, [:]) }
        _paths = []
        lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { isActive }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        // Only user-auth calls are routed and recorded; anything else (events, CDN) gets an empty 200
        var status = 200
        var json: [String: Any] = [:]
        if url.host == URL(string: Otpless.shared.environment.userAuthBaseURL)?.host {
            StubURLProtocol.lock.lock()
            StubURLProtocol._paths.append(url.path)
            StubURLProtocol.lock.unlock()
            (status, json) = StubURLProtocol.route(url.path)
        }
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class InMemoryKeychainStore: KeychainStore {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    func save(key: String, value: String) { lock.lock(); items[key] = value; lock.unlock() }
    func retrieve(key: String) -> String? { lock.lock(); defer { lock.unlock() }; return items[key] }
    func delete(key: String) { lock.lock(); items[key] = nil; lock.unlock() }
    func clearAll() { lock.lock(); items.removeAll(); lock.unlock() }
}

final class StateInvalidRetryTests: XCTestCase {

    private static let statePath = ApiManager.GET_STATE_PATH
    private static let invalidState: (status: Int, json: [String: Any]) = (400, ["errorCode": "7005", "description": "Invalid state"])
    private static let intentSuccess: (status: Int, json: [String: Any]) = (200, ["quantumLeap": [
        "asId": "as-id", "channel": "OTP", "channelAuthToken": "token", "channels": [String](), "pollingRequired": false,
        "state": "s", "status": "SUCCESS", "timerSettings": ["interval": 1, "timeout": 10], "uid": "uid"
    ]])
    private var originalKeychain: KeychainStore!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.isActive = true
        originalKeychain = SecureStorage.shared.keychain
        SecureStorage.shared.keychain = InMemoryKeychainStore()
        // Not a fresh install, so the seeded keychain state survives initialise
        UserDefaults.standard.set(true, forKey: Constants.INSTALL_MARKER_KEY)
    }

    override func tearDown() {
        StubURLProtocol.isActive = false
        StubURLProtocol.reset()
        SecureStorage.shared.keychain = originalKeychain
        UserDefaults.standard.removeObject(forKey: Constants.INSTALL_MARKER_KEY)
        super.tearDown()
    }

    // MARK: - Helpers

    private static func intentPath(_ state: String) -> String {
        ApiManager.POST_INTENT_PATH.replacingOccurrences(of: "{state}", with: state)
    }

    private static func configPath(_ state: String) -> String {
        ApiManager.GET_MERCHANT_CONFIG_PATH.replacingOccurrences(of: "{state}", with: state)
    }

    /// Runs the real initialise flow (cached state when given, else a remote fetch) and waits for SDK ready.
    private func initialiseSdk(cachedState: String?, file: StaticString = #filePath, line: UInt = #line) async {
        if let cachedState {
            SecureStorage.shared.save(key: Constants.STATE_KEY, value: cachedState)
        }
        await MainActor.run {
            Otpless.shared.initialise(withAppId: "TESTAPPID", vc: UIViewController(), sslKind: .sslDisabled)
        }
        let isReady = await waitUntil { Otpless.shared.isSdkReady() }
        XCTAssertTrue(isReady, "SDK did not become ready", file: file, line: line)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func invokeIntent(state: String) async -> PostIntentUseCaseResponse {
        let request = OtplessRequest()
        request.set(phoneNumber: "9999999999", withCountryCode: "+91")
        return await PostIntentUseCase(others: Otpless.shared).invoke(state: state, withOtplessRequest: request, uiId: nil, uid: nil)
    }

    private func errorCode(_ response: PostIntentUseCaseResponse) -> String? {
        response.otplessResponse?.response?["errorCode"] as? String
    }

    // MARK: - Intent

    func testIntent7005RefreshesCachedStateAndRetriesIntent() async {
        StubURLProtocol.route = { path in
            switch path {
            case Self.intentPath("old-state"): return Self.invalidState
            case Self.statePath: return (200, ["state": "new-state"])
            case Self.intentPath("new-state"): return Self.intentSuccess
            default: return (200, [:])
            }
        }
        await initialiseSdk(cachedState: "old-state")
        let initPaths = StubURLProtocol.paths.count
        let response = await invokeIntent(state: "old-state")
        XCTAssertEqual(Array(StubURLProtocol.paths.dropFirst(initPaths)), [Self.intentPath("old-state"), Self.statePath, Self.intentPath("new-state")])
        XCTAssertNotEqual(errorCode(response), "7005")
        XCTAssertEqual(Otpless.shared.state, "new-state")
        XCTAssertEqual(SecureStorage.shared.retrieve(key: Constants.STATE_KEY), "new-state")
    }

    func testIntent7005RefreshesStateOnlyOncePerSession() async {
        StubURLProtocol.route = { path in
            switch path {
            case Self.configPath("old-state"): return (200, [:])
            case Self.statePath: return (200, ["state": "new-state"])
            default: return Self.invalidState
            }
        }
        await initialiseSdk(cachedState: "old-state")
        let initPaths = StubURLProtocol.paths.count
        // First 7005: one refresh, one retry, and the retry's 7005 is returned
        let first = await invokeIntent(state: "old-state")
        XCTAssertEqual(Array(StubURLProtocol.paths.dropFirst(initPaths)), [Self.intentPath("old-state"), Self.statePath, Self.intentPath("new-state")])
        XCTAssertEqual(errorCode(first), "7005")
        // Second 7005 in the same session: no further refresh
        let afterFirst = StubURLProtocol.paths.count
        let second = await invokeIntent(state: "new-state")
        XCTAssertEqual(Array(StubURLProtocol.paths.dropFirst(afterFirst)), [Self.intentPath("new-state")])
        XCTAssertEqual(errorCode(second), "7005")
    }

    func testIntent7005IsNotRetriedWhenStateWasFetchedFromServer() async {
        StubURLProtocol.route = { path in
            switch path {
            case Self.statePath: return (200, ["state": "remote-state"])
            case Self.configPath("remote-state"): return (200, [:])
            default: return Self.invalidState
            }
        }
        await initialiseSdk(cachedState: nil)
        XCTAssertEqual(Otpless.shared.state, "remote-state")
        let initPaths = StubURLProtocol.paths.count
        let response = await invokeIntent(state: "remote-state")
        XCTAssertEqual(Array(StubURLProtocol.paths.dropFirst(initPaths)), [Self.intentPath("remote-state")])
        XCTAssertEqual(errorCode(response), "7005")
        XCTAssertEqual(Otpless.shared.state, "remote-state")
    }

    func testIntent7005WithFailedStateRefreshReturnsTheError() async {
        StubURLProtocol.route = { path in
            switch path {
            case Self.configPath("old-state"): return (200, [:])
            case Self.statePath: return (500, [:])
            default: return Self.invalidState
            }
        }
        await initialiseSdk(cachedState: "old-state")
        let response = await invokeIntent(state: "old-state")
        XCTAssertEqual(errorCode(response), "7005")
        XCTAssertFalse(StubURLProtocol.paths.contains(Self.intentPath("")), "intent must not be retried with an empty state")
        XCTAssertEqual(Otpless.shared.state, "")
        XCTAssertNil(SecureStorage.shared.retrieve(key: Constants.STATE_KEY))
    }

    // MARK: - Merchant config

    func testMerchantConfig7005DuringInitRefreshesCachedStateAndRetries() async {
        StubURLProtocol.route = { path in
            switch path {
            case Self.configPath("old-state"): return Self.invalidState
            case Self.statePath: return (200, ["state": "new-state"])
            case Self.configPath("new-state"): return (200, [:])
            default: return (200, [:])
            }
        }
        await initialiseSdk(cachedState: "old-state")
        XCTAssertEqual(StubURLProtocol.paths, [Self.configPath("old-state"), Self.statePath, Self.configPath("new-state")])
        XCTAssertEqual(Otpless.shared.state, "new-state")
        XCTAssertEqual(SecureStorage.shared.retrieve(key: Constants.STATE_KEY), "new-state")
    }

    /// The intent call already refreshed the state: config retries with it instead of fetching another.
    func testMerchantConfig7005ReusesStateAlreadyRefreshedByIntent() async {
        StubURLProtocol.route = { path in
            switch path {
            case Self.configPath("old-state"): return StubURLProtocol.paths.filter { $0 == Self.configPath("old-state") }.count == 1 ? (200, [:]) : Self.invalidState
            case Self.intentPath("old-state"): return Self.invalidState
            case Self.statePath: return (200, ["state": "new-state"])
            case Self.intentPath("new-state"): return Self.intentSuccess
            case Self.configPath("new-state"): return (200, [:])
            default: return (200, [:])
            }
        }
        await initialiseSdk(cachedState: "old-state")
        _ = await invokeIntent(state: "old-state")
        XCTAssertEqual(Otpless.shared.state, "new-state")
        let beforeConfig = StubURLProtocol.paths.count
        let (config, error) = await GetMerchantConfigUseCase().invoke(state: "old-state", queryParams: [:], isRetry: false)
        XCTAssertNotNil(config)
        XCTAssertNil(error)
        XCTAssertEqual(Array(StubURLProtocol.paths.dropFirst(beforeConfig)), [Self.configPath("old-state"), Self.configPath("new-state")])
    }

    func testMerchantConfig7005IsNotRefreshedWhenStateWasFetchedFromServer() async {
        StubURLProtocol.route = { path in
            switch path {
            case Self.statePath: return (200, ["state": "remote-state"])
            case Self.configPath("remote-state"): return StubURLProtocol.paths.filter { $0 == Self.configPath("remote-state") }.count == 1 ? (200, [:]) : Self.invalidState
            default: return (200, [:])
            }
        }
        await initialiseSdk(cachedState: nil)
        let beforeConfig = StubURLProtocol.paths.count
        let (config, error) = await GetMerchantConfigUseCase().invoke(state: "remote-state", queryParams: [:], isRetry: false)
        XCTAssertNil(config)
        XCTAssertEqual(error?.response?["errorCode"] as? String, "5003")
        // Only the normal retry, no state fetch
        XCTAssertEqual(Array(StubURLProtocol.paths.dropFirst(beforeConfig)), [Self.configPath("remote-state"), Self.configPath("remote-state")])
    }
}
