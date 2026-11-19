//
//  File.swift
//  otpless-iOS-headless-sdk
//
//  Created by Sparsh on 16/01/25.
//

import Foundation

struct IntentResponse: Codable {
    let quantumLeap: QuantumLeap
    let oneTap: OneTap?
}

struct QuantumLeap: Codable {
    let asId: String
    let channel: String
    let channelAuthToken: String
    let channels: [String]
    let intent: String?
    let pollingRequired: Bool
    let state: String
    let status: String
    let timerSettings: TimerSettings
    let uid: String?
    let communicationMode: String?
    /// Present when the backend routed this request to outbound SMS SIM binding (`channel` is
    /// `SIM_BINDING`): the token, the number to send to, the message and the rules.
    let simBinding: [String: JSONValue]?
}

extension QuantumLeap {
    /// The parts the SIM binding flow reads, as plain JSON.
    func simBindingDictionary() -> [String: Any] {
        var dictionary: [String: Any] = ["channel": channel, "channelAuthToken": channelAuthToken]
        var timer: [String: Any] = [:]
        if let timeout = timerSettings.timeout { timer["timeout"] = timeout }
        dictionary["timerSettings"] = timer
        if let simBinding { dictionary["simBinding"] = simBinding.mapValues(\.any) }
        return dictionary
    }
}

/// Any JSON value, for a part of a response whose shape the SDK reads by hand.
enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Plain Foundation values. Whole numbers come back as `Int`, so rule values such as `seconds: 120`
    /// read as integers.
    var any: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.rounded() == value && abs(value) < 1e15 ? Int(value) : value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(\.any)
        case .array(let value): return value.map(\.any)
        case .null: return NSNull()
        }
    }
}

struct TimerSettings: Codable {
    let interval: Int64?
    let timeout: Int64?
}
