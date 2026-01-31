//
//  PostIntentUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//

import Foundation

internal class PostIntentUseCase {
    
    private let usecaseProvider: UsecaseProvider
    
    init(others usecaseProvider: UsecaseProvider) {
        self.usecaseProvider = usecaseProvider
    }
    
    func invoke(
        state: String,
        withOtplessRequest otplessRequest: OtplessRequest,
        uiId: [String]?,
        uid: String?,
        webAuthnFallback: Bool = false
    ) async -> PostIntentUseCaseResponse {
        Otpless.shared.transactionStatusUseCase.stopPolling(dueToSuccessfulVerification: false)
        Otpless.shared.snaUseCase.stopPolling()
        
        flushExistingAuthTypeAndDeliveryChannel()
        var requestBody = getPostIntentRequestBody(otplessRequest, uiId: uiId, uid: uid)
        if webAuthnFallback {
            requestBody.setWebAuthnFallback(is: true)
        }
        let response = await Otpless.shared.apiRepository
            .postIntent(state: state, body: requestBody)
        
        switch response {
        case .success(let success):
            return parseSuccessResponse(success, postIntentRequestBody: requestBody)
        case .failure(let failure):
            return parseFailureResponse(failure, request: otplessRequest)
        }
    }
    
    private func flushExistingAuthTypeAndDeliveryChannel() {
        Otpless.shared.onCommunicationModeChange("NA")
        Otpless.shared.onAuthTypeChange(newAuthType: "")
    }
    
    func getPostIntentRequestBody(_ otplessRequest: OtplessRequest, uiId: [String]?, uid: String?) -> PostIntentRequestBody {
        let requestDict = otplessRequest.getDictForIntent()
        return PostIntentRequestBody(
            channel: alterChannelIfRequired(channel: ((requestDict[RequestKeys.channelKey] ?? "") ?? "")),
            email: requestDict[RequestKeys.emailKey] as? String,
            hasWhatsapp: (Otpless.shared.appInfo["hasWhatsapp"] as? String) ?? "",
            identifierType: (requestDict[RequestKeys.identifierTypeKey] ?? "") ?? "",
            mobile: requestDict[RequestKeys.mobileKey] as? String,
            selectedCountryCode: requestDict[RequestKeys.countryCodeKey] as? String,
            silentAuthEnabled: (Otpless.shared.merchantConfig?.merchant?.config?.isSilentAuthEnabled
                                ?? false) && ((otplessRequest.onetapItemData?.isMobile == true) || (otplessRequest.getPhone() != nil && !otplessRequest.isCustomRequest())) && Otpless.shared.isMobileDataEnabled,
            triggerWebauthn: shouldTriggerWebAuthn(otplessRequest),
            type: (requestDict[RequestKeys.typeKey] ?? "") ?? "",
            uid: uid,
            value: requestDict[RequestKeys.valueKey] as? String,
            expiry: requestDict[RequestKeys.expiryKey] as? String,
            deliveryMethod: requestDict[RequestKeys.deliveryChannelKey] as? String,
            otpLength: requestDict[RequestKeys.otpLengthKey] as? String,
            uiIds: uiId,
            fireIntent: (requestDict[RequestKeys.valueKey] as? String ?? "").isEmpty,
            requestId: requestDict[RequestKeys.requestIdKey] as? String,
            clientMetaData: getJSONClientMetaDataAsString(request: otplessRequest),
            asId: Otpless.shared.asId
        )
    }
    
    private func alterChannelIfRequired(channel: String) -> String {
        if channel == OtplessChannelType.GOOGLE_SDK.rawValue {
            return OtplessChannelType.GMAIL.rawValue
        }
        
        if channel == OtplessChannelType.FACEBOOK_SDK.rawValue {
            return OtplessChannelType.FACEBOOK.rawValue
        }
        
        if channel == OtplessChannelType.APPLE_SDK.rawValue {
            return OtplessChannelType.APPLE.rawValue
        }
        
        return channel
    }
    
