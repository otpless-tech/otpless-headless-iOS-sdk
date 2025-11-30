import Foundation

#if canImport(OTPlessIntelligence)
import OTPlessIntelligence
#endif

@available(iOS 15.0, *)
internal final class OTPlessIntelligenceWorkerImpl: OTPlessIntelligenceWorker, @unchecked Sendable {

    private var isConfigured = false
    private var currentIntelligenceTask: Task<Void, Never>?
    private lazy var intelligenceDataUseCase: IntelligenceDataUseCase = {
        return IntelligenceDataUseCase()
    }()

    public func isIntelligenceSDKConfigured() -> Bool {
        return isConfigured
    }
    
    func configureIfNeeded(
        clientId: String,
        clientSecret: String,
        completion: @escaping (Bool, String?) -> Void
    ) {
        #if canImport(OTPlessIntelligence)
        let className = "OTPlessIntelligence.OTPlessIntelligence"
        guard NSClassFromString(className) != nil else {
            completion(false, "OTPless Intelligence runtime not found")
            return
        }

        guard !isConfigured else {
            completion(true, nil)
            return
        }
        let startTime = Date().timeIntervalSince1970

        OTPlessIntelligence.shared.configure(
            clientId: clientId,
            clientSecret: clientSecret
        ) { [weak self] success in
            guard let self = self else { return }
            self.isConfigured = success
            let delta = Date().timeIntervalSince1970 - startTime
            var eventJson: [String: String] = ["responseTime": String(Int(delta))]
            eventJson["result"] = success ? "success" : "fail"
            sendEvent(
                event: EventConstants.INIT_FRAUD_SDK,
                extras: eventJson
            )
            completion(success, success ? nil : "Failed to configure Intelligence SDK")
        }
        #else
        completion(false, "OTPless Intelligence SDK not linked in the project")
        #endif
    }

    func fetchScore(
        delegate: OTPlessIntelligenceDelegate?
    ) {
        #if canImport(OTPlessIntelligence)
        let className = "OTPlessIntelligence.OTPlessIntelligence"
        guard NSClassFromString(className) != nil else {
            delegate?.intelligenceNotAvailable(reason: "OTPless Intelligence runtime not found")
            return
        }

        guard #available(iOS 15.0, *) else {
            delegate?.intelligenceNotAvailable(reason: "OTPless Intelligence requires iOS 15+")
            return
        }

        let startTime = Date().timeIntervalSince1970

        OTPlessIntelligence.shared.getScore { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let res):
                let src = res.response
                let delta = Date().timeIntervalSince1970 - startTime
                var eventJson: [String: String] = ["result": "success"]
                eventJson["responseTime"] = String(Int(delta))
                sendEvent(
                    event: EventConstants.REQUEST_INTELLIGENCE_FRAUD_SDK,
                    extras: eventJson
                )
                
                let model = IntelligenceInfoData(
                    requestId: src.requestId,
                    deviceId: src.deviceId,
                    ip: src.ip,
                    simulator: src.simulator,
                    jailbroken: src.jailbroken,
                    vpn: src.vpn,
                    geoSpoofed: src.geoSpoofed,
                    appTampering: src.appTampering,
                    hooking: src.hooking,
                    proxy: src.proxy,
                    mirroredScreen: src.mirroredScreen,
                    cloned: src.cloned,
                    newDevice: src.newDevice,
                    factoryReset: src.factoryReset,
                    factoryResetTime: src.factoryResetTime,
                    sdkTsid: Otpless.shared.tsid,
                    gpsLocation: Self.convert(src.gpsLocation),
                    ipDetails: Self.convert(src.ipDetails),
                    deviceMeta: Self.convert(src.deviceMeta)
                )
                
                delegate?.intelligenceDataReceived(model)
                
                let tweaked = Self.tweakRawJSON(res.rawJson)
                self.pushIntelligenceDataToServerWithIntelligenceData(tweaked)
                
            case .failure(let error):
                let fetchError: IntelligenceFetchError
                
                switch error {
                case .intelligenceError(let requestId, let message):
                    var eventJson: [String: String] = ["result": "failure"]
                    eventJson["message"] = message
                    eventJson["requestId"] = requestId
                    sendEvent(
                        event: EventConstants.REQUEST_INTELLIGENCE_FRAUD_SDK,
                        extras: eventJson
                    )
                    fetchError = IntelligenceFetchError(
                        requestId: requestId,
                        message: "OTPless Intelligence fetch failed."
                    )
                    
                case .notConfigured:
                    var eventJson: [String: String] = ["result": "failure"]
                    eventJson["message"] = "OTPless Intelligence SDK is not configured"
                    sendEvent(
                        event: EventConstants.REQUEST_INTELLIGENCE_FRAUD_SDK,
                        extras: eventJson
                    )
                    fetchError = IntelligenceFetchError(
                        requestId: nil,
                        message: "OTPless Intelligence SDK is not configured"
                    )
                    
                case .unknown:
                    var eventJson: [String: String] = ["result": "failure"]
                    eventJson["message"] = "Unknown intelligence error"
                    sendEvent(
                        event: EventConstants.REQUEST_INTELLIGENCE_FRAUD_SDK,
                        extras: eventJson
                    )
                    fetchError = IntelligenceFetchError(
                        requestId: nil,
                        message: "Unknown intelligence error"
                    )
                }
                
