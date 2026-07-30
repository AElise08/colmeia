import Foundation

// §5.8
public enum RelationKind: String, Codable, CaseIterable, Sendable {
    case dependsOn = "depends_on"
    case assignedTo = "assigned_to"
    case produces
    case requiresDecision = "requires_decision"
    case reviews
    case informs
}

public struct Relation: Codable, Equatable, Sendable {
    public var id: ULID
    public var fromID: ULID
    public var toID: ULID
    public var kind: RelationKind
    public var author: Author
    public var createdAt: Date
    public var labelPosition: Ponto?

    enum CodingKeys: String, CodingKey {
        case id, kind, author
        case fromID = "from_id"
        case toID = "to_id"
        case createdAt = "created_at"
        case labelPosition = "label_position"
    }

    public init(
        id: ULID,
        fromID: ULID,
        toID: ULID,
        kind: RelationKind,
        author: Author,
        createdAt: Date,
        labelPosition: Ponto? = nil
    ) {
        self.id = id
        self.fromID = fromID
        self.toID = toID
        self.kind = kind
        self.author = author
        self.createdAt = createdAt
        self.labelPosition = labelPosition
    }
}

public enum RelationValidationError: Error, Equatable, Sendable, LocalizedError {
    case selfLink
    case cycleInDependsOn
    case assignedToRequiresPersonOrAgent
    case producesRequiresDelivery

    public var errorDescription: String? {
        switch self {
        case .selfLink: return "relação não pode ligar objeto a si mesmo"
        case .cycleInDependsOn: return "depends_on forma ciclo não declarado"
        case .assignedToRequiresPersonOrAgent: return "assigned_to deve ligar frente a pessoa ou agente"
        case .producesRequiresDelivery: return "produces deve ligar frente a entrega"
        }
    }
}

/// Detecção de ciclo em grafo de depends_on (§5.8).
public enum RelationGraph {
    public static func hasCycle(edges: [(from: ULID, to: ULID)]) -> Bool {
        var adj: [ULID: [ULID]] = [:]
        for e in edges {
            adj[e.from, default: []].append(e.to)
        }
        var visiting = Set<ULID>()
        var visited = Set<ULID>()

        func dfs(_ node: ULID) -> Bool {
            if visiting.contains(node) { return true }
            if visited.contains(node) { return false }
            visiting.insert(node)
            for next in adj[node] ?? [] {
                if dfs(next) { return true }
            }
            visiting.remove(node)
            visited.insert(node)
            return false
        }

        for node in adj.keys {
            if dfs(node) { return true }
        }
        return false
    }
}