    private func getJSONClientMetaDataAsString(request: OtplessRequest) -> String? {
        do {
            var clientMetaJson: [String: Any] = [:]
            
            if let templateId = request.tid, !templateId.isEmpty {
                clientMetaJson["tid"] = templateId
            }
            if let extras = request.extras {
                for (key, value) in extras {
                    clientMetaJson[key] = value
                }
            }
            
            let jsonData = try JSONSerialization.data(withJSONObject: clientMetaJson, options: [])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            return nil
        }
    }
    
    func parseSuccessResponse(_ response: IntentResponse, postIntentRequestBody: PostIntentRequestBody) -> PostIntentUseCaseResponse {
        var initiateResponse: OtplessResponse? = nil
        let isPollingRequired = response.quantumLeap.pollingRequired
        
        let tokenAsIdUIdAndTimerSettings = TokenAsIdUIdAndTimerSettings(
            token: response.quantumLeap.channelAuthToken,
            asId: response.quantumLeap.asId,
            uid: response.quantumLeap.uid ?? "",
            timerSettings: response.quantumLeap.timerSettings
        )
        
        if !isPollingRequired {
            if let oneTapData = response.oneTap {
                return PostIntentUseCaseResponse(
                    intent: nil,
                    otplessResponse: OtplessResponse(
                        responseType: .ONETAP,
                        response: oneTapData.toDict(),
                        statusCode: 200
                    ),
                    tokenAsIdUIdAndTimerSettings: tokenAsIdUIdAndTimerSettings,
                    passkeyRequestStr: nil,
                    uid: response.quantumLeap.uid,
                    sdkAuthParams: nil,
                    isPollingRequired: false,
                    isSNA: false
                )
            }
            
            initiateResponse = parseInitiateResponse(data: response)
            
            if response.quantumLeap.channel == "DEVICE" {
                return PostIntentUseCaseResponse(
                    intent: nil,
                    otplessResponse: initiateResponse,
                    tokenAsIdUIdAndTimerSettings: tokenAsIdUIdAndTimerSettings,
                    passkeyRequestStr: response.quantumLeap.intent, // Send intent as passkeyRequestStr
                    uid: nil,
                    sdkAuthParams: nil,
                    isPollingRequired: false,
                    isSNA: false
                )
            }
            
            if Otpless.shared.hasMerchantSelectedExternalSDK {
                let sdkAuthParams = getSdkAuthParamsFromIntentAndChannel(intent: response.quantumLeap.intent ?? "", channel: postIntentRequestBody.channel)
                
                return PostIntentUseCaseResponse(
                    intent: nil,
                    otplessResponse: initiateResponse,
                    tokenAsIdUIdAndTimerSettings: tokenAsIdUIdAndTimerSettings,
                    passkeyRequestStr: nil,
                    uid: response.quantumLeap.uid,
                    sdkAuthParams: sdkAuthParams,
                    isPollingRequired: false,
                    isSNA: false
                )
            }
            
            Otpless.shared.onAuthTypeChange(newAuthType: response.quantumLeap.channel)
            
            return PostIntentUseCaseResponse(
                intent: response.quantumLeap.intent,
                otplessResponse: parseInitiateResponse(data: response),
                tokenAsIdUIdAndTimerSettings: tokenAsIdUIdAndTimerSettings,
                passkeyRequestStr: nil,
                uid: nil,
                sdkAuthParams: nil,
                isPollingRequired: false,
                isSNA: false
            )
        } else {
            // Do not set the communication mode as SILENT_AUTH because we don't send a FALLBACK_TRIGGERED response when SNA fails.
            if (response.quantumLeap.channel != "SILENT_AUTH") {
                initiateResponse = parseInitiateResponse(data: response)
            } else {
                Otpless.shared.onCommunicationModeChange("SILENT_AUTH") // Hardcode SILENT_AUTH so that if the new communicationMode doesn't match "SILENT_AUTH", we can send INITIATE response to the user.
            }
            Otpless.shared.onAuthTypeChange(newAuthType: response.quantumLeap.channel)
        }

        // Check if user wants to use Google/Facebook/Apple's SDK for authentication
        if (Otpless.shared.hasMerchantSelectedExternalSDK) {
            // Use the channel from requestBody
            let sdkAuthParams = getSdkAuthParamsFromIntentAndChannel(
                intent: response.quantumLeap.intent ?? "",
                channel: postIntentRequestBody.channel
            )
            return PostIntentUseCaseResponse(
                intent: nil,
                otplessResponse: initiateResponse,
                tokenAsIdUIdAndTimerSettings: tokenAsIdUIdAndTimerSettings,
                passkeyRequestStr: nil,
                uid: nil,
                sdkAuthParams: sdkAuthParams,
                isPollingRequired: true,
                isSNA: false
            )
        }

        let intent = response.quantumLeap.intent ?? ""
        let channel = response.quantumLeap.channel

        if (channel == "SILENT_AUTH") {
            // Make SNA request. If SNA fails, it will invoke a callback that starts the polling of transactionStatusAPI
            return PostIntentUseCaseResponse(
                intent: intent,
                otplessResponse: OtplessResponse.createSuccessfulInitiateResponse(
                    requestId: response.quantumLeap.channelAuthToken,
                    channel: response.quantumLeap.channel,
                    authType: response.quantumLeap.channel,
                    deliveryChannel: response.quantumLeap.communicationMode
                ),
                tokenAsIdUIdAndTimerSettings: tokenAsIdUIdAndTimerSettings,
                passkeyRequestStr: nil,
                uid: nil,
                sdkAuthParams: nil,
                isPollingRequired: true,
                isSNA: true
            )
        }

        if (channel == "DEVICE") {
            return PostIntentUseCaseResponse(
                intent: nil,
                otplessResponse: initiateResponse,
                tokenAsIdUIdAndTimerSettings: tokenAsIdUIdAndTimerSettings,
                passkeyRequestStr: intent,
                uid: nil,
                sdkAuthParams: nil,
                isPollingRequired: false,
                isSNA: false
            )
        }
        
        return PostIntentUseCaseResponse(
            intent: intent,
            otplessResponse: initiateResponse,
            tokenAsIdUIdAndTimerSettings: tokenAsIdUIdAndTimerSettings,
            passkeyRequestStr: nil,
            uid: nil,
            sdkAuthParams: nil,
            isPollingRequired: true,
            isSNA: false
        )
        
    }
    
    
    func parseFailureResponse(_ error: Error, request: OtplessRequest) -> PostIntentUseCaseResponse {
        guard let apiError = error as? ApiError else {
            return PostIntentUseCaseResponse(
                intent: nil,
                otplessResponse:  OtplessResponse(
                    responseType: ResponseTypes.INITIATE,
                    response: [
                        "errorCode": 500,
                        "errorMessage": "Could not get data from intent: \(error.localizedDescription)"
                    ],
                    statusCode: 500
                ),
                tokenAsIdUIdAndTimerSettings: nil,
                passkeyRequestStr: nil,
                uid: nil,
                sdkAuthParams: nil,
                isPollingRequired: false,
                isSNA: false
            )
        }
        
        log(message: "Could not get data from intent: " + apiError.localizedDescription, type: .API_RESPONSE_FAILURE)
        
        var otplessResponse: OtplessResponse? = nil
        otplessResponse = OtplessResponse(
            responseType: .INITIATE,
            response: apiError.getResponse(),
            statusCode: apiError.statusCode
        )
        
        return PostIntentUseCaseResponse(
            intent: nil,
            otplessResponse: otplessResponse,
            tokenAsIdUIdAndTimerSettings: nil,
            passkeyRequestStr: nil,
            uid: nil,
            sdkAuthParams: nil,
            isPollingRequired: false,
            isSNA: false
        )
    }
    
    
    private func parseInitiateResponse(data: IntentResponse?) -> OtplessResponse? {
        guard let data = data else {
            let errorResponse: [String: Any] = [
                "errorCode": 500,
                "errorMessage": "Got null response from intent."
            ]
            return OtplessResponse(
                responseType: .INITIATE,
                response: errorResponse,
                statusCode: 500
            )
        }
        
        if data.quantumLeap.channel == "DEVICE" {
            return nil
        }
        
        let channel: String
        if Otpless.shared.hasMerchantSelectedExternalSDK {
            if data.quantumLeap.channel.contains("FACEBOOK") {
                channel = OtplessChannelType.FACEBOOK_SDK.rawValue
            } else if data.quantumLeap.channel.contains("APPLE") {
                channel = OtplessChannelType.APPLE_SDK.rawValue
            } else {
                channel = OtplessChannelType.GOOGLE_SDK.rawValue
            }
        } else {
            channel = data.quantumLeap.channel
        }
        
        Otpless.shared.onCommunicationModeChange(data.quantumLeap.communicationMode ?? "NA")
        
        return OtplessResponse.createSuccessfulInitiateResponse(
            requestId: data.quantumLeap.channelAuthToken,
            channel: channel,
            authType: data.quantumLeap.channel,
            deliveryChannel: data.quantumLeap.communicationMode
        )
    }
    
