//
//  ApiManager.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//


import Foundation

final class ApiManager: Sendable {
    private let userAuthTimeout: TimeInterval
    private let snaTimeout: TimeInterval
    private let enableLogging: Bool
    private let baseURLUserAuth = "https://user-auth.otpless.app"
    private let baseURLSekura = "http://80.in.safr.sekuramobile.com"
    
    // MARK: Paths for APIs
    static let GET_STATE_PATH = "/v2/state"
    static let POST_INTENT_PATH = "/v3/lp/user/transaction/intent/{state}"
    static let GET_MERCHANT_CONFIG_PATH = "/v2/lp/merchant/config/{state}"
    static let SSO_VERIFY_CODE_PATH = "/v3/lp/user/transaction/code/{state}"
    static let TRANSACTION_STATUS_PATH = "/v3/lp/user/transaction/status/{state}"
    static let SNA_TRANSACTION_STATUS_PATH = "/v3/lp/user/transaction/silent-auth-status/{state}"
    static let OTP_VERIFICATION_PATH = "/v3/lp/user/transaction/otp/{state}"
    
    init(
        userAuthTimeout: TimeInterval = 20.0,
        snaTimeout: TimeInterval = 5.0,
        enableLogging: Bool = false
    ) {
        self.userAuthTimeout = userAuthTimeout
        self.snaTimeout = snaTimeout
        self.enableLogging = enableLogging
    }
    
    // MARK: - User Auth API Request
    func performUserAuthRequest(
        state: String?,
        path: String,
        method: String,
        body: [String: Any]? = nil,
        shoudlAppendBasicParams: Bool = true,
        queryParameters: [String: Any]? = nil
    ) async throws -> Data {
        let startedAt = Date()
        var newPath = path
        if let state = state { newPath = path.replacingOccurrences(of: "{state}", with: state) }

        let url = constructURL(baseURL: baseURLUserAuth, path: newPath, queryParameters: queryParameters, method: method)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = userAuthTimeout
        
        if method.uppercased() == "POST" {
            let newBody = getBody(withExistingBody: body, shouldAppendBasicParameters: shoudlAppendBasicParams)
            request.httpBody = try? JSONSerialization.data(withJSONObject: newBody, options: [])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var xRequestId: String? = nil

        // NEW: stash for catch to use
        var pendingErrorData: Data? = nil
        var pendingStatusCode: Int? = nil

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if enableLogging {
                var sentBodyDict: [String: Any]? = nil
                if let hb = request.httpBody,
                   let obj = try? JSONSerialization.jsonObject(with: hb) as? [String: Any] {
                    sentBodyDict = obj
                }
                logRequestAndResponse(request, body: sentBodyDict, response, data: data)
            }

            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            if let kv = http.allHeaderFields.first(where: { String(describing: $0.key).lowercased() == "x-request-id" }) {
                xRequestId = kv.value as? String
            }

            if !(200..<300).contains(http.statusCode) {
                // just stash and throw; don't emit here
                pendingErrorData = data
                pendingStatusCode = http.statusCode

                let errorBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                throw ApiError(
                    message: errorBody["message"] as? String ?? "Unexpected error occurred",
                    statusCode: http.statusCode,
                    responseJson: errorBody
                )
            }

            // success tracking (if you still want it)
             if shouldTrackSuccess(path: newPath, method: method, statusCode: http.statusCode, data: data) {
                 sendApiEvent(event: .SUCCESS_API_RESPONSE, path: newPath, method: method, statusCode: http.statusCode,
                              startedAt: startedAt, xRequestId: xRequestId, data: nil)
             }

            return data
        } catch {
            // normalize
            let apiError: ApiError
            if let e = error as? ApiError {
                apiError = e
            } else if let urlError = error as? URLError {
                apiError = handleURLError(urlError)   // make sure this does NOT emit
            } else {
                apiError = ApiError(message: error.localizedDescription, statusCode: 500, responseJson: [
                    "errorCode": "500", "errorMessage": "Something Went Wrong!"
                ])
            }

            // single, centralized emit (uses stashed HTTP data/status if available)
            sendApiEvent(
                event: .ERROR_API_RESPONSE,
                path: newPath,
                method: method,
                statusCode: pendingStatusCode ?? apiError.statusCode,
                startedAt: startedAt,
                xRequestId: xRequestId,
                data: pendingErrorData,           // includes api_response when we had one
                apiError: apiError
            )

            throw apiError
        }
    }

    
    // Never track success for these two APIs; still track errors.
    private func isSuppressedSuccessPath(_ fullPath: String) -> Bool {
        let base1 = ApiManager.TRANSACTION_STATUS_PATH.replacingOccurrences(of: "{state}", with: "")
        let base2 = ApiManager.SNA_TRANSACTION_STATUS_PATH.replacingOccurrences(of: "{state}", with: "")
        return fullPath.contains(base1) || fullPath.contains(base2)
    }

