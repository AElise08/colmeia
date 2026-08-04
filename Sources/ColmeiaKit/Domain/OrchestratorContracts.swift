import Foundation

/// Contratos estruturados da skill de orquestração.
///
/// Estes tipos são deliberadamente dados puros: a UI, o Engine e uma skill
/// externa podem serializar o mesmo plano sem compartilhar estado mutável.
public enum OrchestratorPhase: String, Codable, CaseIterable, Sendable {
    case triage
    case plan
    case delegate
    case monitor
    case unblock
    case verify
    case deliver
    case retro

    public static func canTransition(from: Self, to: Self) -> Bool {
        if from == to { return true }
        switch (from, to) {
        case (.triage, .plan),
             (.plan, .delegate),
             (.delegate, .monitor),
             (.monitor, .unblock),
             (.monitor, .verify),
             (.unblock, .monitor),
             (.verify, .deliver),
             (.deliver, .retro),
             (.retro, .triage):
            return true
        default:
            return false
        }
    }
}

public struct OrchestratorBudget: Codable, Equatable, Sendable {
    public var maxRuntimeMinutes: Int?
    public var maxSteps: Int?

    public init(maxRuntimeMinutes: Int? = nil, maxSteps: Int? = nil) {
        self.maxRuntimeMinutes = maxRuntimeMinutes
        self.maxSteps = maxSteps
    }
}

public struct OrchestratorFront: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var title: String
    public var objective: String
    public var definitionOfDone: [String]
    public var dependencies: [ULID]
    public var constraints: [String]

    public init(
        id: ULID = ULID.generate(),
        title: String,
        objective: String,
        definitionOfDone: [String],
        dependencies: [ULID] = [],
        constraints: [String] = []
    ) {
        self.id = id
        self.title = title
        self.objective = objective
        self.definitionOfDone = definitionOfDone
        self.dependencies = dependencies
        self.constraints = constraints
    }

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrchestratorValidationError.frontTitleRequired
        }
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrchestratorValidationError.frontObjectiveRequired
        }
        guard !definitionOfDone.isEmpty,
              definitionOfDone.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw OrchestratorValidationError.definitionOfDoneRequired
        }
        guard !dependencies.contains(id) else {
            throw OrchestratorValidationError.selfDependency
        }
    }
}

public struct OrchestratorPlan: Codable, Equatable, Sendable {
    public var objective: String
    public var assumptions: [String]
    public var risks: [String]
    public var fronts: [OrchestratorFront]
    public var dependencies: [String]
    public var checkpoints: [String]
    public var nextStep: String

    public init(
        objective: String,
        assumptions: [String] = [],
        risks: [String] = [],
        fronts: [OrchestratorFront] = [],
        dependencies: [String] = [],
        checkpoints: [String] = [],
        nextStep: String
    ) {
        self.objective = objective
        self.assumptions = assumptions
        self.risks = risks
        self.fronts = fronts
        self.dependencies = dependencies
        self.checkpoints = checkpoints
        self.nextStep = nextStep
    }

    public func validate() throws {
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrchestratorValidationError.objectiveRequired
        }
        guard !nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrchestratorValidationError.nextStepRequired
        }
        for front in fronts { try front.validate() }
        try Self.validateNoCycles(in: fronts)
    }

    private static func validateNoCycles(in fronts: [OrchestratorFront]) throws {
        let known = Set(fronts.map(\.id))
        var edges = Dictionary(uniqueKeysWithValues: fronts.map { ($0.id, $0.dependencies.filter(known.contains)) })
        var visiting = Set<ULID>()
        var visited = Set<ULID>()

        func visit(_ id: ULID) throws {
            if visiting.contains(id) { throw OrchestratorValidationError.dependencyCycle }
            if visited.contains(id) { return }
            visiting.insert(id)
            for dependency in edges.removeValue(forKey: id) ?? [] { try visit(dependency) }
            visiting.remove(id)
            visited.insert(id)
        }

        for id in known { try visit(id) }
    }
}

public struct OrchestratorDelegation: Codable, Equatable, Sendable {
    public var task: String
    public var context: [String]
    public var constraints: [String]
    public var definitionOfDone: [String]
    public var forbidden: [String]
    public var requiresApproval: Bool
    public var budget: OrchestratorBudget