    private func getSdkAuthParamsFromIntentAndChannel(intent: String, channel: String) -> SdkAuthParams {
        guard !intent.isEmpty, let urlComponents = URLComponents(string: intent), let host = urlComponents.host, !host.isEmpty else {
            return SdkAuthParams(
                nonce: "invalid_or_empty_intent",
                clientId: "invalid_or_empty_intent",
                channelType: OtplessChannelType.fromString(channel),
                permissions: ["email", "public_profile"]
            )
        }
        
        let queryItems = urlComponents.queryItems ?? []
        let nonce = queryItems.first(where: { $0.name == "nonce" })?.value ?? "failed_to_fetch"
        let clientId = queryItems.first(where: { $0.name == "client_id" })?.value
        ?? queryItems.first(where: { $0.name == "clientId" })?.value
        ?? "failed_to_fetch"
        
        let channelType = OtplessChannelType.fromString(channel)
        
        return SdkAuthParams(
            nonce: nonce,
            clientId: clientId,
            channelType: channelType,
            permissions: ["email", "public_profile"]
        )
    }
    
    private func shouldTriggerWebAuthn(_ otplessRequest: OtplessRequest) -> Bool {
        if #available(iOS 15.0, *) {
            return usecaseProvider.passkeyUseCase.isWebAuthnsupportedOnDevice()
        } else {
            return false
        }
    }
}

internal struct PostIntentUseCaseResponse {
    var intent: String?
    var otplessResponse: OtplessResponse?
    var tokenAsIdUIdAndTimerSettings: TokenAsIdUIdAndTimerSettings?
    var passkeyRequestStr: String?
    var uid: String?
    var sdkAuthParams: SdkAuthParams?
    var isPollingRequired: Bool
    var isSNA: Bool
    
    init(
        intent: String?,
        otplessResponse: OtplessResponse?,
        tokenAsIdUIdAndTimerSettings: TokenAsIdUIdAndTimerSettings?,
        passkeyRequestStr: String?,
        uid: String?,
        sdkAuthParams: SdkAuthParams?,
        isPollingRequired: Bool,
        isSNA: Bool
    ) {
        self.intent = intent
        self.otplessResponse = otplessResponse
        self.tokenAsIdUIdAndTimerSettings = tokenAsIdUIdAndTimerSettings
        self.passkeyRequestStr = passkeyRequestStr
        self.uid = uid
        self.sdkAuthParams = sdkAuthParams
        self.isPollingRequired = isPollingRequired
        self.isSNA = isSNA
    }
}
