import Foundation

// §5.2–5.8 / §13 — store local de Missão, Frente, Decisão e Relação tipada.
public final class MissionStore: @unchecked Sendable {
    public let roomID: ULID

    private let lock = NSLock()
    private var missions: [ULID: Mission] = [:]
    private var workstreams: [ULID: Workstream] = [:]
    private var decisions: [ULID: Decision] = [:]
    private var relations: [ULID: Relation] = [:]

    public init(roomID: ULID) {
        self.roomID = roomID
    }

    private init(state: PersistedState) {
        self.roomID = state.roomID
        self.missions = Dictionary(uniqueKeysWithValues: state.missions.map { ($0.id, $0) })
        self.workstreams = Dictionary(uniqueKeysWithValues: state.workstreams.map { ($0.id, $0) })
        self.decisions = Dictionary(uniqueKeysWithValues: state.decisions.map { ($0.id, $0) })
        self.relations = Dictionary(uniqueKeysWithValues: state.relations.map { ($0.id, $0) })
    }

    // MARK: - Persistência

    public func persist(to paths: ColmeiaPaths) throws {
        lock.lock()
        let state = PersistedState(
            roomID: roomID,
            missions: Array(missions.values),
            workstreams: Array(workstreams.values),
            decisions: Array(decisions.values),
            relations: Array(relations.values)
        )
        lock.unlock()
        try FileManager.default.createDirectory(at: paths.roomDir(roomID), withIntermediateDirectories: true)
        try AtomicJSON.write(state, to: paths.roomMissionsFile(roomID))
    }

    public static func load(from paths: ColmeiaPaths, roomID: ULID) throws -> MissionStore {
        let url = paths.roomMissionsFile(roomID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return MissionStore(roomID: roomID)
        }
        let state = try AtomicJSON.read(PersistedState.self, from: url)
        guard state.roomID == roomID else {
            throw MissionStoreError.roomMismatch
        }
        return MissionStore(state: state)
    }

    // MARK: - Missão §5.2 / §9.1

