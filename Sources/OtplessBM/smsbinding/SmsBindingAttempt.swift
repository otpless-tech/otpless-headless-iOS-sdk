import Foundation

/// Attempt states, exactly as in PRD section 11.
internal enum SmsBindingState: String, Equatable, Sendable {
    case issued = "ISSUED"
    case sent = "SENT"
    case received = "RECEIVED"
    case verified = "VERIFIED"
    case rejected = "REJECTED"
    case expired = "EXPIRED"
    case aborted = "ABORTED"

    var isFinal: Bool {
        switch self {
        case .verified, .rejected, .expired, .aborted: return true
        case .issued, .sent, .received: return false
        }
    }

    /// Server-reported states can skip ahead of what the device saw (the VMN often hears the
    /// SMS before the device reports it), so the SDK only refuses to move out of a final state
    /// or backwards, never to skip forward.
    func accepts(_ next: SmsBindingState) -> Bool {
        if self == next { return true }
        if isFinal { return false }
        return rank(next) > rank(self)
    }

    private func rank(_ state: SmsBindingState) -> Int {
        switch state {
        case .issued: return 0
        case .sent: return 1
        case .received: return 2
        case .verified, .rejected, .expired, .aborted: return 3
        }
    }
}

/// One binding attempt as the SDK tracks it. A value type: every change returns a new copy,
/// and an illegal change leaves the attempt untouched.
internal struct SmsBindingAttempt: Equatable, Sendable {
    let attemptId: String
    let vmn: String
    let smsBody: String
    let ttlSeconds: Int
    private(set) var state: SmsBindingState = .issued
    private(set) var failure: SmsBindingFailure?

    init(attemptId: String, vmn: String, smsBody: String, ttlSeconds: Int) {
        self.attemptId = attemptId
        self.vmn = vmn
        self.smsBody = smsBody
        self.ttlSeconds = ttlSeconds
    }

    /// Applies a state reported by the device or the backend. Returns false and changes nothing
    /// when the move is not allowed (for example anything after a final state).
    @discardableResult
    mutating func advance(to next: SmsBindingState, failure: SmsBindingFailure? = nil) -> Bool {
        guard state.accepts(next) else { return false }
        state = next
        if next == .rejected || next == .expired || next == .aborted {
            self.failure = failure ?? self.failure
        }
        return true
    }
}
