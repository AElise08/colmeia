import Foundation

public enum DelegationEstado: String, Codable, CaseIterable, Sendable {
    case queued, running, waitingApproval, completed, failed, canceled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .canceled
    }
}

/// Relação operacional persistente entre principal e subagente. A conexão do
/// canvas continua sendo apenas uma projeção visual desta relação.
public struct Delegation: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var workspaceID: ULID
    public var principalNodeID: ULID
    public var subagentNodeID: ULID
    public var task: String
    public var principalSessionID: ULID?
    public var subagentSessionID: ULID?
    public var estado: DelegationEstado
    public var result: String?
    public var deliveryID: ULID?
    public var pendingApprovalID: ULID?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(id: ULID = ULID.generate(), workspaceID: ULID, principalNodeID: ULID,
                subagentNodeID: ULID, task: String,
                principalSessionID: ULID? = nil, subagentSessionID: ULID? = nil,
                estado: DelegationEstado = .queued, result: String? = nil,
                deliveryID: ULID? = nil, pendingApprovalID: ULID? = nil,
                startedAt: Date? = nil, completedAt: Date? = nil) {
        self.id = id; self.workspaceID = workspaceID
        self.principalNodeID = principalNodeID; self.subagentNodeID = subagentNodeID
        self.task = task; self.principalSessionID = principalSessionID
        self.subagentSessionID = subagentSessionID; self.estado = estado
        self.result = result; self.deliveryID = deliveryID
        self.pendingApprovalID = pendingApprovalID; self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