    public func listMissions(state: MissionState? = nil) -> [Mission] {
        lock.lock(); defer { lock.unlock() }
        return missions.values
            .filter { state == nil || $0.state == state }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func getMission(_ id: ULID) -> Mission? {
        lock.lock(); defer { lock.unlock() }
        return missions[id]
    }

    @discardableResult
    public func createMission(
        id: ULID = ULID.generate(),
        title: String,
        context: String? = nil,
        definitionOfDone: String,
        ownerID: String,
        at: Date = Date()
    ) throws -> Mission {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw MissionValidationError.titleRequired }
        let d = definitionOfDone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { throw MissionValidationError.definitionOfDoneRequired }
        guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MissionValidationError.ownerRequired
        }
        lock.lock(); defer { lock.unlock() }
        let mission = Mission(
            id: id, roomID: roomID, title: t, context: context,
            definitionOfDone: d, ownerID: ownerID, state: .draft,
            createdAt: at, updatedAt: at
        )
        missions[id] = mission
        return mission
    }

    @discardableResult
    public func updateMission(
        id: ULID,
        title: String? = nil,
        context: String? = nil,
        definitionOfDone: String? = nil,
        ownerID: String? = nil,
        at: Date = Date()
    ) throws -> Mission {
        lock.lock(); defer { lock.unlock() }
        guard var mission = missions[id] else { throw MissionStoreError.missionNotFound(id) }
        if mission.state == .archived {
            throw MissionStoreError.archivedReadOnly
        }
        if let title {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw MissionValidationError.titleRequired }
            mission.title = t
        }
        if let context { mission.context = context }
        if let definitionOfDone {
            let d = definitionOfDone.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !d.isEmpty else { throw MissionValidationError.definitionOfDoneRequired }
            mission.definitionOfDone = d
        }
        if let ownerID {
            guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MissionValidationError.ownerRequired
            }
            mission.ownerID = ownerID
        }
        mission.updatedAt = at
        missions[id] = mission
        return mission
    }

    @discardableResult
    public func transitionMission(
        id: ULID,
        to newState: MissionState,
        reason: String? = nil,
        at: Date = Date()
    ) throws -> Mission {
        lock.lock(); defer { lock.unlock() }
        guard var mission = missions[id] else { throw MissionStoreError.missionNotFound(id) }
        try Mission.validateTransition(from: mission.state, to: newState)
        if mission.state == .draft && newState == .active {
            let hasWS = workstreams.values.contains { $0.missionID == id }
            try mission.validateForActivation(hasWorkstream: hasWS)
        }
        if mission.state == .completed && newState == .active {
            let r = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !r.isEmpty else { throw MissionValidationError.reopenRequiresReason }
        }
        if newState == .completed {
            mission.completedAt = at
        }
        if newState == .active {
            mission.completedAt = nil
        }
        mission.state = newState
        mission.updatedAt = at
        missions[id] = mission
        return mission
    }

    // MARK: - Frente §5.3 / §9.2

    public func listWorkstreams(missionID: ULID? = nil, state: WorkstreamState? = nil) -> [Workstream] {
        lock.lock(); defer { lock.unlock() }
        return workstreams.values
            .filter { missionID == nil || $0.missionID == missionID }
            .filter { state == nil || $0.state == state }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func getWorkstream(_ id: ULID) -> Workstream? {
        lock.lock(); defer { lock.unlock() }
        return workstreams[id]
    }

    @discardableResult
    public func createWorkstream(
        id: ULID = ULID.generate(),
        missionID: ULID,
        title: String,
        objective: String,
        definitionOfDone: String,
        assignee: WorkstreamAssignee? = nil,
        dependsOn: [ULID] = [],
        at: Date = Date()
    ) throws -> Workstream {
        lock.lock(); defer { lock.unlock() }
        guard let mission = missions[missionID] else { throw MissionStoreError.missionNotFound(missionID) }
        if mission.state == .archived { throw MissionStoreError.archivedReadOnly }
        let ws = Workstream(
            id: id, missionID: missionID, title: title, objective: objective,
            definitionOfDone: definitionOfDone, assignee: assignee, state: .notStarted,
            dependsOn: dependsOn, createdAt: at, updatedAt: at
        )
        try ws.validateBasics()
        try validateDependsOn(ws, among: workstreams)
        workstreams[id] = ws
        return ws
    }

    @discardableResult
    public func updateWorkstream(
        id: ULID,
        title: String? = nil,
        objective: String? = nil,
        definitionOfDone: String? = nil,
        assignee: WorkstreamAssignee? = nil,
        clearAssignee: Bool = false,
        dependsOn: [ULID]? = nil,
        blockedBy: [WorkstreamBlocker]? = nil,
        at: Date = Date()
    ) throws -> Workstream {
        lock.lock(); defer { lock.unlock() }
        guard var ws = workstreams[id] else { throw MissionStoreError.workstreamNotFound(id) }
        if let title { ws.title = title }
        if let objective { ws.objective = objective }
        if let definitionOfDone { ws.definitionOfDone = definitionOfDone }
        if clearAssignee {
            ws.assignee = nil
        } else if let assignee {
            try assignee.validate()
            ws.assignee = assignee
        }
        if let dependsOn {
            ws.dependsOn = dependsOn
            try validateDependsOn(ws, among: workstreams)
        }
        if let blockedBy { ws.blockedBy = blockedBy }
        try ws.validateBasics()
        ws.updatedAt = at
        workstreams[id] = ws
        return ws
    }

    @discardableResult
    public func transitionWorkstream(
        id: ULID,
        to newState: WorkstreamState,
        at: Date = Date()
    ) throws -> Workstream {
        lock.lock(); defer { lock.unlock() }
        guard var ws = workstreams[id] else { throw MissionStoreError.workstreamNotFound(id) }
        try Workstream.validateTransition(from: ws.state, to: newState)
        if newState == .completed {
            ws.completedAt = at
        }
        ws.state = newState
        ws.updatedAt = at
        workstreams[id] = ws
        return ws
    }

    // MARK: - Decisão §5.6 / §9.3

    public func listDecisions(missionID: ULID? = nil, state: DecisionState? = nil) -> [Decision] {
        lock.lock(); defer { lock.unlock() }
        return decisions.values
            .filter { missionID == nil || $0.missionID == missionID }
            .filter { state == nil || $0.state == state }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func getDecision(_ id: ULID) -> Decision? {
        lock.lock(); defer { lock.unlock() }
        return decisions[id]
    }

    @discardableResult
    public func createDecision(
        id: ULID = ULID.generate(),
        missionID: ULID,
        workstreamID: ULID? = nil,
        question: String,
        options: [DecisionOption] = [],
        requestedBy: Author,
        dueAt: Date? = nil,
        at: Date = Date()
    ) throws -> Decision {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw DecisionValidationError.questionRequired }
        lock.lock(); defer { lock.unlock() }
        guard missions[missionID] != nil else { throw MissionStoreError.missionNotFound(missionID) }
        if let workstreamID {
            guard let ws = workstreams[workstreamID], ws.missionID == missionID else {
                throw MissionStoreError.workstreamNotFound(workstreamID)
            }
        }
        let decision = Decision(
            id: id, missionID: missionID, workstreamID: workstreamID,
            question: q, options: options, requestedBy: requestedBy,
            dueAt: dueAt, createdAt: at, updatedAt: at
        )
        decisions[id] = decision
        return decision
    }

    @discardableResult
    public func decide(
        id: ULID,
        decisionText: String,
        rationale: String?,
        deciderID: String,
        at: Date = Date()
    ) throws -> Decision {
        lock.lock(); defer { lock.unlock() }
        guard var decision = decisions[id] else { throw MissionStoreError.decisionNotFound(id) }
        try decision.applyDecision(
            decisionText: decisionText, rationale: rationale, deciderID: deciderID, at: at
        )
        decisions[id] = decision
        return decision
    }

    @discardableResult
    public func supersedeDecision(id: ULID, at: Date = Date()) throws -> Decision {
        lock.lock(); defer { lock.unlock() }
        guard var decision = decisions[id] else { throw MissionStoreError.decisionNotFound(id) }
        try decision.supersede(at: at)
        decisions[id] = decision
        return decision
    }

    @discardableResult
    public func cancelDecision(id: ULID, at: Date = Date()) throws -> Decision {
        lock.lock(); defer { lock.unlock() }
        guard var decision = decisions[id] else { throw MissionStoreError.decisionNotFound(id) }
        try decision.cancel(at: at)
        decisions[id] = decision
        return decision
    }

    // MARK: - Relação §5.8

    public func listRelations(kind: RelationKind? = nil) -> [Relation] {
        lock.lock(); defer { lock.unlock() }
        return relations.values
            .filter { kind == nil || $0.kind == kind }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func addRelation(
        id: ULID = ULID.generate(),
        fromID: ULID,
        toID: ULID,
        kind: RelationKind,
        author: Author,
        labelPosition: Ponto? = nil,
        at: Date = Date()
    ) throws -> Relation {
        guard fromID != toID else { throw RelationValidationError.selfLink }
        lock.lock(); defer { lock.unlock() }
        if kind == .dependsOn {
            var edges = relations.values
                .filter { $0.kind == .dependsOn }
                .map { (from: $0.fromID, to: $0.toID) }
            edges.append((from: fromID, to: toID))
            if RelationGraph.hasCycle(edges: edges) {
                throw RelationValidationError.cycleInDependsOn
            }
        }
        let relation = Relation(
            id: id, fromID: fromID, toID: toID, kind: kind,
            author: author, createdAt: at, labelPosition: labelPosition
        )
        relations[id] = relation
        return relation
    }

    @discardableResult
    public func removeRelation(id: ULID) throws -> Relation {
        lock.lock(); defer { lock.unlock() }
        guard let relation = relations.removeValue(forKey: id) else {
            throw MissionStoreError.relationNotFound(id)
        }
        return relation
    }

    // MARK: - Briefing §8.3

    public func buildWorkstreamBriefing(
        workstreamID: ULID,
        agentName: String,
        agentRole: String? = nil,
        capabilities: [String] = [],
        allowedArtifacts: [String] = []
    ) throws -> String {
        lock.lock()
        guard let ws = workstreams[workstreamID] else {
            lock.unlock()
            throw MissionStoreError.workstreamNotFound(workstreamID)
        }
        guard let mission = missions[ws.missionID] else {
            lock.unlock()
            throw MissionStoreError.missionNotFound(ws.missionID)
        }
        let openDecisions = decisions.values.filter {
            $0.state == .open && ($0.workstreamID == workstreamID || $0.missionID == mission.id)
        }
        let deps = ws.dependsOn.compactMap { workstreams[$0] }
        lock.unlock()

        // §8.3 — campo obrigatório ausente impede início
        let title = mission.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let dod = mission.definitionOfDone.trimmingCharacters(in: .whitespacesAndNewlines)
        let objective = ws.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let wsDod = ws.definitionOfDone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !dod.isEmpty, !objective.isEmpty, !wsDod.isEmpty,
              !agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MissionStoreError.briefingIncomplete
        }

        var lines: [String] = []
        lines.append("# Briefing de Frente")
        lines.append("")
        lines.append("## Missão")
        lines.append("- **Título:** \(title)")
        if let ctx = mission.context, !ctx.isEmpty {
            lines.append("- **Contexto:** \(ctx)")
        }
        lines.append("- **Definição de pronto:** \(dod)")
        lines.append("")
        lines.append("## Frente")
        lines.append("- **Título:** \(ws.title)")
        lines.append("- **Objetivo:** \(objective)")
        lines.append("- **Definição de pronto:** \(wsDod)")
        lines.append("- **Estado:** \(ws.state.rawValue)")
        if !deps.isEmpty {
            lines.append("- **Depende de:**")
            for d in deps {
                lines.append("  - \(d.title) (\(d.state.rawValue))")
            }
        }
        if !openDecisions.isEmpty {
            lines.append("")
            lines.append("## Decisões abertas")
            for d in openDecisions {
                lines.append("- \(d.question)")
            }
        }
        lines.append("")
        lines.append("## Agente")
        lines.append("- **Nome:** \(agentName)")
        if let agentRole, !agentRole.isEmpty {
            lines.append("- **Papel:** \(agentRole)")
        }
        if !capabilities.isEmpty {
            lines.append("- **Capacidades:** \(capabilities.joined(separator: ", "))")
        }
        if !allowedArtifacts.isEmpty {
            lines.append("- **Artefatos permitidos:** \(allowedArtifacts.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("## Instruções")
        lines.append("- Publique progresso com resumo vinculado a esta frente.")
        lines.append("- Peça decisão quando houver bloqueio de julgamento humano.")
        lines.append("- Proponha entrega com evidência verificável.")
        lines.append("- Escale bloqueio; não conclua a frente automaticamente.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func validateDependsOn(_ ws: Workstream, among all: [ULID: Workstream]) throws {
        if ws.dependsOn.contains(ws.id) { throw WorkstreamValidationError.selfDependence }
        for dep in ws.dependsOn where dep != ws.id {
            if all[dep] == nil {
                throw MissionStoreError.workstreamNotFound(dep)
            }
        }
        var edges: [(from: ULID, to: ULID)] = []
        for item in all.values where item.id != ws.id {
            for dep in item.dependsOn {
                edges.append((from: item.id, to: dep))
            }
        }
        for dep in ws.dependsOn {
            edges.append((from: ws.id, to: dep))
        }
        if RelationGraph.hasCycle(edges: edges) {
            throw WorkstreamValidationError.cycleInDependsOn
        }
    }

    private struct PersistedState: Codable {
        var roomID: ULID
        var missions: [Mission]
        var workstreams: [Workstream]
        var decisions: [Decision]
        var relations: [Relation]

        enum CodingKeys: String, CodingKey {
            case missions, workstreams, decisions, relations
            case roomID = "room_id"
        }
    }
}

public enum MissionStoreError: Error, Equatable, Sendable, LocalizedError {
    case roomMismatch
    case missionNotFound(ULID)
    case workstreamNotFound(ULID)
    case decisionNotFound(ULID)
    case relationNotFound(ULID)
    case archivedReadOnly
    case briefingIncomplete

    public var errorDescription: String? {
        switch self {
        case .roomMismatch: return "snapshot de missão não corresponde à sala"
        case .missionNotFound(let id): return "missão não encontrada: \(id.string)"
        case .workstreamNotFound(let id): return "frente não encontrada: \(id.string)"
        case .decisionNotFound(let id): return "decisão não encontrada: \(id.string)"
        case .relationNotFound(let id): return "relação não encontrada: \(id.string)"
        case .archivedReadOnly: return "sala/missão arquivada é somente leitura"
        case .briefingIncomplete: return "briefing incompleto: campo obrigatório ausente"
        }
    }
}
