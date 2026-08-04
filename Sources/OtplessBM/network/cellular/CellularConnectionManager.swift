//
//  CellularConnectionManager.swift
//  OtplessSDK
//
//  Created by Sparsh on 19/01/25.
//

import Network
#if canImport(UIKit)
import UIKit
#else
import Foundation
#endif

typealias ResultHandler = @Sendable (ConnectionResult) -> Void

/// Force connectivity to cellular only
@available(iOS 12.0, *)
final class CellularConnectionManager: @unchecked Sendable {
    
    private var connection: NWConnection?
    
    //Mitigation for tcp timeout not triggering any events.
    private var timer: Timer?
    private var CONNECTION_TIME_OUT = 7.0
    private var pathMonitor: NWPathMonitor?
    private let accessQueue = DispatchQueue(label: "com.otpless.cellular.connection.manager")
       private var _checkResponseHandler: ResultHandler?
    private var checkResponseHandler: ResultHandler? {
          get {
              accessQueue.sync { _checkResponseHandler }
          }
          set {
              accessQueue.async { self._checkResponseHandler = newValue }
          }
      }
    
    public convenience init(connectionTimeout: Double) {
        self.init()
        self.CONNECTION_TIME_OUT = connectionTimeout
    }
    
    func updateConnectionTimeout(_ connectionTimeout: Double) {
        self.CONNECTION_TIME_OUT = connectionTimeout
    }
    
    func open(url: URL, operators: String?, completion: @escaping @Sendable (Result<[String: Any], SnaErrorKind>) -> Void) {
        guard let _ = url.scheme, let _ = url.host else {
            completion(Result.failure(SnaErrorKind.badUrl(url: "Url is missing scheme or host.\nURL: \(url.absoluteString)")))
            return
        }
        
        // This closure will be called on main thread
        checkResponseHandler = { [weak self] (response) -> Void in
            guard let self = self else {
                completion(Result.failure(SnaErrorKind.callbackInstanceLost(response: response.toDict())))
                return
            }
            
            switch response {
            case .follow(let redirectResult):
                if let url = redirectResult.url {
                    self.createTimer()
                    if let checkResponseHandler = self.checkResponseHandler {
                        self.activateConnectionForDataFetch(url: url, completion: checkResponseHandler)
                    }
                } else {
                    self.cleanUp()
                }
            case .err(let error):
                self.cleanUp()
                completion(Result.failure(error))
            case .dataOK(let connResp):
                self.cleanUp()
                completion(connResp.toResult())
            case .dataErr(let connResp):
                self.cleanUp()
                completion(connResp.toResult())
            }
        }

        //Initiating on the main thread to synch, as all connection update/state events will also be called on main thread
        DispatchQueue.main.async {
            self.startMonitoring()
            self.createTimer()
            if let checkResponseHandler = self.checkResponseHandler {
                self.activateConnectionForDataFetch(url: url, completion: checkResponseHandler)
            }
        }
    }
    
    
    func cancelExistingConnection() {
        if self.connection != nil {
            self.connection?.cancel() // This should trigger a state update
            self.connection = nil
        }
    }
    
    func createConnectionUpdateHandler(completion: @escaping @Sendable ResultHandler, readyStateHandler: @escaping @Sendable ()-> Void) -> @Sendable (NWConnection.State) -> Void {
        return { (newState) in
            switch (newState) {
            case .setup:
                break
            case .preparing:
                break
            case .ready:
                readyStateHandler() //Send and Receive
            case .waiting( _):
                break
            case .cancelled:
                break
            case .failed(let error):
                completion(.err(SnaErrorKind.nwProtocolConnectionError(state: "failed")))
            @unknown default:
                completion(.err(SnaErrorKind.nwProtocolConnectionError(state: "unknown")))
            }
        }
    }
    
    // As url.path property truncates the / if present in the last that is why string splitted
    func extractPathFromURL(urlString: String?) -> String? {
        guard let urlString = urlString,
              let hostRange = urlString.range(of: "//"),
              let pathStart = urlString[hostRange.upperBound...].range(of: "/") else {
            return nil
        }
        
        var path = urlString[pathStart.lowerBound...]
        
        if let queryStart = path.range(of: "?") {
            path = path[..<queryStart.lowerBound]
        }
        
        return String(path)
    }
    
    func createHttpCommand(url: URL) -> String? {
        guard let host = url.host, let scheme = url.scheme  else {
            return nil
        }
        var path = ""
        if #available(iOS 16.0, *) {
             path = url.path(percentEncoded: false)
        } else {
            // Fallback on earlier versions
            path = extractPathFromURL(urlString: url.absoluteString) ?? ""
        }
        // the path method is stripping ending / so adding it back
        if (url.absoluteString.hasSuffix("/") && !url.path.hasSuffix("/")) {
            path += "/"
        }

