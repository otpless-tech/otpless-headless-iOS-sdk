//
//  File.swift
//  otpless-iOS-headless-sdk
//
//  Created by Sparsh on 16/01/25.
//

import Foundation
import UIKit
import Network


@objc final public class Otpless: NSObject, @unchecked Sendable, UsecaseProvider {
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
    internal var drfID: String = ""
    
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
        return PostIntentUseCase(others: self)
    }()
    internal private(set) lazy var transactionStatusUseCase: TransactionStatusUseCase = {
        return TransactionStatusUseCase()
    }()
    internal private(set) lazy var passkeyUseCase: PasskeyUseCase = {
        return PasskeyUseCase(others: self)
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
    
    private weak var onetapController: UIViewController?
    
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
        
        Task(priority: .medium) { [weak self] in
            guard let self = self else { return }
            
            await DeviceInfoUtils.shared.initialise()
            
            self.uid = SecureStorage.shared.retrieve(key: Constants.UID_KEY) ?? ""
            self.inid = DeviceInfoUtils.shared.getInstallationId()
            self.tsid = DeviceInfoUtils.shared.getTrackingSessionId()
            
            
            await MainActor.run {
                self.deviceInfo = DeviceInfoUtils.shared.getDeviceInfoDict()
            }
            self.appInfo = await DeviceInfoUtils.shared.getAppInfo()
            self.fetchStateAndMerchantConfig(onlyState: false)
        }
    }
    
    private func intelligenceInitialized(withAppId appId: String){
        self.merchantAppId = appId
        Task(priority: .medium) { [weak self] in
            guard let self = self else { return }
            
            await DeviceInfoUtils.shared.initialise()
            self.inid = await DeviceInfoUtils.shared.getInstallationId()
            self.tsid = await DeviceInfoUtils.shared.getTrackingSessionId()
            
            await MainActor.run {
                self.deviceInfo = DeviceInfoUtils.shared.getDeviceInfoDict()
            }
            self.appInfo = await DeviceInfoUtils.shared.getAppInfo()
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
            // If not found, then reset again to prevent sending otpLength that may have been set in an earlier request
            self.otpLength = getOtpLength(
                fromChannelConfig: merchantConfig?.channelConfig,
                forAuthenticationMedium: otplessRequest.getAuthenticationMedium()
            )
        }
        sendEvent(event: .START_HEADLESS, extras: otplessRequest.getEventDict())
        await processRequestIfRequestIsValid(otplessRequest)
    }
    
    public func startAuth(parent vc: UIViewController, config authConfig: OtplessAuthCofig) async -> Bool {
        guard #available(iOS 15.0, *) else {
            return false
        }
        var onetapItemData: [OnetapItemData] = []
        if let mobiles = self.merchantConfig?.userDetails?.mobile, !mobiles.isEmpty {
            for each in mobiles {
                onetapItemData.append(OnetapItemData.from(mobile: each))
            }
        }
        if let emails = self.merchantConfig?.userDetails?.email, !emails.isEmpty {
            for each in emails {
                onetapItemData.append(OnetapItemData.from(email: each))
            }
        }
        if onetapItemData.isEmpty {
            return false
        }
        if authConfig.isForeground {
            await MainActor.run {
                presentOneTapBottomSheet(viewController: vc, items: onetapItemData, config: authConfig)
            }
            return true
        } else if onetapItemData.count == 1 {
            let request = OtplessRequest()
            request.onetapItemData = onetapItemData[0]
            await startOnetapAuth(config: authConfig, request: request)
            return true
        } else {
            return false
        }
    }
    
    private func startOnetapAuth(config authConfig: OtplessAuthCofig, request otplessRequest: OtplessRequest) async {
        let intentResponse = await postIntentUseCase.invoke(
            state: self.state ?? "",
            withOtplessRequest: otplessRequest,
            uiId: [otplessRequest.onetapItemData!.uiid],
            uid: self.uid
        )
        await handleIntentResponse(intentResponse, otplessRequest)
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
        
        if (self.sdkState == .READY){
            await self.verifyCodeAndInvokeIfReady(code: code)
        } else {
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
    
    @objc public func setOtplessObjcResponseDelegate(_ otplessResponseDelegate: @escaping (String) -> Void) {
        self.objcResponseDelegate = otplessResponseDelegate
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
    func fetchStateAndMerchantConfig(onlyState:Bool) {
        requestStateForDeviceIfNil(onFetch: { [weak self] state in
            guard let state = state else {
                return
            }
            
            self?.state = state
            SecureStorage.shared.save(key: Constants.STATE_KEY, value: state)
            if (onlyState){
                return
            }
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

                // Send event before invoking any response
                sendEvent(event: .INIT_HEADLESS)

                if let otplessResponse = otplessResponse {
                    // Error occurred during fetch
                    self.invokeResponse(otplessResponse)
                } else {
                    // SDK ready after successful fetch
                    self.sdkState = .READY
                    self.invokeResponse(OtplessResponse.sdkReady)
                }
            }

            if Task.isCancelled { return }

            let code = self.pendingCode
            if !code.isEmpty {
                await self.verifyCodeAndInvokeIfReady(code: code)
            }
        }
    }
    
    func processRequestIfRequestIsValid(_ otplessRequest: OtplessRequest) async {
        if await !canRequestBeMade(request: otplessRequest) {
            return
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
        await handleIntentResponse(intentResponse, otplessRequest)
    }


    
    private func handleIntentResponse(_ intentResponse: PostIntentUseCaseResponse, _ otplessRequest: OtplessRequest) async {
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
            let result = await passkeyUseCase.autherizePasskey(request: passkeyRequestDict)
            switch result {
                case .success(let response):
                self.invokeResponse(response)
            case .failure(let error):
                let intentResponse: PostIntentUseCaseResponse
                if otplessRequest.onetapItemData != nil {
                    let uuid: String = otplessRequest.onetapItemData!.uiid
                    intentResponse = await postIntentUseCase.invoke(
                        state: self.state ?? "",
                        withOtplessRequest: otplessRequest,
                        uiId: [uuid],
                        uid: self.uid,
                        webAuthnFallback: true
                    )
                } else {
                    intentResponse = await postIntentUseCase.invoke(
                        state: self.state ?? "",
                        withOtplessRequest: otplessRequest,
                        uiId: self.uiId,
                        uid: self.uid,
                        webAuthnFallback: true
                    )
                }
                await handleIntentResponse(intentResponse, otplessRequest)
            }
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
            invokeResponse(
                OtplessResponse.failedToInitializeResponse
            )
            return false
        }
        
        guard let merchantConfig = merchantConfig else {
            invokeResponse(
                OtplessResponse.failedToInitializeResponse
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
    }
}

extension Otpless {
    func getEventCounterAndIncrement() -> Int {
        let currentCounter = eventCounter
        eventCounter += 1
        return currentCounter
    }
}

@MainActor
public protocol OtplessResponseDelegate: NSObjectProtocol {
    func onResponse(_ response: OtplessResponse)
}

extension Otpless {
    
    @available(iOS 15.0, *)
    internal func presentOneTapBottomSheet(viewController: UIViewController, items: [OnetapItemData], config config: OtplessAuthCofig) {
        let oneTapView = OneTapView(
            items: items,
            onItemSelected: { [weak self] selectedIdentity in
                DLog("Otpless auth in progress \(selectedIdentity.identity) \(selectedIdentity.name)")
                // start the process
                let request = OtplessRequest()
                request.onetapItemData = selectedIdentity
                Task {
                    await self?.startOnetapAuth(config: config, request: request)
                }
                
            },
            onDismiss: { [weak self] in
                self?.dismissOneTapBottomSheet()
            }
        )
        let sheetVC = OneTapBottomSheetViewController(oneTapView: oneTapView) // from earlier
        onetapController = sheetVC
        viewController.present(sheetVC, animated: true)
    }
    
    internal func dismissOneTapBottomSheet() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let controller = self.onetapController else { return }
            controller.dismiss(animated: true)
            self.onetapController = nil
        }
    }
}


