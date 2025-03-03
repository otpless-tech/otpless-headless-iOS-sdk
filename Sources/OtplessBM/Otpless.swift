//
//  File.swift
//  otpless-iOS-headless-sdk
//
//  Created by Sparsh on 16/01/25.
//

import Foundation
import UIKit

@objc final public class Otpless: NSObject, @unchecked Sendable {
    @objc public static let shared: Otpless = {
        return Otpless()
    }()
    
    internal private(set) var isOneTapUIDismissed: Bool = false
    internal private(set) var requestCount: Int = 0
    internal private(set) var stateFetchRetriesCount: Int = 0
    
    internal private(set) var merchantAppId: String = ""
    internal private(set) var merchantOtplessRequest: OtplessRequest?
    internal private(set) var state: String?
    internal private(set) var hasMerchantSelectedExternalSDK: Bool = false
    internal private(set) var phoneIntentChannel: String = ""
    internal private(set) var emailIntentChannel: String = ""
    internal private(set) var communicationMode: String = ""
    internal private(set) var authType: String = ""
    
    internal private(set) var uid: String = ""
    internal private(set) var appInfo: [String: Any] = [:]
    internal private(set) var deviceInfo: [String: String] = [:]
    internal private(set) var uiId: [String]?
    internal private(set) var inid: String = ""
    internal private(set) var tsid: String = ""
    internal private(set) var asId: String = ""
    internal private(set) var token: String = ""
    internal private(set) var userSelectedOAuthChannel: OtplessChannelType?
    internal private(set) var merchantLoginUri: String = ""
    internal private(set) var packageName: String = ""
    
    internal private(set) weak var loggerDelegate: OtplessLoggerDelegate?
    internal private(set) weak var responseDelegate: OtplessResponseDelegate?
    internal private(set) weak var oneTapDataDelegate: OneTapDataDelegate?
    
    internal private(set) weak var merchantWindowScene: UIWindowScene?
    
    internal let apiRepository = ApiRepository(userAuthApiTimeout: 30, snaTimeout: 5, enableLogging: true)
    
    internal private(set) var merchantConfig: MerchantConfigResponse? = nil
    
    private lazy var getStateUseCase: GetStateUseCase = {
        return GetStateUseCase()
    }()
    private lazy var getMerchantConfigUseCase: GetMerchantConfigUseCase = {
        return GetMerchantConfigUseCase()
    }()
    private lazy var postIntentUseCase: PostIntentUseCase = {
        return PostIntentUseCase()
    }()
    internal private(set) lazy var transactionStatusUseCase: TransactionStatusUseCase = {
        return TransactionStatusUseCase()
    }()
    internal private(set) lazy var passkeyUseCase: PasskeyUseCase = {
        return PasskeyUseCase()
    }()
    internal private(set) lazy var snaUseCase: SNAUseCase = {
        return SNAUseCase()
    }()
    private lazy var verifyOtpUseCase: VerifyOTPUseCase = {
        return VerifyOTPUseCase()
    }()
    internal private(set) lazy var verifyCodeUseCase: VerifyCodeUseCase = {
        return VerifyCodeUseCase()
    }()
    internal private(set) lazy var appleSignInUseCase: AppleSignInUseCase = {
        return AppleSignInUseCase()
    }()
    
    internal private(set) weak var merchantVC: UIViewController?
    
    private var eventCounter = -1
    private let eventCounterLock = NSLock()
    
    public func setOneTapDataDelegate(_ oneTapDataDelegate: OneTapDataDelegate?) {
        self.oneTapDataDelegate = oneTapDataDelegate
    }
    
