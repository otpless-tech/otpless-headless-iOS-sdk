import Foundation

/// Calls `CTCellularPlanStatus`'s iOS 27 methods through the Objective-C runtime.
///
/// The package builds with SDKs that predate iOS 27 and supports iOS 13, so these methods cannot
/// be named in Swift. They are looked up by selector, which also makes "is it there" a check on
/// the device's capability rather than on its version number. Selectors and block signatures were
/// read from a real iOS 27.0.1 device (ENG-626).
internal struct LivePlanStatusProvider: PlanStatusProvider {

    private static let className = "CTCellularPlanStatus"
    private static let authorizationStatusSelector = "getAuthorizationStatusForPhoneNumber:completion:"
    private static let requestAuthorizationSelector = "requestAuthorizationForPhoneNumber:completion:"
    private static let hintSelector = "getStatusHintForPhoneNumber:completion:"

    /// Reads answer from local state in well under a second (measured: 0.00 to 0.02 s).
    static let readTimeout: TimeInterval = 10
    /// The request waits for a person to answer Apple's dialog, so it is given long.
    static let requestTimeout: TimeInterval = 120

    var isSupported: Bool {
        guard let target = Self.target else { return false }
        return [Self.authorizationStatusSelector, Self.requestAuthorizationSelector, Self.hintSelector]
            .allSatisfy { target.responds(to: NSSelectorFromString($0)) }
    }

    func authorizationStatus(for phoneNumber: String) async throws -> PlanAuthorization {
        try await call(Self.authorizationStatusSelector, phoneNumber, timeout: Self.readTimeout) { finish in
            let block: @convention(block) (Int, AnyObject?) -> Void = { raw, error in
                finish(error == nil ? .success(PlanAuthorization(rawValue: raw)) : .failure(PlanStatusError.system))
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
    }

    func requestAuthorization(for phoneNumber: String) async throws -> PlanAuthorization {
        try await call(Self.requestAuthorizationSelector, phoneNumber, timeout: Self.requestTimeout) { finish in
            let block: @convention(block) (Int, AnyObject?) -> Void = { raw, error in
                finish(error == nil ? .success(PlanAuthorization(rawValue: raw)) : .failure(PlanStatusError.system))
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
    }

    func hint(for phoneNumber: String) async throws -> PlanHint {
        try await call(Self.hintSelector, phoneNumber, timeout: Self.readTimeout) { finish in
            let block: @convention(block) (Int, Int, AnyObject?) -> Void = { availability, confidence, error in
                finish(error == nil
                    ? .success(PlanHint(availabilityRaw: availability, confidenceRaw: confidence))
                    : .failure(PlanStatusError.system))
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
    }

    // MARK: - Runtime call

    private static var target: AnyObject? { NSClassFromString(className) as AnyObject? }

    /// Delivers exactly one result: Apple's callback, or a timeout if it never comes.
    private func call<T: Sendable>(
        _ selectorName: String,
        _ phoneNumber: String,
        timeout: TimeInterval,
        makeBlock: (@escaping @Sendable (Result<T, Error>) -> Void) -> AnyObject
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = OneShot()
            let finish: @Sendable (Result<T, Error>) -> Void = { result in
                guard once.claim() else { return }
                continuation.resume(with: result)
            }

            let selector = NSSelectorFromString(selectorName)
            guard let target = Self.target, target.responds(to: selector) else {
                return finish(.failure(PlanStatusError.unavailable))
            }
            let block = makeBlock(finish)
            _ = target.perform(selector, with: phoneNumber, with: block)
            // `block` is copied by Apple if it needs it later; no extra retain is held here.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(PlanStatusError.timeout))
            }
        }
    }
}

/// Lets exactly one of several racing callers through.
internal final class OneShot: @unchecked Sendable {
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
