//
//  OtplessSessionManager.swift
//  OtplessSwiftLP
//
//  Created by Digvijay Singh on 18/09/25.
//

import Foundation

public actor OtplessSessionManager {

    
    public static let shared = OtplessSessionManager()
    internal static let appIdAtomicBox = AtomicBox<String>("")
    internal static let isInitAtomicBox = AtomicBox<Bool>(false)

    private let AUTHENTICATION_LOOP_TIME: UInt64 = 3 * 60 * 1_000_000_000 // 3 minutes in ns
    private let ORIGIN: String = "https://otpless.com"

    internal nonisolated var appId: String {
        Self.appIdAtomicBox.get()
    }
    private var state: String = ""
    private var authenticationTask: Task<Void, Never>?
    private let sessionService = SessionServiceImpl()
    
    internal nonisolated var isInit: Bool {
        Self.isInitAtomicBox.get()
    }
    
    private init() {
    }

    public func initialize(appId: String) {
        Self.appIdAtomicBox.setOn(new: appId, onCondition: { $0.isEmpty })
        // set value true if current value is false
        Self.isInitAtomicBox.setOn(new: true, onCondition: { !$0 })
    }

    public func getActiveSession() async -> OtplessSessionState {
        sendEvent(event: EventConstants.getActiveSession)
        guard let session = getSavedSession() else {
            DLog("no saved session is available to check, returning inactive session")
            return .inactive
        }
        if isJwtTokenActive(session.jwtToken) {
            DLog("active session available")
            startAuthenticationLoopIfNotStarted()
            return .active(session.jwtToken)
        }
        DLog("session expired, refreshing jwt")
        let refreshStateResponse = await refreshJwtToken(oldSessionInfo: session)
        if case .active = refreshStateResponse {
            startAuthenticationLoopIfNotStarted()
        }
        return refreshStateResponse
    }

    public func logout() async {
        guard let session = getSavedSession() else {
            DLog("no session available to logout")
            return
        }
        sendEvent(event: EventConstants.logoutSession)
        DLog("session logout is in progress")
        let loginUri = "\(ORIGIN)/rc5/appid/\(appId)"
        let requestMap: [String: String] = [
            "appId": self.appId,
            "origin": ORIGIN,
            "loginUri": loginUri
        ]
        // after loading the data delete the stored data
        deleteSession()
        authenticationTask?.cancel()
        // server-side delete (best-effort)
        let response = await sessionService.deleteSession(
            sessionToken: session.sessionToken, headers: makeHeaderMap(), body: requestMap
        ).decode(as: DeleteSessionResponse.self)
        switch response {
        case .success(let data):
            DLog("session logout \(data!.success), \(data!.message)")
        case .error:
            DLog("session logout api failed")
        }
    }

    internal func saveSessionAndState(_ sessionInfo: OtplessSessionInfo, state: String) async {
        saveSession(sessionInfo)
        self.state = state
        SecureStorage.shared.save(key: SessionStorageKeys.state, value: state)
    }

    internal func saveSession(_ sessionInfo: OtplessSessionInfo) {
        if let json = try? JSONEncoder().encode(sessionInfo),
           let str = String(data: json, encoding: .utf8) {
            SecureStorage.shared.save(key: SessionStorageKeys.session, value: str)
        }
    }

    internal func getSavedSession() -> OtplessSessionInfo? {
        let jsonString = SecureStorage.shared.retrieve(key: SessionStorageKeys.session) ?? ""
        guard !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8),
              let obj = try? JSONDecoder().decode(OtplessSessionInfo.self, from: data) else {
            return nil
        }
        return obj
    }

    private func isJwtTokenActive(_ jwt: String) -> Bool {
        // Parse JWT payload and check exp > now
        // base64url parts: header.payload.signature
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return false }
        let payloadB64 = String(parts[1])

        guard let payloadData = base64URLDecode(payloadB64),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return false
        }

        let exp = (json["exp"] as? NSNumber)?.int64Value ?? 0
        let now = Int64(Date().timeIntervalSince1970)
        return exp > now
    }

    private func base64URLDecode(_ input: String) -> Data? {
        var s = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // pad
        let padLen = 4 - (s.count % 4)
        if padLen < 4 {
            s.append(String(repeating: "=", count: padLen))
        }
        return Data(base64Encoded: s)
    }

    private func makeHeaderMap() -> [String: String] {
        var headers: [String: String] = [:]
        headers["appId"] = self.appId
        if self.state.isEmpty {
            self.state = SecureStorage.shared.retrieve(key: SessionStorageKeys.state) ?? ""
        }
        headers["state"] = self.state
        return headers
    }

    private func refreshJwtToken(oldSessionInfo: OtplessSessionInfo) async -> OtplessSessionState {
        DLog("refresh session token started")
        let loginUri = "\(ORIGIN)/rc5/appid/\(appId)"
        let requestMap: [String: String] = [
            "appId": self.appId,
            "refreshToken": oldSessionInfo.refreshToken,
            "origin": ORIGIN,
            "loginUri": loginUri
        ]

        switch await sessionService.refreshSession(headers: makeHeaderMap(), body: requestMap)
            .decode(as: OtplessSessionInfo.self) {
        case .success(let data):
            if isJwtTokenActive(data!.jwtToken) {
                DLog("refresh success saving new jwt token")
                let newInfo = OtplessSessionInfo(
                    sessionToken: oldSessionInfo.sessionToken,
                    refreshToken: oldSessionInfo.refreshToken,
                    jwtToken: data!.jwtToken
                )
                saveSession(newInfo)
                return .active(data!.jwtToken)
            } else {
                DLog("refresh success but jwt token is not active")
                return .inactive
            }
        case .error:
            DLog("failed to refresh jwt token")
            return .inactive
        }
    }

    private func startAuthenticationLoopIfNotStarted() {
        if let task = authenticationTask, !task.isCancelled {
            // Already running
            DLog("authentication loop is already active")
            return
        }

        authenticationTask = Task.detached { [weak self] in
            guard let self else { return }
            DLog("authentication loop started")

            while !Task.isCancelled {
                DLog("waiting to go in session authentication")
                try? await Task.sleep(nanoseconds: self.AUTHENTICATION_LOOP_TIME)

                if Task.isCancelled { break }
                DLog("session authentication started")

                // Note: actor hop
                let saved = await self.getSavedSession()
                guard let savedSessionInfo = saved else { continue }

                let loginUri = "\(self.ORIGIN)/rc5/appid/\(await self.appId)"
                let request: [String: String] = [
                    "sessionToken": savedSessionInfo.sessionToken,
                    "sessionTokenJWT": savedSessionInfo.jwtToken,
                    "appId": await self.appId,
                    "origin": self.ORIGIN,
                    "loginUri": loginUri
                ]

                let result = await sessionService.authenticateSession(headers: self.makeHeaderMap(), body: request)
                    .decode(as: AuthenticateSessionResponse.self)
                switch result {
                case .success(let resp):
                    let newJwt = resp!.sessionTokenJWT
                    if await self.isJwtTokenActive(newJwt) {
                        DLog("saving new jwt token")
                        let newInfo = OtplessSessionInfo(
                            sessionToken: savedSessionInfo.sessionToken,
                            refreshToken: savedSessionInfo.refreshToken,
                            jwtToken: newJwt
                        )
                        await self.saveSession(newInfo)
                    } else {
                        DLog("new jwt token is expired")
                    }
                case .error:
                    DLog("failed to fetch new jwt token")
                }
            }
        }
    }
    
    private func deleteSession() {
        for key in [SessionStorageKeys.session, SessionStorageKeys.state] {
            SecureStorage.shared.delete(key: key)
        }
    }
}


internal final class AtomicBox<T> {
    private let lock = NSLock()
    private var value: T
    public init(_ value: T) { self.value = value }

    func get() -> T {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func setOn(new newValue: T, onCondition onCondition: (T) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        if onCondition(value) { value = newValue }
    }
}
