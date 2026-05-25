//
//  File.swift
//  otpless-iOS-headless-sdk
//
//  Created by Sparsh on 16/01/25.
//

import Foundation
import UIKit
import Network


@objc final public class Otpless: NSObject, @unchecked Sendable {
    @objc public static let shared: Otpless = {
        return Otpless()
    }()
    
    internal private(set) var environment: OtplessEnvironment = .PRODUCTION
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
    internal var drfID: String = ""

    // Device Intelligence
    internal var rsId: String = ""
    internal var diState: DeviceIntelligenceState = .idle
    internal var deviceFingerprintMode: DeviceFingerprintMode = .NONE

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
    internal private(set) weak var merchantWindowScene: UIWindowScene?
    internal private(set) var pendingCode = ""
    internal private(set) var sdkState : SdkState = SdkState.NOT_READY
    
    
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
    
    private var eventCounter = 1
    
    let cellularMonitor = NWPathMonitor(requiredInterfaceType: .cellular)
    internal private(set) var isMobileDataEnabled: Bool = true
    
    internal private(set) var otpLength: Int = -1
    
    internal private(set) var objcResponseDelegate: ((String) -> Void)?
    
    //initialize method
    @objc public func initialise(
        withAppId appId: String,
        loginUri: String? = nil,
        vc: UIViewController
    ) {
        self.merchantOtplessRequest = nil
        self.sdkState = .NOT_READY
        self.merchantAppId = appId
        self.merchantVC = vc
        self.uid = SecureStorage.shared.retrieve(key: Constants.UID_KEY) ?? ""
        self.merchantLoginUri = loginUri ?? "otpless.\(appId.lowercased())://otpless"
        startMobileDataMonitoring()

        log(message: "[Init] SDK initialising — appId: \(appId), loginUri: \(self.merchantLoginUri)", type: .SDK_INIT)

        Task(priority: .medium) { [weak self] in
            guard let self = self else { return }

            await DeviceInfoUtils.shared.initialise()

            let uid = SecureStorage.shared.retrieve(key: Constants.UID_KEY) ?? ""
            let inid = await self.getInidFromMainActor()
            let tsid = await self.getTsidFromMainActor()

            self.uid = uid
            self.inid = inid
            self.tsid = tsid

            log(message: "[Init] Device IDs resolved — inId: \(inid), tsId: \(tsid), uid: \(uid.isEmpty ? "<none>" : uid)", type: .SDK_INIT)

            await MainActor.run {
                self.deviceInfo = DeviceInfoUtils.shared.getDeviceInfoDict()
            }

            await MainActor.run { [weak self] in
                self?.appInfo = self?.getAppInfoFromMainActor() ?? [:]
            }

            self.fetchStateAndMerchantConfig(onlyState: false)
        }
    }
    private func intelligenceInitialized(withAppId appId: String){
        self.merchantAppId = appId
        Task(priority: .medium) { [weak self] in
            guard let self = self else { return }
            
            await DeviceInfoUtils.shared.initialise()
            let inid = await self.getInidFromMainActor()
            let tsid = await self.getTsidFromMainActor()
            self.inid = inid
            self.tsid = tsid
            
            await MainActor.run {
                self.deviceInfo = DeviceInfoUtils.shared.getDeviceInfoDict()
            }
            
            await MainActor.run { [weak self] in
                self?.appInfo = self?.getAppInfoFromMainActor() ?? [:]
            }
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
        self.pendingCode = ""
        self.merchantOtplessRequest = otplessRequest
        self.userSelectedOAuthChannel = otplessRequest.getSelectedChannelType()

        if otplessRequest.getOtpLength() != -1 {
            self.otpLength = otplessRequest.getOtpLength()
        } else {
            self.otpLength = getOtpLength(
                fromChannelConfig: merchantConfig?.channelConfig,
                forAuthenticationMedium: otplessRequest.getAuthenticationMedium()
            )
        }

        log(message: "[Transaction] start() called — medium: \(otplessRequest.getAuthenticationMedium()?.rawValue ?? "unknown"), isIntentRequest: \(otplessRequest.isIntentRequest())", type: .TRANSACTION_START)

        sendEvent(event: .START_HEADLESS, extras: otplessRequest.getEventDict())
        await processRequestIfRequestIsValid(otplessRequest)
    }
    
    @objc public func authorizeViaPasskey(withRequest otplessRequest: OtplessRequest, windowScene: UIWindowScene) async {
        self.merchantOtplessRequest = otplessRequest
        self.merchantWindowScene = windowScene
        await processRequestIfRequestIsValid(otplessRequest)
    }
    
    @objc public func handleDeeplink(_ url: URL) async {
        log(message: "[Deeplink] Received — url: \(url.absoluteString)", type: .DEEPLINK)

        guard url.host == "otpless" else {
            log(message: "[Deeplink] Invalid host — expected 'otpless', got '\(url.host ?? "nil")'", type: .INVALID_DEEPLINK)
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
            log(message: "[Deeplink] No code found in URL — ignoring", type: .DEEPLINK)
            return
        }

        log(message: "[Deeplink] Code extracted — sdkState: \(self.sdkState)", type: .DEEPLINK)

        if self.sdkState == .READY {
            await self.verifyCodeAndInvokeIfReady(code: code)
        } else {
            log(message: "[Deeplink] SDK not ready — code queued as pendingCode", type: .DEEPLINK)
            self.pendingCode = code
        }
    }
    
    private func verifyCodeAndInvokeIfReady(code : String) async{
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
        self.pendingCode = ""
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
        Utils.convertToEventParamsJson(
            otplessResponse: otplessResponse,
            callback: { extras, musId in
                sendEvent(event: .HEADLESS_MERCHANT_COMMIT, extras: extras, musId: musId ?? "")
            }
        )
    }
    
    @objc public func cleanup() {
        self.merchantVC = nil
        cellularMonitor.cancel()
        self.responseDelegate = nil
    }
    
    @objc public func isSdkReady() -> Bool {
           return sdkState == .READY
       }
    
    @objc public func objcCommit(_ otplessResponse: String?) {
        let responseDict = Utils.convertStringToDictionary(otplessResponse ?? "") ?? [:]
        let responseType = ResponseTypes(rawValue: responseDict["responseType"] as? String ?? "") ?? .FAILED
        let response = responseDict["response"] as? [String: Any]
        let statusCode = responseDict["statusCode"] as? Int ?? -10699
        let otplResponse = OtplessResponse(responseType: responseType, response: response, statusCode: statusCode)
        commitOtplessResponse(otplResponse)
    }
    
    @objc public func gettsID()->String {
        return tsid
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

    public func setEnvironment(_ environment: OtplessEnvironment) {
        self.environment = environment
    }
    
    @objc public func setOtplessObjcResponseDelegate(_ otplessResponseDelegate: @escaping (String) -> Void) {
        self.objcResponseDelegate = otplessResponseDelegate
        sendEvent(event: .SET_HEADLESS_CALLBACK)
    }
    
    public func setLoggerDelegate(_ otplessLoggerDelegate: OtplessLoggerDelegate) {
        self.loggerDelegate = otplessLoggerDelegate
    }

    @objc public func setDeviceFingerprintMode(_ mode: DeviceFingerprintMode) {
        self.deviceFingerprintMode = mode
    }
    
    func setPackageName(_ pName: String) {
        self.packageName = pName
    }
    
    public func clearAll() {
        SecureStorage.shared.clearAll()
    }
    
}

private extension Otpless {
    func fetchStateAndMerchantConfig(onlyState:Bool) {
        log(message: "[Init] Fetching device state — onlyState: \(onlyState)", type: .SDK_STATE_FETCH)
        requestStateForDeviceIfNil(onFetch: { [weak self] state in
            guard let state = state else {
                log(message: "[Init] State fetch returned nil — aborting", type: .SDK_STATE_FETCH)
                return
            }

            log(message: "[Init] State resolved — state: \(state.prefix(8))…", type: .SDK_STATE_FETCH)
            self?.state = state
            SecureStorage.shared.save(key: Constants.STATE_KEY, value: state)
            if onlyState { return }
            self?.fetchMerchantConfig()
        })
    }
    
    func requestStateForDeviceIfNil(onFetch: @escaping @Sendable (String?) -> Void) {
        if let savedState = SecureStorage.shared.retrieve(key: Constants.STATE_KEY),
           !savedState.isEmpty {
            onFetch(savedState)
        } else {
            Task(priority: .medium) { [weak self] in
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
        guard let state = self.state else { return }

        log(message: "[Init] Fetching merchant config — state: \(state.prefix(8))…", type: .MERCHANT_CONFIG)

        Task(priority: .medium) { [weak self] in
            guard let self = self else { return }

            let (merchantConfig, otplessResponse) = await self.getMerchantConfigUseCase.invoke(
                state: state,
                queryParams: [:],
                isRetry: false
            )

            await MainActor.run { [weak self] in
                guard let self = self else { return }

                self.merchantConfig = merchantConfig
                self.phoneIntentChannel = self.getIntentChannelFromConfig(
                    channelConfig: merchantConfig?.channelConfig,
                    isMobile: true
                ) ?? ""
                self.emailIntentChannel = self.getIntentChannelFromConfig(
                    channelConfig: merchantConfig?.channelConfig,
                    isMobile: false
                ) ?? ""

                if let config = merchantConfig {
                    let diType = config.metaData?.deviceIntelligence?.type ?? "<not set>"
                    log(message: "[Init] Merchant config received — phoneChannel: \(self.phoneIntentChannel), emailChannel: \(self.emailIntentChannel), isMFAEnabled: \(config.isMFAEnabled ?? false), deviceIntelligence.type: \(diType)", type: .MERCHANT_CONFIG)
                }

                sendEvent(event: .INIT_HEADLESS)

                if let otplessResponse = otplessResponse {
                    log(message: "[Init] Merchant config fetch failed — relaying error response", type: .MERCHANT_CONFIG)
                    self.invokeResponse(otplessResponse)
                } else {
                    log(message: "[Init] SDK ready", type: .SDK_READY)
                    self.sdkState = .READY
                    self.invokeResponse(OtplessResponse.sdkReady)
                }
            }

            if Task.isCancelled { return }

            let code = self.pendingCode
            if !code.isEmpty {
                log(message: "[Deeplink] Processing pending code now that SDK is ready", type: .DEEPLINK)
                await self.verifyCodeAndInvokeIfReady(code: code)
            }
        }
    }


    
    func processRequestIfRequestIsValid(_ otplessRequest: OtplessRequest) async {
        if await !canRequestBeMade(request: otplessRequest) {
            return
        }

        if !otplessRequest.isIntentRequest() {
            log(message: "[Verify] OTP/code verify request — state: \(self.state?.prefix(8) ?? "nil")…", type: .VERIFY)
            let verifyOtpResponse = await verifyOtpUseCase.invoke(
                state: self.state ?? "",
                queryParams: otplessRequest.getQueryParams(),
                getTransactionStatusUseCase: self.transactionStatusUseCase
            )
            invokeResponse(verifyOtpResponse)
            return
        }

        // Read DI mode from request extras so callers don't need a separate setter.
        let requestedDIMode = otplessRequest.getDeviceFingerprintMode()
        if requestedDIMode != .NONE {
            deviceFingerprintMode = requestedDIMode
        }

        log(message: "[Transaction] New intent request — deviceFingerprintMode: \(deviceFingerprintMode == .SYNC ? "SYNC" : deviceFingerprintMode == .ASYNC ? "ASYNC" : "NONE"), triggering DI if needed, then calling intent API", type: .TRANSACTION_START)

        // Configure device intelligence in parallel with the intent API.
        triggerDeviceIntelligenceIfNeeded(state: self.state ?? "")

        let intentResponse = await postIntentUseCase.invoke(
            state: self.state ?? "",
            withOtplessRequest: otplessRequest,
            uiId: self.uiId,
            uid: self.uid
        )
        
        if let otplessResponse = intentResponse.otplessResponse {
            invokeResponse(otplessResponse)
            // check for error code, if error code is terminal error code
            // then give create terminal response and exit
            if let errorCode = otplessResponse.response?["errorCode"] as? String, OtplessConstant.terminalErrorCodes.contains(errorCode) {
                let terminalResponse = OtplessResponse(responseType: ResponseTypes.AUTH_TERMINATED, response: otplessResponse.response, statusCode: otplessResponse.statusCode)
                invokeResponse(terminalResponse)
                sendEvent(event: .SNA_INIT_TERMINAL_RESPONSE)
                DLog("SNA auth init terminated")
                return
            }
        }
        
        if let tokenAsIdUIdAndTimerSettings = intentResponse.tokenAsIdUIdAndTimerSettings {
            self.token = tokenAsIdUIdAndTimerSettings.token ?? ""
            self.asId = tokenAsIdUIdAndTimerSettings.asId ?? ""
            updateAuthMap(token: token)
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
           let timerSettings = intentResponse.tokenAsIdUIdAndTimerSettings?.timerSettings
        {
            let response = await self.snaUseCase.invoke(url: snaUrl, timerSettings: timerSettings)
            if let otplessResponse = response.otplessResponse {
                for op in otplessResponse {
                    invokeResponse(op)
                    if op.responseType == ResponseTypes.ONETAP {
                        // No need to proceed further, user has been authenticated
                        return
                    }
                    // check for terminal error code
                    if let errorCode = op.response?["errorCode"] as? String, OtplessConstant.terminalErrorCodes.contains(errorCode) {
                        // terminal response is sent, exit the flow
                        sendEvent(event: .SNA_AUTH_TERMINAL_RESPONSE)
                        DLog("SNA auth terminated")
                        return
                    }
                }
            }
            
            if let tokenAsIdUIdAndTimerSettings = response.tokenAsIdUIdAndTimerSettings {
                // Update before making api call because they will be referenced in ApiManager 
                self.token = tokenAsIdUIdAndTimerSettings.token ?? ""
                self.asId = tokenAsIdUIdAndTimerSettings.asId ?? ""
                self.uid = tokenAsIdUIdAndTimerSettings.uid ?? ""
                updateAuthMap(token: token)
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
        request: OtplessRequest
    ) async -> Bool {

        if let state = self.state, state.isEmpty {
            log(message: "[Validation] Request blocked — state is empty (SDK not initialised)", type: .TRANSACTION_VALIDATION)
            invokeResponse(OtplessResponse.failedToInitializeResponse)
            return false
        }

        guard let merchantConfig = merchantConfig else {
            log(message: "[Validation] Request blocked — merchantConfig is nil (SDK not initialised)", type: .TRANSACTION_VALIDATION)
            invokeResponse(OtplessResponse.failedToInitializeResponse)
            return false
        }

        if merchantConfig.isMFAEnabled == true {
            log(message: "[Validation] Request blocked — MFA is enabled for this merchant", type: .TRANSACTION_VALIDATION)
            invokeResponse(OtplessResponse.create2FAEnabledError())
            return false
        }

        if !request.isPhoneNumberWithCountryCodeValid() &&
            request.getSelectedChannelType() == nil &&
            (request.getRequestId()?.isEmpty ?? true) &&
            !request.isEmailValid() {
            log(message: "[Validation] Request blocked — invalid request params (no phone, email, channel, or requestId)", type: .TRANSACTION_VALIDATION)
            invokeResponse(OtplessResponse.createInvalidRequestError(request: request))
            return false
        }
        
        log(message: "[Validation] Request passed all checks — proceeding", type: .TRANSACTION_VALIDATION)
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
    
    private func startMobileDataMonitoring() {
        cellularMonitor.pathUpdateHandler = { path in
            DispatchQueue.main.async { [weak self] in
                self?.isMobileDataEnabled = path.status == .satisfied
            }
        }
        cellularMonitor.start(queue: DispatchQueue.global())
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
        merchantOtplessRequest = nil
        // rsId, diState, and deviceFingerprintMode are reset in the ONETAP handler inside invokeResponse
    }
}

extension Otpless {
    func getEventCounterAndIncrement() -> Int {
        let currentCounter = eventCounter
        eventCounter += 1
        return currentCounter
    }
}

internal enum DeviceIntelligenceState {
    case idle, inProgress, completed
}

extension Otpless {
    func triggerDeviceIntelligenceIfNeeded(state: String) {
        guard deviceFingerprintMode != .NONE else {
            log(message: "[DI] Skipped — deviceFingerprintMode is NONE", type: .DEVICE_INTELLIGENCE)
            return
        }

        guard diState == .idle else {
            log(message: "[DI] Skipped — already in state: \(diState) (will not re-trigger until after ONETAP)", type: .DEVICE_INTELLIGENCE)
            return
        }

        rsId = "\(UUID().uuidString)-\(DispatchTime.now().uptimeNanoseconds)-\(state)"
        diState = .inProgress
        log(message: "[DI] Configuring — mode: \(deviceFingerprintMode == .SYNC ? "SYNC" : "ASYNC"), rsId: \(rsId)", type: .DEVICE_INTELLIGENCE)

        guard #available(iOS 15.0, *),
              let cls = NSClassFromString("OTPlessIntelligence.OTPlessIntelligence") as? NSObject.Type else {
            log(message: "[DI] SDK class not found or iOS < 15 — marking configured and continuing", type: .DEVICE_INTELLIGENCE)
            onDeviceIntelligenceConfigured()
            return
        }

        let sharedSelector = NSSelectorFromString("shared")
        guard cls.responds(to: sharedSelector),
              let sharedObj = cls.perform(sharedSelector)?.takeUnretainedValue() as? NSObject else {
            log(message: "[DI] Could not get shared instance of OTPlessIntelligence — marking configured", type: .DEVICE_INTELLIGENCE)
            onDeviceIntelligenceConfigured()
            return
        }

        let selector = NSSelectorFromString("configureIntelligenceWithParams:onComplete:")
        guard sharedObj.responds(to: selector) else {
            log(message: "[DI] Method 'configureIntelligenceWithParams:onComplete:' not found — marking configured", type: .DEVICE_INTELLIGENCE)
            onDeviceIntelligenceConfigured()
            return
        }

        log(message: "[DI] Calling configure — rsId: \(rsId), inId: \(inid), tsId: \(tsid), state: \(state.prefix(8))…", type: .DEVICE_INTELLIGENCE)

        let params: [String: String] = [
            "rsId": rsId,
            "inId": inid,
            "tsId": tsid,
            "state": state,
            "appId": merchantAppId
        ]

        typealias VoidBlock = @convention(block) () -> Void
        let completion: VoidBlock = { [weak self] in
            self?.onDeviceIntelligenceConfigured()
        }
        let blockObj = unsafeBitCast(completion, to: AnyObject.self)
        sharedObj.perform(selector, with: params, with: blockObj)
    }

    private func onDeviceIntelligenceConfigured() {
        log(message: "[DI] Configure complete — diState transitioning to completed", type: .DEVICE_INTELLIGENCE)
        diState = .completed
    }

    func fetchIntelligenceAsync() async -> [String: Any]? {
        guard #available(iOS 15.0, *),
              let cls = NSClassFromString("OTPlessIntelligence.OTPlessIntelligence") as? NSObject.Type else {
            log(message: "[DI] Fetch skipped — SDK class not found or iOS < 15", type: .DEVICE_INTELLIGENCE)
            return nil
        }

        let sharedSelector = NSSelectorFromString("shared")
        guard cls.responds(to: sharedSelector),
              let sharedObj = cls.perform(sharedSelector)?.takeUnretainedValue() as? NSObject else {
            log(message: "[DI] Fetch skipped — could not get shared instance", type: .DEVICE_INTELLIGENCE)
            return nil
        }

        let selector = NSSelectorFromString("fetchIntelligenceWithCompletion:")
        guard sharedObj.responds(to: selector) else {
            log(message: "[DI] Fetch skipped — method 'fetchIntelligenceWithCompletion:' not found", type: .DEVICE_INTELLIGENCE)
            return nil
        }

        log(message: "[DI] Fetching intelligence…", type: .DEVICE_INTELLIGENCE)

        return await withCheckedContinuation { continuation in
            typealias FetchBlock = @convention(block) ([String: Any]?, AnyObject?) -> Void
            let block: FetchBlock = { data, error in
                if let error = error {
                    log(message: "[DI] Fetch failed: \(error)", type: .DEVICE_INTELLIGENCE)
                }
                continuation.resume(returning: data)
            }
            let blockObj = unsafeBitCast(block, to: AnyObject.self)
            sharedObj.perform(selector, with: blockObj)
        }
    }
}

@MainActor
public protocol OtplessResponseDelegate: NSObjectProtocol {
    func onResponse(_ response: OtplessResponse)
}


