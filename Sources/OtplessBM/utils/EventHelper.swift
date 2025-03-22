//
//  EventHelper.swift
//  OtplessBM
//
//  Created by Sparsh on 20/02/25.
//

import Foundation
import Network

func sendEvent(event: EventConstants, extras: [String: String] = [:], musId: String = "", requestId: String = ""){
    do {
        var params = [String: String]()
        params["event_name"] = event.rawValue
        params["platform"] = "iOS-headless"
        params["sdk_version"] = "1.0.5"
        params["mid"] = Otpless.shared.merchantAppId
        params["event_timestamp"] = Utils.formatCurrentTimeToDateString()
        
        if let request = Otpless.shared.merchantOtplessRequest {
            params["request"] = Utils.convertDictionaryToString(request.getEventDict(), options: [])
        }
        
        params["tsid"] = Otpless.shared.tsid
        params["inid"] = Otpless.shared.inid
        params["event_id"] = String(Otpless.shared.getEventCounterAndIncrement())
        
        if !requestId.isEmpty {
            params["token"] = requestId
        }
        
        if !musId.isEmpty {
            params["musid"] = musId
        }
        
        var eventParams = extras
        
        var deviceInfo = Otpless.shared.deviceInfo
        deviceInfo.removeValue(forKey: "userAgent") // Remove userAgent key because parsing is failing on backend due to this and userAgent is by default added so we don't need it
        
        eventParams["device_info"] = Utils.convertDictionaryToString(deviceInfo)
        
        if let eventParamsData = try? JSONSerialization.data(withJSONObject: eventParams, options: []),
           let eventParamsString = String(data: eventParamsData, encoding: .utf8) {
            params["event_params"] = eventParamsString
        }
        
        fetchDataWithGET(
            apiRoute: "https://mtkikwb8yc.execute-api.ap-south-1.amazonaws.com/prod/appevent",
            params: params
        )
    }
    catch {
        log(message: "sendEvent failed: \(error)", type: .EVENT_CREATING_FAILED)
    }
}


private func fetchDataWithGET(apiRoute: String, params: [String: String]? = nil, headers: [String: String]? = nil) {
    var components = URLComponents(string:apiRoute)
    
    if let params = params {
        components?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    
    guard let url = components?.url else {
        return
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    
    if let headers = headers {
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }
    
    let task = URLSession.shared.dataTask(with: request) { (_, _, error) in
        if let error = error {
            log(message: "EVENT_ERROR: \(error.localizedDescription)", type: .EVENT_API_ERROR)
        }
    }
    task.resume()
}


enum EventConstants: String {
    case INIT_HEADLESS = "native_init_headless"
    case SET_HEADLESS_CALLBACK = "native_set_headless_callback"
    case START_HEADLESS = "native_start_headless"
    
    case HEADLESS_RESPONSE_SDK = "native_headless_response_ios_headless_sdk"
    
    case SNA_CALLBACK_RESULT = "native_sna_callback_result"
    
    case DEEPLINK_SDK = "native_deeplink_ios_headless_sdk"
    case GOOGLE_SDK_IOS_SDK = "native_google_sdk_ios_headless_sdk"
    case APPLE_SDK_IOS_SDK = "native_apple_sdk_ios_headless_sdk"
    case FACEBOOK_SDK_IOS_SDK = "native_facebook_sdk_ios_headless_sdk"
    case HEADLESS_TIMEOUT = "native_headless_timeout"
    case HEADLESS_MERCHANT_COMMIT = "native_headless_merchant_commit"
    
    case ERROR_API_RESPONSE = "native_api_response_error"
}
