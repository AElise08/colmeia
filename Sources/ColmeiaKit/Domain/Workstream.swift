import Foundation

// §5.3 / §9.2
public enum WorkstreamState: String, Codable, CaseIterable, Sendable {
    case notStarted = "not_started"
    case active
    case blocked
    case waitingForReview = "waiting_for_review"
    case completed
    case canceled
}

public enum WorkstreamBlockerKind: String, Codable, CaseIterable, Sendable {
    case workstream
    case decision
}

public struct WorkstreamBlocker: Codable, Equatable, Sendable {
    public var kind: WorkstreamBlockerKind
    public var id: ULID

    public init(kind: WorkstreamBlockerKind, id: ULID) {
        self.kind = kind
        self.id = id
    }
}

public struct WorkstreamAssignee: Codable, Equatable, Sendable {
    public var personID: String?
    public var agentID: ULID?

    enum CodingKeys: String, CodingKey {
        case personID = "person_id"
        case agentID = "agent_id"
    }

    public init(personID: String? = nil, agentID: ULID? = nil) {
        self.personID = personID
        self.agentID = agentID
    }

    public var isAssigned: Bool { personID != nil || agentID != nil }

    public func validate() throws {
        guard isAssigned else { throw WorkstreamValidationError.assigneeRequiresAtLeastOne }
    }
}

public struct Workstream: Codable, Equatable, Sendable {
    public var id: ULID
    public var missionID: ULID
    public var title: String
    public var objective: String
    public var definitionOfDone: String
    public var assignee: WorkstreamAssignee?
    public var state: WorkstreamState
    public var dependsOn: [ULID]
    public var blockedBy: [WorkstreamBlocker]
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, objective, assignee, state
        case missionID = "mission_id"
        case definitionOfDone = "definition_of_done"
        case dependsOn = "depends_on"
        case blockedBy = "blocked_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
    }

    public init(
        id: ULID,
        missionID: ULID,
        title: String,
        objective: String,
        definitionOfDone: String,
        assignee: WorkstreamAssignee? = nil,
        state: WorkstreamState = .notStarted,
        dependsOn: [ULID] = [],
        blockedBy: [WorkstreamBlocker] = [],
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.missionID = missionID
        self.title = title
        self.objective = objective
        self.definitionOfDone = definitionOfDone
        self.assignee = assignee
        self.state = state
        self.dependsOn = dependsOn
        self.blockedBy = blockedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ULID.self, forKey: .id)
        missionID = try c.decode(ULID.self, forKey: .missionID)
        title = try c.decode(String.self, forKey: .title)
        objective = try c.decodeIfPresent(String.self, forKey: .objective) ?? ""
        definitionOfDone = try c.decodeIfPresent(String.self, forKey: .definitionOfDone) ?? ""
        assignee = try c.decodeIfPresent(WorkstreamAssignee.self, forKey: .assignee)
        state = try c.decodeIfPresent(WorkstreamState.self, forKey: .state) ?? .notStarted
        dependsOn = try c.decodeIfPresent([ULID].self, forKey: .dependsOn) ?? []
        blockedBy = try c.decodeIfPresent([WorkstreamBlocker].self, forKey: .blockedBy) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    // §9.2
    public static func canTransition(from: WorkstreamState, to: WorkstreamState) -> Bool {
        if from == to { return true }
        if from == .completed { return false }
        if to == .canceled, from != .completed { return true }
        switch (from, to) {
        case (.notStarted, .active):
            return true
        case (.active, .blocked), (.active, .waitingForReview):
            return true
        case (.blocked, .active):
            return true
        case (.waitingForReview, .active), (.waitingForReview, .completed):
            return true
        default:
            return false
        }
    }

    public static func validateTransition(from: WorkstreamState, to: WorkstreamState) throws {
        guard canTransition(from: from, to: to) else {
            throw WorkstreamValidationError.invalidTransition(from: from, to: to)
        }
    }

    public func validateBasics() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkstreamValidationError.titleRequired
        }
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkstreamValidationError.objectiveRequired
        }
        guard !definitionOfDone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkstreamValidationError.definitionOfDoneRequired
        }
        if let assignee { try assignee.validate() }
        if dependsOn.contains(id) { throw WorkstreamValidationError.selfDependence }
    }
}

public enum WorkstreamValidationError: Error, Equatable, Sendable, LocalizedError {
    case titleRequired
    case objectiveRequired
    case definitionOfDoneRequired
    case assigneeRequiresAtLeastOne
    case invalidTransition(from: WorkstreamState, to: WorkstreamState)
    case selfDependence
    case cycleInDependsOn
    case reopenRequiresAudit

    public var errorDescription: String? {
        switch self {
        case .titleRequired: return "título da frente é obrigatório"
        case .objectiveRequired: return "objetivo da frente é obrigatório"
        case .definitionOfDoneRequired: return "definição de pronto da frente é obrigatória"
        case .assigneeRequiresAtLeastOne: return "assignee exige pessoa, agente ou ambos"
        case .invalidTransition(let from, let to):
            return "transição de frente inválida: \(from.rawValue) → \(to.rawValue)"
        case .selfDependence: return "frente não pode depender de si mesma"
        case .cycleInDependsOn: return "depends_on forma ciclo não declarado"
        case .reopenRequiresAudit: return "completed não volta sem reabertura auditada"
        }
    }
}