        if (path.count == 0) {
            path = "/"
        }

        var cmd = String(format: "GET %@", path)
        
        if let q = url.query {
            cmd += String(format:"?%@", q)
        }
        
        cmd += String(format:" HTTP/1.1\r\nHost: %@", host)
        if (scheme.starts(with:"https") && url.port != nil && url.port != 443) {
            cmd += String(format:":%d", url.port!)
        } else if (scheme.starts(with:"http") && url.port != nil && url.port != 80) {
            cmd += String(format:":%d", url.port!)
        }

        cmd += "\r\nAccept: text/html,application/json,application/xhtml+xml,application/xml,*/*"
        cmd += "\r\nConnection: close\r\n\r\n"
        return cmd
    }
    
    func createConnection(scheme: String, host: String, port: Int? = nil) -> NWConnection? {
        if scheme.isEmpty ||
            host.isEmpty ||
            !(scheme.hasPrefix("http") ||
              scheme.hasPrefix("https")) {
            return nil
        }
        
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 5 //Secs
        tcpOptions.enableKeepalive = false
        
        var tlsOptions: NWProtocolTLS.Options?
        var fport = (port != nil ? NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port!)) : NWEndpoint.Port.http)
        
        if (scheme.starts(with:"https")) {
            fport = (port != nil ? NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port!)) : NWEndpoint.Port.https)
            tlsOptions = .init()
            tcpOptions.enableFastOpen = true //Save on tcp round trip by using first tls packet
        }
        
        let params = NWParameters(tls: tlsOptions , tcp: tcpOptions)
        params.serviceClass = .responsiveData

        params.requiredInterfaceType = .cellular
        params.prohibitExpensivePaths = false
        params.prohibitedInterfaceTypes = [.wifi, .loopback, .wiredEthernet]

        connection = NWConnection(host: NWEndpoint.Host(host), port: fport, using: params)
        
        return connection
    }
    
    func parseHttpStatusCode(response: String) -> Int {
        let status = response[response.index(response.startIndex, offsetBy: 9)..<response.index(response.startIndex, offsetBy: 12)]
        return Int(status) ?? 0
    }
    
    /// Decodes a response, first attempting with UTF8 and then fallback to ascii
    /// - Parameter data: Data which contains the response
    /// - Returns: decoded response as String
    func decodeResponse(data: Data) -> String? {
        guard let response = String(data: data, encoding: .utf8) else {
            return String(data: data, encoding: .ascii)
        }
        return response
    }
    
    func parseRedirect(requestUrl: URL, response: String) -> RedirectResult? {
        guard let _ = requestUrl.host else {
            return nil
        }
        //header could be named "Location" or "location"
        if let range = response.range(of: #"ocation: (.*)\r\n"#, options: .regularExpression) {
            let location = response[range]
            let redirect = location[location.index(location.startIndex, offsetBy: 9)..<location.index(location.endIndex, offsetBy: -1)]
            // some location header are not properly encoded
            let cleanRedirect = redirect.replacingOccurrences(of: " ", with: "+")
            if let redirectURL =  URL(string: String(cleanRedirect)) {
                return RedirectResult(url: redirectURL.host == nil ? URL(string: redirectURL.description, relativeTo: requestUrl)! : redirectURL, cookies: nil)
            } else {
                return nil
            }
        }
        return nil
    }
    
    func createTimer() {
        
        if let timer = self.timer, timer.isValid {
            timer.invalidate()
        }

        self.timer = Timer.scheduledTimer(timeInterval: self.CONNECTION_TIME_OUT,
                                          target: self,
                                          selector: #selector(self.fireTimer),
                                          userInfo: nil,
                                          repeats: false)
    }
    
    @objc func fireTimer() {
        timer?.invalidate()
        checkResponseHandler?(.err(SnaErrorKind.timerFinished))
    }
    
    func startMonitoring() {
        
        if let monitor = pathMonitor { monitor.cancel() }
        
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { path in
            let interfaceTypes = path.availableInterfaces.map { $0.type }
            for interfaceType in interfaceTypes {
                #if DEBUG
                switch interfaceType {
                case .wifi:
                    print("Path is Wi-Fi")
                case .cellular:
                    print("Path is Cellular ipv4 \(path.supportsIPv4.description) ipv6 \(path.supportsIPv6.description)")
                case .wiredEthernet:
                    print("Path is Wired Ethernet")
                case .loopback:
                    print("Path is Loopback")
                case .other:
                    print("Path is other")
                default:
                    print("Path is unknown")
                }
                #endif
            }
        }
        
        pathMonitor?.start(queue: .main)
    }
    
    func stopMonitoring() {
        if let monitor = pathMonitor {
            monitor.cancel()
            pathMonitor = nil
        }
    }
    
    func cleanUp() {
        self.timer?.invalidate()
        self.stopMonitoring()
        self.cancelExistingConnection()
    }
    
    private func activateConnectionForDataFetch(url: URL, completion: @escaping ResultHandler) {
        self.cancelExistingConnection()
        guard let scheme = url.scheme,
              let host = url.host else {
            completion(.err(SnaErrorKind.badUrl(url: url.absoluteString)))
            return
        }
        
        guard let command = createHttpCommand(url: url) else {
            completion(.err(SnaErrorKind.httpCommandConversionError(command: nil)))
            return
        }
        guard let data = command.data(using: .utf8) else {
            completion(.err(SnaErrorKind.httpCommandConversionError(command: command)))
            return
        }
        
        connection = createConnection(scheme: scheme, host: host, port: url.port)
        if let connection = connection {
            connection.stateUpdateHandler = createConnectionUpdateHandler(completion: completion, readyStateHandler: { [weak self] in
                self?.sendAndReceiveWithBody(requestUrl: url, data: data, completion: completion)
            })
            // All connection events will be delivered on the main thread.
            connection.start(queue: .main)
        } else {
            completion(.err(SnaErrorKind.nwProtocolMakeError))
        }
    }
    
    func sendAndReceiveWithBody(requestUrl: URL, data: Data, completion: @escaping ResultHandler) {
        connection?.send(content: data, completion: NWConnection.SendCompletion.contentProcessed({ (error) in
            if let err = error {
                completion(.err(SnaErrorKind.nwProtocolFailedToSendData(url: requestUrl, error: err)))
            }
        }))
        
        timer?.invalidate()

        //Read the entire response body
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536){ data, context, isComplete, error in
            
            if let err = error {
                completion(.err(SnaErrorKind.nwProtocolFailedToReceiveData(url: requestUrl, error: err)))
                return
            }
            
            if let d = data, !d.isEmpty, let response = self.decodeResponse(data: d) {
                let status = self.parseHttpStatusCode(response: response)
                
                let snaBodyDict: [String: Any]? = {
                    guard let d = self.getResponseBody(response: response),
                          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                        return nil
                    }
                    return obj
                }()

                switch status {
                case 200...202:
                    OtplessBMEvents.Sna.response(statusCode: status, body: snaBodyDict)
                    if let r = self.getResponseBody(response: response) {
                        completion(.dataOK(ConnectionResponse(request: requestUrl, status: status, body: r)))
                    } else {
                        completion(.dataOK(ConnectionResponse(request: requestUrl, status: status, body: nil)))
                    }
                case 204:
                    OtplessBMEvents.Sna.response(statusCode: status, body: nil)
                    completion(.dataOK(ConnectionResponse(request: requestUrl, status: status, body: nil)))
                case 301...303, 307...308:
                    guard let ru = self.parseRedirect(requestUrl: requestUrl, response: response) else {
                        completion(.err(SnaErrorKind.redirectParsingFailed(response: response)))
                        return
                    }
                    OtplessBMEvents.Sna.redirected(location: ru.url?.absoluteString ?? "", statusCode: status)
                    completion(.follow(ru))
                case 400...451:
                    OtplessBMEvents.Sna.response(statusCode: status, body: snaBodyDict)
                    if let r = self.getResponseBody(response: response) {
                        completion(.dataErr(ConnectionResponse(request: requestUrl, status: status, body:r)))
                    } else {
                        completion(.err(SnaErrorKind.nonOkError(
                            url: requestUrl, code: status, data: snaBodyDict ?? [:]))
                        )
                    }
                case 500...511:
                    OtplessBMEvents.Sna.response(statusCode: status, body: snaBodyDict)
                    if let r = self.getResponseBody(response: response) {
                        completion(.dataErr(ConnectionResponse(request: requestUrl, status: status, body:r)))
                    } else {
                        completion(
                            .err(SnaErrorKind.nonOkError(url: requestUrl, code: status, data: snaBodyDict ?? [:]))
                        )
                    }
                default:
                    completion(
                        .err(SnaErrorKind.nonOkError(url: requestUrl, code: status, data: snaBodyDict ?? [:]))
                    )
                }
            } else {
                completion(.err(SnaErrorKind.invalidResponseBody))
            }
        }
    }
    
    func getResponseBody(response: String) -> Data? {
        
        if let rangeContentType = response.range(of: #"Content-Type: (.*)\r\n"#, options: .regularExpression) {
            // retrieve content type
            let contentType = response[rangeContentType]
            let type = contentType[contentType.index(contentType.startIndex, offsetBy: 9)..<contentType.index(contentType.endIndex, offsetBy: -1)]
            if (type.contains("application/json") || type.contains("application/hal+json") || type.contains("application/problem+json")) {
                if let range = response.range(of: "\r\n\r\n") {
                    if let rangeTransferEncoding = response.range(of: #"Transfer-Encoding: chunked\r\n"#, options: .regularExpression) {
                        if (!rangeTransferEncoding.isEmpty) {
                            if let r1 = response.range(of: "\r\n\r\n") , let r2 = response.range(of:"\r\n0\r\n") {
                                let c = response[r1.upperBound..<r2.lowerBound]
                                if let start = c.firstIndex(of: "{") {
                                    let json = c[start..<c.index(c.endIndex, offsetBy: 0)]
                                    let jsonString = String(json)
                                    guard let data = jsonString.data(using: .utf8) else {
                                        return nil
                                    }
                                    return data
                                }
                            }
                        }
                    }
                    let content = response[range.upperBound..<response.index(response.endIndex, offsetBy: 0)]
                    if let start = content.firstIndex(of: "{") {
                        let json = content[start..<response.index(response.endIndex, offsetBy: 0)]
                        let jsonString = String(json)
                        guard let data = jsonString.data(using: .utf8) else {
                            return nil
                        }
                        return data
                    }
                }
            }
        }
        return nil
    }
}

