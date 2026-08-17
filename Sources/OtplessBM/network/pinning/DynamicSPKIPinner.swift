//
//  DynamicSPKIPinner.swift
//  OtplessBM
//

import Foundation
import Security

/// Holds a live, swappable pin set — the iOS mirror of Android's `DynamicCertificatePinner`.
/// `PinningURLSessionDelegate` reads whichever snapshot is current at the moment a TLS challenge
/// arrives, so `OtplessSslPinManager` can apply a refreshed envelope without rebuilding the
/// shared `URLSession`. Comparison itself is delegated to the pure `SPKIPinner`.
internal final class DynamicSPKIPinner: @unchecked Sendable {

    private let lock = NSLock()
    private var pins: [String: [String]] = [:]

    func setPins(_ hostToPins: [String: [String]]) {
        lock.lock()
        pins = hostToPins
        lock.unlock()
    }

    func currentPins() -> [String: [String]] {
        lock.lock()
        defer { lock.unlock() }
        return pins
    }

    /// True if `trust` satisfies the current pin set for `host`. Hosts with no configured pins
    /// pass through untouched (see `SPKIPinner.evaluate`).
    func check(trust: SecTrust, host: String) -> Bool {
        return SPKIPinner.evaluate(trust: trust, host: host, pins: currentPins())
    }
}