    @objc public func initialise(
        withAppId appId: String,
        loginUri: String? = nil,
        vc: UIViewController
    ) {
        self.merchantAppId = appId
        self.merchantVC = vc
        self.uid = SecureStorage.shared.retrieve(key: Constants.UID_KEY) ?? ""
        self.merchantLoginUri = loginUri ?? "otpless.\(appId.lowercased())://otpless"
        initialiseEventCounter()
        
        Task(priority: .background) { [weak self] in
            guard let self = self else { return }
            
            await DeviceInfoUtils.shared.initialise()
            
            let uid = SecureStorage.shared.retrieve(key: Constants.UID_KEY) ?? ""
            let inid = await self.getInidFromMainActor()
            let tsid = await self.getTsidFromMainActor()
            
            self.uid = uid
            self.inid = inid
            self.tsid = tsid
            
            await MainActor.run {
                self.deviceInfo = DeviceInfoUtils.shared.getDeviceInfoDict()
            }
            
            await MainActor.run { [weak self] in
                self?.appInfo = self?.getAppInfoFromMainActor() ?? [:]
            }
            
            self.fetchStateAndMerchantConfig()
        }
    }
    
    @objc public func isOtplessDeeplink(url : URL) -> Bool {
        if let GoogleAuthClass = NSClassFromString("OtplessBM.GIDSignInUseCase") as? NSObject.Type {
            let googleAuthHandler = GoogleAuthClass.init()
            if let handler = googleAuthHandler as? GoogleAuthProtocol {
                let isGIDDeeplink = handler.isGIDDeeplink(url: url)
                if isGIDDeeplink {
                    return true
                }
            }
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: true), let host = components.host {
            switch host {
            case "otpless":
                return true
            default:
                break
            }
        }
        return false
    }
    
    @objc public func start(withRequest otplessRequest: OtplessRequest) async {
        self.merchantOtplessRequest = otplessRequest
        self.userSelectedOAuthChannel = otplessRequest.getSelectedChannelType()
        
        sendEvent(event: .START_HEADLESS, extras: otplessRequest.getEventDict())
        await processRequestIfRequestIsValid(otplessRequest)
    }
    
    @objc public func authorizeViaPasskey(withRequest otplessRequest: OtplessRequest, windowScene: UIWindowScene) async {
        self.merchantOtplessRequest = otplessRequest
        self.merchantWindowScene = windowScene
        await processRequestIfRequestIsValid(otplessRequest)
    }
    
    @objc public func handleDeeplink(_ url: URL) async {
        guard url.host == "otpless" else {
            log(message: "Invalid deeplink: \(url.absoluteString)", type: .INVALID_DEEPLINK)
            return
        }
        
        var code = ""
        
        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in queryItems {
                if item.name.lowercased() == "code" {
                    code = item.value ?? ""
                }
            }
        }
        
        if code.isEmpty {
            return
        }
        
        let response = await verifyCodeUseCase.invoke(
            state: self.state ?? "",
            queryParams: getVerifyCodeQueryParams(code: code),
            getTransactionStatusUseCase: transactionStatusUseCase
        )
        
        if let response = response.0 {
            invokeResponse(response)
        }
        
        if let uid = response.1 {
            SecureStorage.shared.save(key: Constants.UID_KEY, value: uid)
        }
    }
    
    /// Registers the application to use Facebook Login.
    @MainActor
    @objc public func registerFBApp(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) {
        if let FacebookAuthClass = NSClassFromString("OtplessBM.FBSdkUseCase") as? NSObject.Type {
            let facebookAuthHandler = FacebookAuthClass.init()
            if let handler = facebookAuthHandler as? FacebookAuthProtocol {
                handler.register(application, didFinishLaunchingWithOptions: launchOptions)
            }
        }
    }
    
    /// Registers the application to use Facebook Login. To be called from `AppDelegate`
    @MainActor
    @objc public func registerFBApp(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey : Any] = [:]
    ) {
        if let FacebookAuthClass = NSClassFromString("OtplessBM.FBSdkUseCase") as? NSObject.Type {
            let facebookAuthHandler = FacebookAuthClass.init()
            if let handler = facebookAuthHandler as? FacebookAuthProtocol {
                handler.register(app, open: url, options: options)
            }
        }
    }
    
    /// Registers the application to use Facebook Login. To be called from `SceneDelegate`
    @available(iOS 13.0, *)
    @MainActor
    @objc public func registerFBApp(
        openURLContexts URLContexts: Set<UIOpenURLContext>
    ) async {
        if let FacebookAuthClass = NSClassFromString("OtplessBM.FBSdkUseCase") as? NSObject.Type {
            let facebookAuthHandler = FacebookAuthClass.init()
            if let handler = facebookAuthHandler as? FacebookAuthProtocol {
                await handler.register(openURLContexts: URLContexts)
            }
        }
    }
    
    public func commitOtplessResponse(_ otplessResponse: OtplessResponse) {
        if otplessResponse.statusCode == 5005 ||
            (otplessResponse.statusCode >= 9100 && otplessResponse.statusCode <= 9105) {
            sendEvent(event: .HEADLESS_TIMEOUT, extras: merchantOtplessRequest?.getEventDict() ?? [:])
        } else {
            Utils.convertToEventParamsJson(
                otplessResponse: otplessResponse,
                callback: { extras, requestId, musId in
                    sendEvent(event: .HEADLESS_RESPONSE_SDK, extras: extras, musId: musId ?? "", requestId: requestId ?? "")
                }
            )
        }
    }
    
    public func performOneTap(forIdentity oneTapIdentity: OneTapIdentity) async {
        let oneTapRequest = OtplessRequest()
        oneTapRequest.set(oneTapValue: oneTapIdentity.identity)
        let intentResponse = await postIntentUseCase.invoke(state: self.state ?? "", withOtplessRequest: oneTapRequest, uiId: [oneTapIdentity.uiId], uid: self.uid)
        
        if let otplessResponse = intentResponse.otplessResponse {
            invokeResponse(otplessResponse)
        }
    }
}