// MARK: - RedirectResult

internal struct RedirectResult {
    public var url: URL?
    public let cookies: [HTTPCookie]?
    
    func toDict() -> [String: String] {
        var result: [String: String] = [:]
        result["url"] = url?.absoluteString ?? ""
        if let cookies = cookies, !cookies.isEmpty {
            result["cookies"] = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        return result
    }
}

// MARK: - ConnectionResponse

internal struct ConnectionResponse {
    public let request: URL
    public var status: Int
    public let body: Data?;
    
    func toResult() -> Result<[String: Any], SnaErrorKind> {
        if status >= 200 && status < 300 {
            do {
                // load JSON response into a dictionary
                if let body = body, let dictionary = try JSONSerialization.jsonObject(with: body, options: .mutableContainers) as? [String : Any] {
                    return Result.success(dictionary)
                } else {
                    return Result.failure(SnaErrorKind.invalidResponseBody)
                }
            } catch {
                return Result.failure(SnaErrorKind.parsingError(src: body, error: error))
            }
        } else {
            let errorDescription: String = String(data: body ?? Data(), encoding: .utf8) ?? ""
            var errorBody : [String: String] = [
                "status": String(status),
                "error": "api_not_ok_response",
                "error_response": errorDescription
            ]
            return Result.failure(SnaErrorKind.nonOkError(url: request, code: status, data: errorBody))
        }
    }
    