                delegate?.intelligenceFailed(error: fetchError)
            }
        }
        #else
        delegate?.intelligenceNotAvailable(reason: "OTPless Intelligence SDK is not added")
        #endif
    }

    /// Generic JSON round-trip: vendor Encodable → local Decodable DTO
    private static func convert<Source: Encodable, Target: Decodable>(
        _ value: Source?
    ) -> Target? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        guard let data = try? encoder.encode(value) else { return nil }
        return try? decoder.decode(Target.self, from: data)
    }

    private static func tweakRawJSON(_ json: String) -> [String: Any] {
        guard
            let data = json.data(using: .utf8),
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func getRequestMap(token: String?) -> [String: Any] {
        var requestData: [String: Any] = ["tsId": Otpless.shared.tsid]
        
        requestData["inId"] = Otpless.shared.inid
        requestData["appId"] = Otpless.shared.merchantAppId
        if let state = Otpless.shared.state, !state.isEmpty {
            requestData["state"] = state
        }
        if !Otpless.shared.asId.isEmpty {
            requestData["asId"] = Otpless.shared.asId
        }
        if !Otpless.shared.drfID.isEmpty {
            requestData["dfrId"] = Otpless.shared.drfID
        }
        if let token = token {
            requestData["token"] = token
        }
        return requestData
    }
    
    internal func updateToDFRID(token: String?) {
        var eventJson: [String: String] = ["startType": "TxnCompleted"]
        sendEvent(
            event: EventConstants.UPDATE_REQUEST_INTELLIGENCE_FRAUD_SDK_START,
            extras: eventJson
        )
        if !Otpless.shared.drfID.isEmpty {
            let requestMap = Self.getRequestMap(token: token)
            postIntelligencData(data: requestMap)
        }
    }
    
    internal func updateToDFRID() {
        var eventJson: [String: String] = ["startType": "TxnCreated"]
        sendEvent(
            event: EventConstants.UPDATE_REQUEST_INTELLIGENCE_FRAUD_SDK_START,
            extras: eventJson
        )
        updateToDFRID(token: nil)
    }

    private func pushIntelligenceDataToServerWithIntelligenceData(_ json: [String: Any]) {
        var requestMap = Self.getRequestMap(token: nil)
        requestMap["data"] = json
        postIntelligencData(data: requestMap)
    }

    // Wrapper type to make the payload Sendable for Task closure capture
    private struct IntelligencePayload: @unchecked Sendable {
        let data: [String: Any]
    }
    
    internal func postIntelligencData(data: [String: Any]) {
        // Cancel any in-flight request
        currentIntelligenceTask?.cancel()
        
        let payload = IntelligencePayload(data: data)
        
        // Start a new task with Sendable payload + Sendable self
        currentIntelligenceTask = Task { [weak self, payload] in
            await self?.sendIntelligenceDataWithRetry(data: payload.data)
        }
    }

    private func sendIntelligenceDataWithRetry(
        data: [String: Any],
        maxAttempts: Int = 5,
        initialDelayMs: UInt64 = 100
    ) async {
        var attempt = 1
        var delayMs = initialDelayMs

        while !Task.isCancelled && attempt <= maxAttempts {
            let response = await intelligenceDataUseCase.invoke(bodyParams: data)

            switch response {
            case .success(let resp):
                if let dfrID = resp?.dfrId {
                    Otpless.shared.drfID = dfrID
                    var eventJson: [String: String] = ["result": "success"]
                    eventJson["dfrId"] = dfrID
                    sendEvent(
                        event: EventConstants.UPDATE_REQUEST_INTELLIGENCE_FRAUD_SDK,
                        extras: eventJson
                    )
                }
                return

            case .error(let apiError):
                var eventJson: [String: String] = ["result": "failure"]
                eventJson["attemptCount"] = String(attempt)
                eventJson["message"] = apiError.localizedDescription
                sendEvent(
                    event: EventConstants.UPDATE_REQUEST_INTELLIGENCE_FRAUD_SDK,
                    extras: eventJson
                )
                // If we've exhausted attempts, stop
                if attempt == maxAttempts { return }

                do {
                    let nanos = delayMs * 1_000_000  // ms → ns
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    // Task was cancelled while sleeping
                    return
                }

                // Next attempt
                delayMs *= 2
                attempt += 1
            }
        }
    }
}

@objcMembers
public class IntelligenceFetchError: NSObject {

    /// Unique requestId returned by vendor SDK / server
    public let requestId: String

    /// Human-readable failure message
    public let message: String

    public init(requestId: String?, message: String) {
        if let requestId = requestId {
            self.requestId = requestId
        } else {
            self.requestId = Otpless.shared.tsid
        }
        self.message = message
        super.init()
    }

    override public var description: String {
        return "IntelligenceFetchError(requestId: \(requestId), message: \(message))"
    }
}