internal extension Otpless {
    func onAuthTypeChange(newAuthType: String) {
        self.authType = newAuthType
    }
    
    func onCommunicationModeChange(_ newCommunicationMode: String) {
        self.communicationMode = newCommunicationMode
    }
}

// MARK: Getters and Setters
extension Otpless {
    public func setResponseDelegate(_ otplessResponseDelegate: OtplessResponseDelegate) {
        self.responseDelegate = otplessResponseDelegate
        sendEvent(event: .SET_HEADLESS_CALLBACK)
    }
    
    public func setLoggerDelegate(_ otplessLoggerDelegate: OtplessLoggerDelegate) {
        self.loggerDelegate = otplessLoggerDelegate
    }
    
    func setPackageName(_ pName: String) {
        self.packageName = pName
    }
    
    public func clearAll() {
        SecureStorage.shared.clearAll()
    }
}

private extension Otpless {
    func fetchStateAndMerchantConfig() {
        requestStateForDeviceIfNil(onFetch: { [weak self] state in
            guard let state = state else {
                return
            }
            
            self?.state = state
            SecureStorage.shared.save(key: Constants.STATE_KEY, value: state)
            sendEvent(event: .INIT_HEADLESS)
            self?.fetchMerchantConfig()
        })
    }
    
    func requestStateForDeviceIfNil(onFetch: @escaping @Sendable (String?) -> Void) {
        if let savedState = SecureStorage.shared.retrieve(key: Constants.STATE_KEY),
           !savedState.isEmpty {
            onFetch(savedState)
        } else {
            Task.detached { [weak self] in
                let stateResponse = await self?.getStateUseCase
                    .invoke(queryParams: self?.getMerchantConfigQueryParams() ?? [:], isRetry: false)
                let state = stateResponse?.0?.state
                if let otplessResponse = stateResponse?.1 {
                    self?.invokeResponse(otplessResponse)
                }
                await MainActor.run(body: {
                    onFetch(state)
                })
            }
        }
    }
    
    func fetchMerchantConfig() {
        if let state = self.state {
            Task.detached { [weak self] in
                let configResponse = await self?.getMerchantConfigUseCase.invoke(state: state, queryParams: [:], isRetry: false)
                self?.merchantConfig = configResponse?.0
                self?.phoneIntentChannel = self?.getIntentChannelFromConfig(channelConfig: configResponse?.0?.channelConfig, isMobile: true) ?? ""
                self?.emailIntentChannel = self?.getIntentChannelFromConfig(channelConfig: configResponse?.0?.channelConfig, isMobile: false) ?? ""
                
                if let otplessResponse = configResponse?.1 {
                    self?.invokeResponse(otplessResponse)
                }
                
                if let oneTapDataDelegate = self?.oneTapDataDelegate {
                    await oneTapDataDelegate.onOneTapData(configResponse?.0?.userDetails?.toOneTapIdentities())
                }
            }
        }
    }
    