    func toDict() -> [String: String] {
        var result = ["status": String(status)]
        if let body = body {
            result["body"] = String(data: body, encoding: .utf8) ?? ""
        }
        return result
    }
}

// MARK: - ConnectionResult

internal enum ConnectionResult {
    case err(SnaErrorKind)
    case dataOK(ConnectionResponse)
    case dataErr(ConnectionResponse)
    case follow(RedirectResult);
    
    func toDict() -> [String: String] {
        switch self {
        case .err(let result):
            return result.toDictionary()
        case .dataOK(let r):
            return r.toDict()
        case .dataErr(let r):
            return r.toDict()
        case .follow(let r):
            return r.toDict()
        }
    }
}

// MARK: - SnaErrorKind

internal enum SnaErrorKind: Error {
    // connectivity manager related error
    case iosConnectivityApiUnavailable
    case callbackInstanceLost(response: [String: String])
    
    // url and data parsing releated error
    case badUrl(url: String)
    case parsingError(src: Data?, error: Error)
    case timerFinished
    case httpCommandConversionError(command: String?)
    
    // connectivity manager callback related error
    case nwProtocolConnectionError(state: String)
    case noDataConnectivity(error: Error)
    case nwProtocolMakeError
    case nwProtocolFailedToSendData(url: URL, error: Error)
    case nwProtocolFailedToReceiveData(url: URL, error: Error)
    case nonOkError(url: URL, code: Int, data: [String: Any])
    case invalidResponseBody
    
    
    
