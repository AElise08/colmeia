import Foundation

public enum SemanticEventKind: String, Codable, CaseIterable, Sendable {
    case userMessage, assistantMessage, toolStarted, toolFinished
    case approvalRequested, delegationStarted, delegationCompleted, error
}

public struct SemanticEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var workspaceID: ULID
    public var sessionID: ULID?
    public var nodeID: ULID?
    public var kind: SemanticEventKind
    public var text: String?
    public var metadata: [String: String]
    public var createdAt: Date

    public init(id: ULID = ULID.generate(), workspaceID: ULID, sessionID: ULID? = nil,
                nodeID: ULID? = nil, kind: SemanticEventKind, text: String? = nil,
                metadata: [String: String] = [:], createdAt: Date = Date()) {
        self.id = id; self.workspaceID = workspaceID; self.sessionID = sessionID
        self.nodeID = nodeID; self.kind = kind; self.text = text
        self.metadata = metadata; self.createdAt = createdAt
    }
}