    func processRequestIfRequestIsValid(_ otplessRequest: OtplessRequest) async {
        if await !canRequestBeMade(request: otplessRequest, shouldRetryStateAndMerchantConfigFetch: nil) {
            return
        }
        
        if !otplessRequest.hasOtp() && otplessRequest.getRequestId().isEmpty {
            let oneTapIdentity = await showOneTapViewIfIdentityExists(request: otplessRequest)
            if let identity = oneTapIdentity {
                let oneTapRequest = OtplessRequest()
                oneTapRequest.set(oneTapValue: identity.identity)
                let intentResponse = await postIntentUseCase.invoke(state: self.state ?? "", withOtplessRequest: oneTapRequest, uiId: [identity.uiId], uid: self.uid)
                
                if let otplessResponse = intentResponse.otplessResponse {
                    invokeResponse(otplessResponse)
                }
                return
            }
        }
        
        if !otplessRequest.isIntentRequest() {
            let verifyOtpResponse = await verifyOtpUseCase.invoke(
                state: self.state ?? "",
                queryParams: otplessRequest.getQueryParams(),
                getTransactionStatusUseCase: self.transactionStatusUseCase
            )
            invokeResponse(verifyOtpResponse)
            return
        }
        
        let intentResponse = await postIntentUseCase.invoke(
            state: self.state ?? "",
            withOtplessRequest: otplessRequest,
            uiId: self.uiId,
            uid: self.uid
        )
        
        if let otplessResponse = intentResponse.otplessResponse {
            invokeResponse(otplessResponse)
        }
        
        if let tokenAsIdUIdAndTimerSettings = intentResponse.tokenAsIdUIdAndTimerSettings {
            self.token = tokenAsIdUIdAndTimerSettings.token ?? ""
            self.asId = tokenAsIdUIdAndTimerSettings.asId ?? ""
            self.uid = tokenAsIdUIdAndTimerSettings.uid ?? ""
            
            if !self.uid.isEmpty {
                SecureStorage.shared.save(key: Constants.UID_KEY, value: self.uid)
            }
        }
        
        if let passkeyRequestStr = intentResponse.passkeyRequestStr,
           !passkeyRequestStr.isEmpty,
           let passkeyRequestDict = Utils.convertStringToDictionary(passkeyRequestStr) {
            await self.startPasskeyAuthorization(passkeyRequestDict: passkeyRequestDict)
            return
        }
        
        if intentResponse.isSNA,
           let snaUrl = intentResponse.intent,
           let state = self.state,
           let timerSettings = intentResponse.tokenAsIdUIdAndTimerSettings?.timerSettings
        {
            let response = await self.snaUseCase.invoke(state: state, url: snaUrl, timerSettings: timerSettings)
            if let otplessResponse = response.otplessResponse {
                invokeResponse(otplessResponse)
                if otplessResponse.responseType == ResponseTypes.ONETAP {
                    // No need to proceed further, user has been authenticated
                    return
                }
            }
            
            if let tokenAsIdUIdAndTimerSettings = response.tokenAsIdUIdAndTimerSettings {
                // Update before making api call because they will be referenced in ApiManager 
                self.token = tokenAsIdUIdAndTimerSettings.token ?? ""
                self.asId = tokenAsIdUIdAndTimerSettings.asId ?? ""
                self.uid = tokenAsIdUIdAndTimerSettings.uid ?? ""
                
                if let timerSettings = tokenAsIdUIdAndTimerSettings.timerSettings {
                    await transactionStatusUseCase.invoke(queryParams: otplessRequest.getQueryParams(), state: self.state ?? "", timerSettings: timerSettings, onResponse: { [weak self] otplessResponse in
                        self?.invokeResponse(otplessResponse)
                    })
                }
            }
            return
        }
        
        if let sdkAuthParams = intentResponse.sdkAuthParams {
            await prepareForSdkAuth(withAuthParams: sdkAuthParams)
            return
        }
        
        if let intent = intentResponse.intent {
            let urlWithOutDecoding = intent.removingPercentEncoding
            if let link = URL(string: (urlWithOutDecoding!.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed))!) {
                var params: [String: String] = [:]
                var channel = ""
                if #available(iOS 16.0, *) {
                    channel = (link.scheme ?? "") + "://" + (link.host() ?? "")
                } else {
                    channel = (link.scheme ?? "") + "://" + (link.host ?? "")
                }
                params["channel"] = channel
                sendEvent(event: .DEEPLINK_SDK, extras: params)
                await UIApplication.shared.open(link, options: [:], completionHandler: nil)
            }
        }
        
        if let timerSettings = intentResponse.tokenAsIdUIdAndTimerSettings?.timerSettings,
           intentResponse.isPollingRequired == true {
            await transactionStatusUseCase.invoke(queryParams: otplessRequest.getQueryParams(), state: self.state ?? "", timerSettings: timerSettings, onResponse: { [weak self] otplessResponse in
                self?.invokeResponse(otplessResponse)
            })
        }
    }
    
    func canRequestBeMade(
        request: OtplessRequest,
        shouldRetryStateAndMerchantConfigFetch: (() async -> (String?, MerchantConfigResponse?))?
    ) async -> Bool {
        
        if let state = self.state, state.isEmpty {
            invokeResponse(
                OtplessResponse.createUnauthorizedResponse(
                    errorCode: "5003",
                    errorMessage: "Failed to fetch."
                )
            )
            return false
        }
        
        guard let merchantConfig = merchantConfig else {
            invokeResponse(
                OtplessResponse.createUnauthorizedResponse(
                    errorCode: "5003",
                    errorMessage: "Failed to initialize."
                )
            )
            return false
        }
        
        if merchantConfig.isMFAEnabled == true {
            invokeResponse(
                OtplessResponse.create2FAEnabledError()
            )
            return false
        }
        
        if !request.isPhoneNumberWithCountryCodeValid() &&
            request.getSelectedChannelType() == nil &&
            (request.getRequestId()?.isEmpty ?? true) &&
            !request.isEmailValid() {
            invokeResponse(
                OtplessResponse.createInvalidRequestError(request: request)
            )
            return false
        }
        
        switch request.getAuthenticationMedium() {
        case .PHONE:
            if !isChannelEnabled(channelType: phoneIntentChannel, isPhoneAuth: true) {
                invokeResponse(
                    OtplessResponse.createInactiveOAuthChannelError(channel: "phone")
                )
                return false
            }
            
        case .EMAIL:
            if !isChannelEnabled(channelType: emailIntentChannel, isPhoneAuth: false) {
                invokeResponse(
                    OtplessResponse.createInactiveOAuthChannelError(channel: "email")
                )
                return false
            }
            
        case .OAUTH:
            // Check if the selected channel is enabled
            if !isChannelEnabled(
                channelType: request.getSelectedChannelType()?.rawValue ?? "",
                isPhoneAuth: request.getSelectedChannelType() == .WHATSAPP ||
                request.getSelectedChannelType() == .TRUE_CALLER
            ) {
                invokeResponse(
                    OtplessResponse.createInactiveOAuthChannelError(
                        channel: request.getSelectedChannelType()?.rawValue ?? ""
                    )
                )
                return false
            }
            
        case .WEB_AUTHN:
            if merchantConfig.merchant?.config?.isWebauthnEnabled == false {
                invokeResponse(
                    OtplessResponse.createInactiveOAuthChannelError(channel: "WebAuthn")
                )
                return false
            }
            
        default:
            break
        }
        
        return true
    }
    
    func isChannelEnabled(channelType: String, isPhoneAuth: Bool?) -> Bool {
        guard let channelConfigs = merchantConfig?.channelConfig else {
            return false
        }
        
        for channelConfig in channelConfigs {
            if isPhoneAuth == true && channelConfig.identifierType != "MOBILE" {
                continue
            }
            if isPhoneAuth == false && channelConfig.identifierType == "MOBILE" {
                continue
            }
            
            // Check each channel in the channelConfig
            if let channels = channelConfig.channel {
                for channel in channels {
                    // Special cases FACEBOOK_SDK, APPLE_SDK & GOOGLE_SDK
                    if channelType == OtplessChannelType.FACEBOOK_SDK.rawValue, let channelName = channel.name, channelName.starts(with: "FACEBOOK") {
                        hasMerchantSelectedExternalSDK = true
                        return true
                    }
                    if channelType == OtplessChannelType.GOOGLE_SDK.rawValue, let channelName = channel.name, channelName.starts(with: "GMAIL") || channelName.starts(with: "GOOGLE") {
                        hasMerchantSelectedExternalSDK = true
                        return true
                    }
                    
                    if channelType == OtplessChannelType.APPLE_SDK.rawValue, let channelName = channel.name,
                       channelName.starts(with: "APPLE") {
                        hasMerchantSelectedExternalSDK = true
                        return true
                    }
                    
                    if let channelName = channel.name, channelName.contains(channelType) {
                        return true
                    }
                }
            }
        }
        
        return false
    }
    
    func getIntentChannelFromConfig(channelConfig: [ChannelConfig]?, isMobile: Bool) -> String {
        guard let channelConfig = channelConfig else {
            return ""
        }
        
        if isMobile {
            for cf in channelConfig {
                if cf.identifierType != "MOBILE" {
                    continue
                }
                if let channels = cf.channel {
                    for channel in channels {
                        if channel.type == "INPUT" {
                            return channel.name ?? ""
                        }
                    }
                }
            }
        } else {
            for cf in channelConfig {
                if cf.identifierType != "EMAIL" {
                    continue
                }
                if let channels = cf.channel {
                    for channel in channels {
                        if channel.type == "INPUT" {
                            return channel.name ?? ""
                        }
                    }
                }
            }
        }
        
        return ""
    }
    
    func getMerchantConfigQueryParams() -> [String: String] {
        var queryParams: [String: String] = [:]
        if !uid.isEmpty {
            queryParams["uid"] = uid
        }
        return queryParams
    }
    
    @MainActor
    func getInidFromMainActor() -> String {
        return DeviceInfoUtils.shared.getInstallationId() ?? ""
    }
    
    @MainActor
    func getTsidFromMainActor() -> String {
        return DeviceInfoUtils.shared.getTrackingSessionId() ?? ""
    }
    
    @MainActor
    func getAppInfoFromMainActor() -> [String: Any] {
        return DeviceInfoUtils.shared.getAppInfo()
    }
    
}

