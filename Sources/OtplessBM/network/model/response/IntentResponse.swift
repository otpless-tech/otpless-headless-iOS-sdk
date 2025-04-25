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
    let state: String?
    let status: String
    let timerSettings: TimerSettings
    let uid: String?
    let communicationMode: String?
    let otpLength: Int?
}

struct TimerSettings: Codable {
    let interval: Int64?
    let timeout: Int64?
}