    // Central place to decide success tracking; easy to extend later.
    private func shouldTrackSuccess(path: String, method: String, statusCode: Int, data: Data) -> Bool {
        if isSuppressedSuccessPath(path) { return false }
        return true                                       // track all other successes
    }

    // Uses your real sendEvent signature.
    private func sendApiEvent(
        event: EventConstants,
        path: String,
        method: String,
        statusCode: Int,
        startedAt: Date,
        xRequestId: String?,
        data: Data?,
        apiError: ApiError? = nil
    ) {
        var extras: [String: String] = [
            "which_api": path,
            "method": method,
            "status_code": "\(statusCode)",
            "latency": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
            "x-request-id": xRequestId ?? ""
        ]
        if let apiError = apiError {
            for (k, v) in apiError.getResponse() { extras[k] = v }
        }
        if event == .ERROR_API_RESPONSE {
            extras["api_response"] = stringifyApiResponse(data: data, maxLen: 8_192)
        }

        sendEvent(
            event: event,
            extras: extras,
            musId: ""                  // keep empty unless you have it at callsite
        )
    }

    private func stringifyApiResponse(data: Data?, maxLen: Int) -> String {
        guard let data = data else { return "[no response data]" }
        if let json = try? JSONSerialization.jsonObject(with: data),
           let compact = try? JSONSerialization.data(withJSONObject: json),
           var s = String(data: compact, encoding: .utf8) {
            if s.count > maxLen { s = String(s.prefix(maxLen)) + "…[truncated]" }
            return s
        }
        if var s = String(data: data, encoding: .utf8) {
            if s.count > maxLen { s = String(s.prefix(maxLen)) + "…[truncated]" }
            return s
        }
        return "[non-text response \(data.count) bytes]"
    }


    
    private func getBody(withExistingBody body: [String: Any]?,shouldAppendBasicParameters: Bool) -> [String: Any] {
        if (!shouldAppendBasicParameters) {
            return body ?? [:]
        }
            
            
        var mutableBody: [String: Any] = [:]
        
        for (key, value) in (body ?? [:]) {
            mutableBody[key] = value
        }
        
        mutableBody["origin"] = "https://otpless.com"
        mutableBody["version"] = "V4"
        mutableBody["tsId"] = Otpless.shared.tsid
        mutableBody["inId"] = Otpless.shared.inid
        mutableBody["deviceInfo"] = Utils.convertDictionaryToString(Otpless.shared.deviceInfo)
        mutableBody["loginUri"] = Otpless.shared.merchantLoginUri
        mutableBody["appId"] = Otpless.shared.merchantAppId
        mutableBody["isHeadless"] = true
        mutableBody["packageName"] = Otpless.shared.packageName
        mutableBody["package"] = Otpless.shared.packageName
        mutableBody["platform"] = "HEADLESS"
        mutableBody["uid"] = Otpless.shared.uid
        
        mutableBody["metadata"] = Utils.convertDictionaryToString([
            "appInfo": Utils.convertDictionaryToString(Otpless.shared.appInfo),
            "deviceInfo": Utils.convertDictionaryToString(Otpless.shared.deviceInfo)
        ])
        
        return mutableBody
    }

    
    // MARK: - Helpers
    private func constructURL(
        baseURL: String,
        path: String,
        queryParameters: [String: Any]?,
        method: String
    ) -> URL {
        var urlComponents = URLComponents(string: baseURL + path)!
        
        if method.uppercased() == "POST" {
            return urlComponents.url!
        }
        
        var extraQueryParams = [
            URLQueryItem(name: "origin", value: "https://otpless.com"),
            URLQueryItem(name: "tsId", value: Otpless.shared.tsid),
            URLQueryItem(name: "inId", value: Otpless.shared.inid),
            URLQueryItem(name: "version", value: "V4"),
            URLQueryItem(name: "isHeadless", value: "true"),
            URLQueryItem(name: "platform", value: "iOS"),
            URLQueryItem(name: "isLoginPage", value: "false"),
            URLQueryItem(name: "packageName", value: Otpless.shared.packageName),
            URLQueryItem(name: "package", value: Otpless.shared.packageName),
            URLQueryItem(name: "loginUri", value: Otpless.shared.merchantLoginUri),
            URLQueryItem(name: "appId", value: Otpless.shared.merchantAppId),
            URLQueryItem(name: "deviceInfo", value: Utils.convertDictionaryToString(Otpless.shared.deviceInfo))
        ]
        
        if !Otpless.shared.uid.isEmpty {
            extraQueryParams.append(URLQueryItem(name: "uid", value: Otpless.shared.uid))
        }
        
        if !Otpless.shared.asId.isEmpty {
            extraQueryParams.append(URLQueryItem(name: "asId", value: Otpless.shared.asId))
        }
        
        if !Otpless.shared.token.isEmpty {
            extraQueryParams.append(URLQueryItem(name: "token", value: Otpless.shared.token))
        }
        
        if let queryParameters = queryParameters {
            urlComponents.queryItems = queryParameters.map { URLQueryItem(name: $0.key, value: ($0.value as? String ?? "")) }
        }
        
        for queryItem in extraQueryParams {
            urlComponents.queryItems?.append(queryItem)
        }
        
        return urlComponents.url!
    }
    
