//
//  ApiRepository.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//

import Foundation

internal final class ApiRepository: @unchecked Sendable {
    private let apiManager: ApiManager
    private var otplessCellularNetwork: CellularConnectionManager?
    
    init(userAuthApiTimeout: TimeInterval, snaTimeout: TimeInterval, enableLogging: Bool) {
        self.apiManager = ApiManager(userAuthTimeout: userAuthApiTimeout, snaTimeout: snaTimeout, enableLogging: enableLogging)
        if #available(iOS 12.0, *) {
            self.otplessCellularNetwork = CellularConnectionManager()
        }
    }
    
    private func sendApiResponse(apiName: String, data: Data?, statusCode: Int, error: Error? = nil) {
        var responseDict: [String: Any] = ["apiName": apiName]
        
        if let data = data,
           let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            responseDict["data"] = jsonDict
        } else if let data = data,
                  let rawString = String(data: data, encoding: .utf8) {
            responseDict["raw"] = rawString
        }
        
        if let error = error {
            if let apiError = error as? ApiError {
                responseDict["error"] = apiError.getResponse()
            } else {
                responseDict["error"] = [
                    "errorCode": "\(statusCode)",
                    "errorMessage": error.localizedDescription
                ]
            }
        }
        
        let apiResponse = OtplessResponse(
            responseType: .API_RESPONSE,
            response: responseDict,
            statusCode: statusCode
        )
        
        DispatchQueue.main.async {
            Otpless.shared.responseDelegate?.onResponse(apiResponse)
            Otpless.shared.objcResponseDelegate?(apiResponse.toJsonString())
        }
    }
    
    func getState(
        queryParams: [String: String]
    ) async -> Result<StateResponse, Error> {
        let apiName = "getState"
        do {
            let data = try await self.apiManager.performUserAuthRequest(
                state: nil,
                path: ApiManager.GET_STATE_PATH,
                method: "GET",
                queryParameters: queryParams
            )
            sendApiResponse(apiName: apiName, data: data, statusCode: 200)
            return try Result.success(JSONDecoder().decode(StateResponse.self, from: data))
        } catch {
            let statusCode = (error as? ApiError)?.statusCode ?? 500
            sendApiResponse(apiName: apiName, data: nil, statusCode: statusCode, error: error)
            return Result.failure(error)
        }
    }
    
    func getMerchantConfig(
        state: String,
        queryParams: [String: String]
    ) async -> Result<MerchantConfigResponse, Error> {
        let apiName = "getMerchantConfig"
        do {
            let data = try await self.apiManager.performUserAuthRequest(
                state: state,
                path: ApiManager.GET_MERCHANT_CONFIG_PATH,
                method: "GET",
                queryParameters: queryParams
            )
            sendApiResponse(apiName: apiName, data: data, statusCode: 200)
            return try Result.success(JSONDecoder().decode(MerchantConfigResponse.self, from: data))
        } catch {
            let statusCode = (error as? ApiError)?.statusCode ?? 500
            sendApiResponse(apiName: apiName, data: nil, statusCode: statusCode, error: error)
            return Result.failure(error)
        }
    }
    
    func postIntent(
        state: String,
        body: PostIntentRequestBody
    ) async -> Result<IntentResponse, Error> {
        let apiName = "postIntent"
        do {
            let data = try await self.apiManager.performUserAuthRequest(
                state: state,
                path: ApiManager.POST_INTENT_PATH,
                method: "POST",
                body: body.toDict()
            )
            sendApiResponse(apiName: apiName, data: data, statusCode: 200)
            return try Result.success(JSONDecoder().decode(IntentResponse.self, from: data))
        }
        catch {
            let statusCode = (error as? ApiError)?.statusCode ?? 500
            sendApiResponse(apiName: apiName, data: nil, statusCode: statusCode, error: error)
            return Result.failure(error)
        }
    }
    
    func verifySSOCode(queryParams: [String: Any], state: String) async -> Result<TransactionStatusResponse, Error> {
        let apiName = "verifySSOCode"
        do {
            let data = try await self.apiManager.performUserAuthRequest(
                state: state,
                path: ApiManager.SSO_VERIFY_CODE_PATH,
                method: "POST",
                body: appendTokenIds(queryParams: queryParams)
            )
            sendApiResponse(apiName: apiName, data: data, statusCode: 200)
            return try Result.success(JSONDecoder().decode(TransactionStatusResponse.self, from: data))
        }
        catch {
            let statusCode = (error as? ApiError)?.statusCode ?? 500
            sendApiResponse(apiName: apiName, data: nil, statusCode: statusCode, error: error)
            return Result.failure(error)
        }
    }
    
    func verifyOTP(queryParams: [String: String], state: String) async -> Result<TransactionStatusResponse, Error> {
        let apiName = "verifyOTP"
        do {
            let data = try await self.apiManager.performUserAuthRequest(
                state: state,
                path: ApiManager.OTP_VERIFICATION_PATH,
                method: "POST",
                body: appendTokenIds(queryParams: queryParams)
            )
            sendApiResponse(apiName: apiName, data: data, statusCode: 200)
            return try Result.success(JSONDecoder().decode(TransactionStatusResponse.self, from: data))
        }
        catch {
            let statusCode = (error as? ApiError)?.statusCode ?? 500
            sendApiResponse(apiName: apiName, data: nil, statusCode: statusCode, error: error)
            return Result.failure(error)
        }
    }
    
    func appendTokenIds(queryParams: [String: Any]) -> [String: Any] {
            var result: [String: Any] = [:]
            result.merge(queryParams) {(_, new) in new}
            if !Otpless.shared.uid.isEmpty {
                result["uid"] = Otpless.shared.uid
            }
            if !Otpless.shared.asId.isEmpty {
                result["asId"] = Otpless.shared.asId
            }
            if !Otpless.shared.token.isEmpty {
                result["token"] = Otpless.shared.token
            }
            return result
    }
    
    func makeSNACall(url: String, onComplete: @escaping @Sendable ([String: Any]) -> Void) {
        guard let otplessCellularNetwork = otplessCellularNetwork else {
            onComplete(Utils.createErrorDictionary(errorCode: "5800", errorMessage: "Could not get instance of OtplessCellularManager"))
            return
        }
        
        guard let url = URL(string: url) else {
            onComplete(Utils.createErrorDictionary(errorCode: "5800", errorMessage: "Could not parse URL \(url)"))
            return
        }
        
        otplessCellularNetwork.open(url: url, operators: nil, completion:  { result in
            onComplete(result)
        })
    }
    
    func getSNATransactionStatus(queryParams: [String: String], state: String) async -> Result<TransactionStatusResponse, Error> {
        let apiName = "getSNATransactionStatus"
        do {
            let data = try await apiManager.performUserAuthRequest(
                state: state,
                path: ApiManager.SNA_TRANSACTION_STATUS_PATH,
                method: "GET",
                queryParameters: queryParams
            )

            if let dataString = String(data: data, encoding: .utf8) {
                log(message: "SNA transaction status data (utf8): \(dataString)", type: .SNA_RESPONSE)
            } else {
                log(message: "SNA transaction status data: <binary data length=\(data.count)>", type: .SNA_RESPONSE)
            }

            sendApiResponse(apiName: apiName, data: data, statusCode: 200)
            return try Result.success(JSONDecoder().decode(TransactionStatusResponse.self, from: data))
        }
        catch {
            let statusCode = (error as? ApiError)?.statusCode ?? 500
            sendApiResponse(apiName: apiName, data: nil, statusCode: statusCode, error: error)
            return Result.failure(error)
        }
    }
    
    func getTransactionStatus(queryParams: [String: String], state: String) async -> Result<TransactionStatusResponse, Error> {
        let apiName = "getTransactionStatus"
        do {
            let data = try await apiManager.performUserAuthRequest(
                state: state,
                path: ApiManager.TRANSACTION_STATUS_PATH,
                method: "GET",
                queryParameters: queryParams
            )
            sendApiResponse(apiName: apiName, data: data, statusCode: 200)
            return try Result.success(JSONDecoder().decode(TransactionStatusResponse.self, from: data))
        }
        catch {
            let statusCode = (error as? ApiError)?.statusCode ?? 500
            sendApiResponse(apiName: apiName, data: nil, statusCode: statusCode, error: error)
            return Result.failure(error)
        }
    }
}

extension ApiRepository {
    
    func handleResponse <T: Decodable> (
        response: Result<Data, Error>,
        onComplete: @escaping @Sendable (Result<T?, Error>) -> Void
    ) {
        switch response {
        case .success(let data):
            do {
                let response = try JSONDecoder().decode(T.self, from: data)
                onComplete(Result.success(response))
            } catch {
                onComplete(Result.failure(ApiError(message: "Could not decode response", statusCode: 500)))
            }
        case .failure(let error):
            if let error = error as? URLError {
                onComplete(Result.failure(error))
            }
        }
    }
}

extension ApiRepository {
    func updateSNAConnectionTimeout(connectionTimeout: Double) {
        self.otplessCellularNetwork?.updateConnectionTimeout(connectionTimeout)
    }
}
