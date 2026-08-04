import Foundation

/// Normative CAP lifecycle states.
public enum CAPState: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case idle
    case briefing
    case working
    case blocked
    case delivering
    case failed
    case shutdown

    /// The allowed directed edges of the CAP state machine.
    public var allowedNextStates: Set<CAPState> {
        switch self {
        case .idle: return [.briefing, .shutdown]
        case .briefing: return [.working, .failed, .shutdown]
        case .working: return [.blocked, .delivering, .failed, .idle]
        case .blocked: return [.working, .failed, .shutdown]
        case .delivering: return [.working, .idle, .failed]
        case .failed: return [.idle, .shutdown]
        case .shutdown: return []
        }
    }

    public func canTransition(to state: CAPState) -> Bool {
        allowedNextStates.contains(state)
    }

    public static func validateTransition(from: CAPState, to: CAPState) throws {
        guard from.canTransition(to: to) else {
            throw CAPStateTransitionError.invalidTransition(from: from, to: to)
        }
    }
}

public enum CAPStateTransitionError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidTransition(from: CAPState, to: CAPState)

    public var description: String {
        switch self {
        case .invalidTransition(let from, let to):
            return "invalid CAP state transition: \(from.rawValue) -> \(to.rawValue)"
        }
    }
}

/// An immutable, durable record of one accepted state transition.
public struct CAPStateTransitionEvent: Codable, Sendable, Equatable, Identifiable {
    public let event_id: ULID
    public let from: CAPState
    public let to: CAPState
    public let timestamp: HLC
    public let reason: String?

    public init(
        from: CAPState,
        to: CAPState,
        timestamp: HLC,
        reason: String? = nil,
        event_id: ULID = ULID.generate()
    ) throws {
        try CAPState.validateTransition(from: from, to: to)
        self.event_id = event_id
        self.from = from
        self.to = to
        self.timestamp = timestamp
        self.reason = reason
    }

    public var id: ULID { event_id }
    public var eventID: ULID { event_id }
}

/// A lock-protected state holder useful to producers of transition events.
public final class CAPStateMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var current: CAPState

    public init(initial: CAPState = .idle) {
        self.current = initial
    }

    public var state: CAPState {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    @discardableResult
    public func transition(
        to next: CAPState,
        timestamp: HLC,
        reason: String? = nil,
        event_id: ULID = ULID.generate()
    ) throws -> CAPStateTransitionEvent {
        lock.lock()
        defer { lock.unlock() }
        let event = try CAPStateTransitionEvent(
            from: current, to: next, timestamp: timestamp, reason: reason, event_id: event_id)
        current = next
        return event
    }
}

public typealias StateTransitionEvent = CAPStateTransitionEvent
