import Foundation

/// Payload imutável que atravessa a fronteira do supervisor para a sala.
public typealias AgentPayload = JSONValue

public struct AgentStateTransition: Codable, Equatable, Sendable {
    public let agentId: ULID
    public let from: CAPState
    public let to: CAPState
    public let timestamp: HLC
    public let payload: AgentPayload?

    public init(
        agentId: ULID,
        from: CAPState,
        to: CAPState,
        timestamp: HLC,
        payload: AgentPayload? = nil
    ) throws {
        try CAPState.validateTransition(from: from, to: to)
        self.agentId = agentId
        self.from = from
        self.to = to
        self.timestamp = timestamp
        self.payload = payload
    }
}
