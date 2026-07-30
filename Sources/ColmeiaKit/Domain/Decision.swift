import Foundation

// §5.6 / §9.3
public enum DecisionState: String, Codable, CaseIterable, Sendable {
    case open
    case decided
    case superseded
    case canceled
}

public struct DecisionOption: Codable, Equatable, Sendable {
    public var id: ULID
    public var label: String
    public var consequence: String?

    public init(id: ULID, label: String, consequence: String? = nil) {
        self.id = id
        self.label = label
        self.consequence = consequence
    }
}

public struct Decision: Codable, Equatable, Sendable {
    public var id: ULID
    public var missionID: ULID
    public var workstreamID: ULID?
    public var question: String
    public var options: [DecisionOption]
    public var requestedBy: Author
    public var deciderID: String?
    public var state: DecisionState
    public var decision: String?
    public var rationale: String?
    public var dueAt: Date?
    public var decidedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, question, options, decision, rationale, state
        case missionID = "mission_id"
        case workstreamID = "workstream_id"
        case requestedBy = "requested_by"
        case deciderID = "decider_id"
        case dueAt = "due_at"
        case decidedAt = "decided_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: ULID,
        missionID: ULID,
        workstreamID: ULID? = nil,
        question: String,
        options: [DecisionOption] = [],
        requestedBy: Author,
        deciderID: String? = nil,
        state: DecisionState = .open,
        decision: String? = nil,
        rationale: String? = nil,
        dueAt: Date? = nil,
        decidedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.missionID = missionID
        self.workstreamID = workstreamID
        self.question = question
        self.options = options
        self.requestedBy = requestedBy
        self.deciderID = deciderID
        self.state = state
        self.decision = decision
        self.rationale = rationale
        self.dueAt = dueAt
        self.decidedAt = decidedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ULID.self, forKey: .id)
        missionID = try c.decode(ULID.self, forKey: .missionID)
        workstreamID = try c.decodeIfPresent(ULID.self, forKey: .workstreamID)
        question = try c.decode(String.self, forKey: .question)
        options = try c.decodeIfPresent([DecisionOption].self, forKey: .options) ?? []
        requestedBy = try c.decode(Author.self, forKey: .requestedBy)
        deciderID = try c.decodeIfPresent(String.self, forKey: .deciderID)
        state = try c.decodeIfPresent(DecisionState.self, forKey: .state) ?? .open
        decision = try c.decodeIfPresent(String.self, forKey: .decision)
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale)
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    // §9.3
    public static func canTransition(from: DecisionState, to: DecisionState) -> Bool {
        if from == to { return true }
        switch (from, to) {
        case (.open, .decided), (.open, .superseded), (.open, .canceled):
            return true
        case (.decided, .superseded), (.decided, .canceled):
            return true
        default:
            return false
        }
    }

    public static func validateTransition(from: DecisionState, to: DecisionState) throws {
        guard canTransition(from: from, to: to) else {
            throw DecisionValidationError.invalidTransition(from: from, to: to)
        }
    }

    public mutating func applyDecision(
        decisionText: String,
        rationale: String?,
        deciderID: String,
        at: Date = Date()
    ) throws {
        try Self.validateTransition(from: state, to: .decided)
        let text = decisionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DecisionValidationError.decideRequiresDecisionText }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecisionValidationError.questionRequired
        }
        self.decision = text
        self.rationale = rationale
        self.deciderID = deciderID
        self.decidedAt = at
        self.state = .decided
        self.updatedAt = at
    }

    public mutating func supersede(at: Date = Date()) throws {
        try Self.validateTransition(from: state, to: .superseded)
        state = .superseded
        updatedAt = at
    }

    public mutating func cancel(at: Date = Date()) throws {
        try Self.validateTransition(from: state, to: .canceled)
        state = .canceled
        updatedAt = at
    }
}

public enum DecisionValidationError: Error, Equatable, Sendable, LocalizedError {
    case questionRequired
    case invalidTransition(from: DecisionState, to: DecisionState)
    case decideRequiresDecisionText
    case decidedImmutableWithoutSupersede

    public var errorDescription: String? {
        switch self {
        case .questionRequired: return "pergunta da decisão é obrigatória"
        case .invalidTransition(let from, let to):
            return "transição de decisão inválida: \(from.rawValue) → \(to.rawValue)"
        case .decideRequiresDecisionText: return "decisão exige texto de resultado"
        case .decidedImmutableWithoutSupersede:
            return "decision/rationale não mudam após decided sem supersede"
        }
    }
}
