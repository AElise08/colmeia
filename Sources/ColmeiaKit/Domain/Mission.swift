import Foundation

// §5.2 / §9.1
public enum MissionState: String, Codable, CaseIterable, Sendable {
    case draft
    case active
    case blocked
    case inReview = "in_review"
    case completed
    case archived
}

public struct Mission: Codable, Equatable, Sendable {
    public var id: ULID
    public var roomID: ULID
    public var title: String
    public var context: String?
    public var definitionOfDone: String
    public var ownerID: String
    public var state: MissionState
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, context, state
        case roomID = "room_id"
        case definitionOfDone = "definition_of_done"
        case ownerID = "owner_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
    }

    public init(
        id: ULID,
        roomID: ULID,
        title: String,
        context: String? = nil,
        definitionOfDone: String,
        ownerID: String,
        state: MissionState = .draft,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.title = title
        self.context = context
        self.definitionOfDone = definitionOfDone
        self.ownerID = ownerID
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ULID.self, forKey: .id)
        roomID = try c.decode(ULID.self, forKey: .roomID)
        title = try c.decode(String.self, forKey: .title)
        context = try c.decodeIfPresent(String.self, forKey: .context)
        definitionOfDone = try c.decode(String.self, forKey: .definitionOfDone)
        ownerID = try c.decode(String.self, forKey: .ownerID)
        state = try c.decodeIfPresent(MissionState.self, forKey: .state) ?? .draft
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    // §9.1
    public static func canTransition(from: MissionState, to: MissionState) -> Bool {
        if from == to { return true }
        switch (from, to) {
        case (.draft, .active), (.draft, .archived):
            return true
        case (.active, .blocked), (.active, .inReview), (.active, .archived):
            return true
        case (.blocked, .active), (.blocked, .archived):
            return true
        case (.inReview, .completed), (.inReview, .active), (.inReview, .archived):
            return true
        case (.completed, .active), (.completed, .archived):
            return true
        case (.archived, .active):
            return true
        default:
            return false
        }
    }

    public static func validateTransition(from: MissionState, to: MissionState) throws {
        guard canTransition(from: from, to: to) else {
            throw MissionValidationError.invalidTransition(from: from, to: to)
        }
    }

    public func validateForActivation(hasWorkstream: Bool) throws {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw MissionValidationError.titleRequired }
        let d = definitionOfDone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { throw MissionValidationError.definitionOfDoneRequired }
        guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MissionValidationError.ownerRequired
        }
        guard hasWorkstream else { throw MissionValidationError.activateRequiresWorkstream }
    }
}

public enum MissionValidationError: Error, Equatable, Sendable, LocalizedError {
    case titleRequired
    case definitionOfDoneRequired
    case ownerRequired
    case invalidTransition(from: MissionState, to: MissionState)
    case activateRequiresWorkstream
    case completeRequiresAcceptedDeliveries
    case reopenRequiresReason

    public var errorDescription: String? {
        switch self {
        case .titleRequired: return "título da missão é obrigatório"
        case .definitionOfDoneRequired: return "definição de pronto da missão é obrigatória"
        case .ownerRequired: return "owner da missão é obrigatório"
        case .invalidTransition(let from, let to):
            return "transição de missão inválida: \(from.rawValue) → \(to.rawValue)"
        case .activateRequiresWorkstream: return "missão active exige ao menos uma frente"
        case .completeRequiresAcceptedDeliveries: return "missão completed exige entregas obrigatórias aceitas"
        case .reopenRequiresReason: return "reabertura de missão exige motivo"
        }
    }
}