    // sna redirect and status code releated error releted error
    case redirectParsingFailed(response: String?)
    
    case pollingTimeOut
    
    ;
    
    func toDictionary() -> [String: String] {
        switch self {
        // connectivity manager related error
        case .iosConnectivityApiUnavailable:
            return [
                Constants.ERROR_KEY: "cellular_api_unavaiable",
                Constants.ERROR_DESCRIPTION_KEY: "could not get instance of OtplessCellularManager."
            ]
        case .callbackInstanceLost(var result):
            result[Constants.ERROR_KEY] = "cellular_api_instance_lost"
            result[Constants.ERROR_DESCRIPTION_KEY] = "The callback self instance is lost. could not revert the callback."
            return result
        
        // url and data parsing releated error
        case .badUrl(let url):
            return [
                Constants.ERROR_KEY: "sna_bad_url",
                Constants.ERROR_DESCRIPTION_KEY: "Failed to parse the sna URL \(url)."
            ]
        case .parsingError(src: let src, error: let error):
            return [
                Constants.ERROR_KEY: "sna_parsing_error",
                Constants.ERROR_DESCRIPTION_KEY: "Failed to parse the sna response: \(error).\n\(String(data: src ?? Data(), encoding: .utf8) ?? "")"
            ]
        case .timerFinished:
            return [
                Constants.ERROR_KEY: "sna_url_timeout",
                Constants.ERROR_DESCRIPTION_KEY: "Didn't get the response in 7 seconds. Closing nw protocol call."
            ]
        case .httpCommandConversionError(let error):
            var result: [String: String] = [:]
            result[Constants.ERROR_KEY] = "sna_http_command_conversion_error"
            if let error = error {
                result[Constants.ERROR_DESCRIPTION_KEY] = "Failed to convert HTTP command to Data\ncommand: \(error)"
            } else {
                result[Constants.ERROR_DESCRIPTION_KEY] = "Failed to create the HTTP command"
            }
            return result
        
        // connectivity manager callback related error
        case .noDataConnectivity(let error):
            return [
                Constants.ERROR_KEY: "sna_no_data_connectivity",
                Constants.ERROR_DESCRIPTION_KEY: error.localizedDescription ?? "No data connectivity. Please check your internet connection."
            ]
        case .nwProtocolConnectionError(let state):
            return [
                Constants.ERROR_KEY: "nw_protocol_connection_error",
                Constants.ERROR_DESCRIPTION_KEY: "Failed to create NW connection. state is: \(state)",
            ]
        case .nwProtocolMakeError:
            return [
                Constants.ERROR_KEY: "nw_protocol_make_error",
                Constants.ERROR_DESCRIPTION_KEY: "iOS api failed to create NWPathConnection instance.",
            ]
        case .nwProtocolFailedToSendData(let url, let error):
            return [
                Constants.ERROR_KEY: "nw_protocol_data_send_error",
                Constants.ERROR_DESCRIPTION_KEY: error.localizedDescription ?? "NWPathConnection failed to send the data.",
                "url": url.absoluteString ?? "NA"
            ]
        case .nwProtocolFailedToReceiveData(let url, let error):
            return [
                Constants.ERROR_KEY: "nw_protocol_data_receive_error",
                Constants.ERROR_DESCRIPTION_KEY: error.localizedDescription ?? "NWPathConnection failed to receive the data.",
                "url": url.absoluteString
            ]
        case .nonOkError(let url, let code, let data):
            return [
                Constants.ERROR_KEY: "sna_non_ok_response",
                Constants.ERROR_DESCRIPTION_KEY: "Non 200..299 response received.\ndata:\n\(Utils.convertDictionaryToString(data))",
                "status_code": String(code),
                "url": url.absoluteString ?? "NA"
            ]
        case .invalidResponseBody:
            return [
                Constants.ERROR_KEY: "invalid_sna_response",
                Constants.ERROR_DESCRIPTION_KEY: "No response received from NWPathConnection",
            ]
            
        // sna redirect api error
        case .redirectParsingFailed(let response):
            return [
                Constants.ERROR_KEY: "sna_redirect_parsing_failed",
                Constants.ERROR_DESCRIPTION_KEY: "Failed to parse redirect response: \(response)"
            ]
        
        // sna polling related timeout
        case .pollingTimeOut:
            return [
                Constants.ERROR_KEY: "sna_polling_timeout",
                Constants.ERROR_DESCRIPTION_KEY: "Transaction could not be polled anymore."
            ]
        }
    }
}
