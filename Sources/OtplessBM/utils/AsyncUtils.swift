//
//  AsyncUtils.swift
//  OtplessBM
//

import Foundation

/// Thrown by `AsyncUtils.withTimeout` when the timer fires first.
internal struct TimeoutError: Error {}

/// Lets exactly one of several racing callbacks resume a continuation.
internal final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

final internal class AsyncUtils {
    /// Races `operation` against a timer and throws `TimeoutError` if the timer wins. Unlike a
    /// task group this returns as soon as the timer fires even if `operation` never finishes,
    /// so it also bounds calls that cannot be cancelled.
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            Task {
                do {
                    let value = try await operation()
                    if once.claim() { continuation.resume(returning: value) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                if once.claim() { continuation.resume(throwing: TimeoutError()) }
            }
        }
    }
}