extension Otpless {
    func resetStates() {
        isOneTapUIDismissed = false // reset it's state so that onetap ui is shown for a new request.
        requestCount = 0 // reset the requestCount to 0
        stateFetchRetriesCount = 0
        token = ""
        asId = ""
        hasMerchantSelectedExternalSDK = false
        userSelectedOAuthChannel = nil
    }
}

extension Otpless {
    private func initialiseEventCounter() {
        let existingEventCounterString = SecureStorage.shared.retrieve(key: Constants.EVENT_COUNTER_KEY) ?? "-1"
        let existingEventCounterInt = Int(existingEventCounterString) ?? -1
        
        if existingEventCounterInt != -1 {
            self.eventCounter = existingEventCounterInt // Existing EVENT_COUNTER was for the previous session, so increment it by 1 to avoid duplicity.
            return
        }
        // EVENT_COUNTER does not exist, so initialize it with 1
        self.eventCounter = 1
    }
    
    func getEventCounterAndIncrement() -> Int {
        eventCounterLock.lock()
        defer { eventCounterLock.unlock() }
        let currentValue = eventCounter
        eventCounter += 1
        SecureStorage.shared.save(key: Constants.EVENT_COUNTER_KEY, value: String(eventCounter))
        return currentValue
    }
}

@MainActor
public protocol OtplessResponseDelegate: NSObjectProtocol {
    func onResponse(_ response: OtplessResponse)
}

@MainActor
public protocol OneTapDataDelegate: NSObjectProtocol {
    func onOneTapData(_ identities: [OneTapIdentity]?)
}
