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
        queryParameters: [String: Any]? = nil
    ) async throws -> Data {
        // Replace {state} placeholder in the path
        var newPath = path
        if let state = state {
            newPath = path.replacingOccurrences(of: "{state}", with: state)
        }
        
        let url = constructURL(baseURL: baseURLUserAuth, path: newPath, queryParameters: queryParameters, method: method)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = userAuthTimeout
        
        if method.uppercased() == "POST" {
            let newBody = getBody(withExistingBody: body)
            request.httpBody = try? JSONSerialization.data(withJSONObject: newBody, options: [])
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if enableLogging {
                logRequestAndResponse(request, body: body, response, data: data)
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            
            if !(200..<300).contains(httpResponse.statusCode) {
                var errorBody: [String: Any] = [:]
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    errorBody = json
                }
                
                throw ApiError(
                    message: errorBody["message"] as? String ?? "Unexpected error occurred",
                    statusCode: httpResponse.statusCode,
                    responseJson: errorBody
                )
            }
            
            return data
        } catch {
            if let apiError = error as? ApiError {
                throw apiError
            } else if let urlError = error as? URLError {
                let code = urlError.errorCode
                let errorBody = urlError.errorUserInfo
                let errorMessage = errorBody["message"] as? String ?? "Something Went Wrong!"
                throw ApiError(message: errorMessage, statusCode: code, responseJson: errorBody)
            } else {
                throw ApiError(message: error.localizedDescription, statusCode: 500, responseJson: [
                    "errorCode": "500",
                    "errorMessage": "Something Went Wrong!"
                ])
            }
        }
    }
    
    private func getBody(withExistingBody body: [String: Any]?) -> [String: Any] {
        var mutableBody: [String: Any] = [:]
        
        for (key, value) in (body ?? [:]) {
            mutableBody[key] = value
        }
        
        mutableBody["origin"] = "https://otpless.com"
        mutableBody["version"] = "V4"
        mutableBody["tsId"] = Otpless.shared.tsid
        mutableBody["inId"] = Otpless.shared.inid
        mutableBody["deviceInfo"] = Otpless.shared.deviceInfo
        mutableBody["loginUri"] = Otpless.shared.merchantLoginUri
        mutableBody["appId"] = Otpless.shared.merchantAppId
        mutableBody["isHeadless"] = true
        mutableBody["packageName"] = Otpless.shared.packageName
        mutableBody["package"] = Otpless.shared.packageName
        mutableBody["platform"] = "HEADLESS"
        mutableBody["uid"] = Otpless.shared.uid
        
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
            URLQueryItem(name: "packageName", value: "com.digvijayanubhav.app"),
            URLQueryItem(name: "package", value: "com.digvijayanubhav.app"),
            URLQueryItem(name: "loginUri", value: "otpless.ztdr74hfnt0l7cp504zf://otpless"),
            URLQueryItem(name: "appId", value: Otpless.shared.merchantAppId),
            URLQueryItem(name: "deviceInfo", value: Otpless.shared.deviceInfo)
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
}