    public init(
        task: String,
        context: [String] = [],
        constraints: [String] = [],
        definitionOfDone: [String],
        forbidden: [String] = [],
        requiresApproval: Bool = false,
        budget: OrchestratorBudget = .init()
    ) {
        self.task = task
        self.context = context
        self.constraints = constraints
        self.definitionOfDone = definitionOfDone
        self.forbidden = forbidden
        self.requiresApproval = requiresApproval
        self.budget = budget
    }

    public func validate() throws {
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrchestratorValidationError.taskRequired
        }
        guard !definitionOfDone.isEmpty else {
            throw OrchestratorValidationError.definitionOfDoneRequired
        }
        if let maxRuntimeMinutes = budget.maxRuntimeMinutes, maxRuntimeMinutes <= 0 {
            throw OrchestratorValidationError.invalidBudget
        }
        if let maxSteps = budget.maxSteps, maxSteps <= 0 {
            throw OrchestratorValidationError.invalidBudget
        }
    }
}

public struct OrchestratorDecisionRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var title: String
    public var question: String
    public var options: [String]
    public var recommendation: String?
    public var risk: String
    public var context: [String]
    public var consequences: [String: String]

    public init(
        id: ULID = ULID.generate(),
        title: String,
        question: String,
        options: [String],
        recommendation: String? = nil,
        risk: String,
        context: [String] = [],
        consequences: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.question = question
        self.options = options
        self.recommendation = recommendation
        self.risk = risk
        self.context = context
        self.consequences = consequences
    }

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrchestratorValidationError.decisionQuestionRequired
        }
        guard options.count >= 2,
              options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw OrchestratorValidationError.decisionNeedsOptions
        }
        if let recommendation, !options.contains(recommendation) {
            throw OrchestratorValidationError.invalidRecommendation
        }
    }
}

public struct OrchestratorBlockerReport: Codable, Equatable, Sendable {
    public var fact: String
    public var probableCause: String
    public var impact: String
    public var options: [String]
    public var recommendation: String?
    public var question: String

    public init(
        fact: String,
        probableCause: String,
        impact: String,
        options: [String] = [],
        recommendation: String? = nil,
        question: String
    ) {
        self.fact = fact
        self.probableCause = probableCause
        self.impact = impact
        self.options = options
        self.recommendation = recommendation
        self.question = question
    }
}

public enum OrchestratorAuditKind: String, Codable, CaseIterable, Sendable {
    case planCreated = "plan_created"
    case delegationProposed = "delegation_proposed"
    case delegationAccepted = "delegation_accepted"
    case blockerDetected = "blocker_detected"
    case decisionRequested = "decision_requested"
    case decisionResolved = "decision_resolved"
    case deliveryProposed = "delivery_proposed"
    case retroSaved = "retro_saved"
}

public struct OrchestratorAuditEntry: Codable, Equatable, Sendable {
    public var id: ULID
    public var kind: OrchestratorAuditKind
    public var summary: String
    public var evidence: [String]
    public var createdAt: Date

    public init(
        id: ULID = ULID.generate(),
        kind: OrchestratorAuditKind,
        summary: String,
        evidence: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.evidence = evidence
        self.createdAt = createdAt
    }
}

public enum OrchestratorValidationError: Error, Equatable, Sendable, LocalizedError {
    case objectiveRequired
    case nextStepRequired
    case frontTitleRequired
    case frontObjectiveRequired
    case definitionOfDoneRequired
    case selfDependency
    case dependencyCycle
    case taskRequired
    case invalidBudget
    case decisionQuestionRequired
    case decisionNeedsOptions
    case invalidRecommendation

    public var errorDescription: String? {
        switch self {
        case .objectiveRequired: return "objetivo do plano é obrigatório"
        case .nextStepRequired: return "próximo passo do plano é obrigatório"
        case .frontTitleRequired: return "título da frente é obrigatório"
        case .frontObjectiveRequired: return "objetivo da frente é obrigatório"
        case .definitionOfDoneRequired: return "definição de pronto é obrigatória"
        case .selfDependency: return "frente não pode depender de si mesma"
        case .dependencyCycle: return "dependências das frentes formam um ciclo"
        case .taskRequired: return "tarefa de delegação é obrigatória"
        case .invalidBudget: return "budget de delegação deve ser positivo"
        case .decisionQuestionRequired: return "título e pergunta da decisão são obrigatórios"
        case .decisionNeedsOptions: return "decisão exige pelo menos duas opções"
        case .invalidRecommendation: return "recomendação deve ser uma das opções"
        }
    }
}