    private func logRequestAndResponse(_ request: URLRequest, body: [String: Any]?, _ response: URLResponse?, data: Data) {
        let urlStr = request.url?.absoluteString
        let method = request.httpMethod
        var logBody: [String: Any] = [:]
        if let body = body {
            logBody = body
        }
        
        var statusCode = -1
        
        if let httpResponse = response as? HTTPURLResponse {
            statusCode = httpResponse.statusCode
        }
        
        log(
            message: """
            REQUEST: \n
            URL: \(urlStr ?? "")\n
            METHOD: \(method ?? "")\n
            Request body: \(Utils.convertDictionaryToString(logBody))\n\n\n
            
            RESPONSE: \n
            Status Code: \(statusCode)
            Data: \(String(data: data, encoding: .utf8) ?? "")
            """,
            type: .API_REQUEST_AND_RESPONSE
        )
    }
    
    private func handleURLError(_ urlError: URLError) -> ApiError {
        let code = urlError.errorCode
        let errorBody = urlError.errorUserInfo
        
        switch urlError.code {
        case .timedOut:
            return ApiError(message: "Request timeout", statusCode: 9100, responseJson: [
                "errorCode": "9100",
                "errorMessage": "Request timeout"
            ])
        case .networkConnectionLost:
            return ApiError(message: "Network connection was lost", statusCode: 9101, responseJson: [
                "errorCode": "9101",
                "errorMessage": "Network connection was lost"
            ])
        case .dnsLookupFailed:
            return ApiError(message: "DNS lookup failed", statusCode: 9102, responseJson: [
                "errorCode": "9102",
                "errorMessage": "DNS lookup failed"
            ])
        case .cannotConnectToHost:
            return ApiError(message: "Cannot connect to the server", statusCode: 9103, responseJson: [
                "errorCode": "9103",
                "errorMessage": "Cannot connect to the server"
            ])
        case .notConnectedToInternet:
            return ApiError(message: "No internet connection", statusCode: 9104, responseJson: [
                "errorCode": "9104",
                "errorMessage": "No internet connection"
            ])
        case .secureConnectionFailed:
            return ApiError(message: "Secure connection failed (SSL issue)", statusCode: 9105, responseJson: [
                "errorCode": "9105",
                "errorMessage": "Secure connection failed (SSL issue)"
            ])
        case .cancelled:
            return ApiError(message: "Otpless authentication request cancelled", statusCode: 9110, responseJson: [
                "errorCode": "9110",
                "errorMessage": "Otpless authentication request cancelled"
            ])
        default:
            let errorMessage = errorBody["message"] as? String ?? "Something Went Wrong!"
            return ApiError(message: errorMessage, statusCode: code, responseJson: errorBody)
        }
    }
}

