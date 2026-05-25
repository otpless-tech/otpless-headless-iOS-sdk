//
//  CoreHttpClient.swift
//  OtplessBM
//
//  Created by Digvijay Singh on 27/01/26.
//
import Foundation

internal final class CoreHTTPClient {
    private let session: URLSession
    
    init(session: URLSession = .shared) {
        self.session = session
    }
    
    /// Execute a request and return ApiResponse<Data>
    func execute(_ request: URLRequest) async -> Result<Data, ApiError> {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                // No HTTPURLResponse — treat as transport failure
                return .failure(ApiError(message: "No HTTP response"))
            }
            if (200..<300).contains(http.statusCode) {
                return .success(data)
            } else {
                // Build ApiError with status + parsed JSON (if any)
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = json?["description"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                // sending api error
                sendEvent(event: .ERROR_API_RESPONSE, extras: [
                    "api_exception": message,
                    "method": request.httpMethod ?? "UNKNOWN",
                    "which_api": request.url?.absoluteString ?? "UNKNOWN"
                ])
                return .failure(ApiError(message: message, statusCode: http.statusCode, responseJson: json))
            }
        } catch {
            sendEvent(event: .ERROR_API_RESPONSE, extras: [
                "api_exception": error.localizedDescription,
                "method": request.httpMethod ?? "UNKNOWN",
                "which_api": request.url?.absoluteString ?? "unknown"
            ])
            // Transport errors (DNS, TLS, no network, timeouts, cancellations, etc.)
            return .failure(ApiError(message: error.localizedDescription))
        }
    }
    
    /// Build URLRequest and handle JSON body encoding errors → ApiResponse.error
    func makeRequest(
        baseURL: URL, path: String, method: String, headers: [String: String] = [:], jsonBody: [String: String]? = nil
    ) -> Result<URLRequest, ApiError> {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if let body = jsonBody {
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
                if req.value(forHTTPHeaderField: "Content-Type") == nil {
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            } catch {
                // Encoding error (kept because you asked to keep "encoding")
                return .failure(ApiError(message: "Encoding failed: \(error.localizedDescription)"))
            }
        }
        return .success(req)
    }
}


internal protocol SessionService: Sendable {
    func authenticateSession(headers: [String: String], body: [String: String]) async -> Result<Data, ApiError>
    func refreshSession(headers: [String: String], body: [String: String]) async -> Result<Data, ApiError>
    func deleteSession(sessionToken: String, headers: [String: String], body: [String: String]) async -> Result<Data, ApiError>
}


internal final class SessionServiceImpl: SessionService, @unchecked Sendable {
    private let baseURL: URL
    private let http: CoreHTTPClient
    
    init(http: CoreHTTPClient = CoreHTTPClient()) {
        self.baseURL = URL(string: "https://api.otpless.com/")!
        self.http = http
    }
    
    func authenticateSession(headers: [String : String], body: [String : String]) async -> Result<Data, ApiError> {
        switch http.makeRequest(
            baseURL: baseURL, path: "v4/session/authenticate", method: "POST", headers: headers, jsonBody: body
        ) {
        case .success(let req):
            return await http.execute(req)
        case .failure(let err):
            return .failure(err)
        }
    }
    
    func refreshSession(headers: [String : String], body: [String : String]) async -> Result<Data, ApiError> {
        switch http.makeRequest(baseURL: baseURL, path: "v4/session/refresh", method: "POST", headers: headers, jsonBody: body) {
        case .success(let req):
            return await http.execute(req)
        case .failure(let err):
            return .failure(err)
        }
    }
    
    func deleteSession(sessionToken: String, headers: [String : String], body: [String : String]) async -> Result<Data, ApiError> {
        let safeToken = sessionToken.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionToken
        switch http.makeRequest(baseURL: baseURL,path: "v4/session/\(safeToken)", method: "DELETE",headers: headers,jsonBody: body) {
        case .success(let req):
            return await http.execute(req)
        case .failure(let err):
            return .failure(err)
        }
    }
}

internal extension Result where Success == Data, Failure == ApiError {
    func decode<U: Decodable>(as type: U.Type, using decoder: JSONDecoder = .init()) -> Result<U, Failure> {
        switch self {
        case .success(let data):
            do {
                let value = try decoder.decode(U.self, from: data)
                return .success(value)
            } catch {
                return .failure(ApiError(message: "Decoding failed: \(error.localizedDescription)"))
            }
        case .failure(let err):
            return .failure(err)
        }
    }
}
