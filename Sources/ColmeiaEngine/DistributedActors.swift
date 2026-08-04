import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ColmeiaKit

/// O único valor que cruza do supervisor para a sala. O workspace não precisa
/// acessar o processo, PTY ou buffer mutável do agente.
public struct AgentSupervisorEvent: Codable, Equatable, Sendable {
    public let agentID: ULID
    public let transition: AgentStateTransition
    public let payload: JSONValue?

    public init(agentID: ULID, transition: AgentStateTransition, payload: JSONValue? = nil) {
        self.agentID = agentID
        self.transition = transition
        self.payload = payload
    }
}

/// Actor boundary around the deterministic value resolver. The lower-level
/// resolver remains useful for synchronous replay/tests; this wrapper is the
/// isolation boundary used by WorkspaceActor.
public actor CRDTResolverActor {
    private let resolver = CRDTResolver()

    public init() {}

    @discardableResult
    public func apply(_ operation: CRDTOperation) -> Bool {
        resolver.apply(operation)
    }

    public func materializedState() -> CRDTMaterializedState {
        resolver.materializedState
    }
}

/// Supervisor efêmero por agente. O processo real pode ser acoplado ao PTY
/// existente sem expor seu estado: apenas eventos imutáveis saem deste ator.
public actor AgentSupervisor {
    public let agentID: ULID
    private let clock: HLCClock
    private var currentState: CAPState
    private var journal: [Data] = []
    private var continuations: [UUID: AsyncStream<AgentSupervisorEvent>.Continuation] = [:]

    public init(agentID: ULID, nodeID: UUID = UUID(), initialState: CAPState = .idle) {
        self.agentID = agentID
        self.clock = HLCClock(nodeID: nodeID)
        self.currentState = initialState
    }

    public func state() -> CAPState { currentState }

    public func subscribe() -> AsyncStream<AgentSupervisorEvent> {
        let subscriptionID = UUID()
        let pair = AsyncStream<AgentSupervisorEvent>.makeStream()
        continuations[subscriptionID] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscription(subscriptionID) }
        }
        return pair.stream
    }

    @discardableResult
    public func transition(to next: CAPState, reason: String? = nil, payload: JSONValue? = nil) throws -> AgentSupervisorEvent {
        let event = try AgentStateTransition(
            agentId: agentID,
            from: currentState,
            to: next,
            timestamp: clock.tick(),
            payload: payload)
        currentState = next
        let supervisorEvent = AgentSupervisorEvent(agentID: agentID, transition: event, payload: payload)
        for continuation in continuations.values { continuation.yield(supervisorEvent) }
        return supervisorEvent
    }

    public func appendJournal(_ bytes: Data) {
        journal.append(bytes)
    }

    public func journalSnapshot() -> [Data] {
        journal
    }

    public func finish() {
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    private func removeSubscription(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

}

/// Fronteira de isolamento de uma sala. Ela recebe somente eventos Sendable do
/// supervisor; o estado de agentes e do canvas não é exposto por referência.
public actor WorkspaceActor {
    public let workspaceID: ULID
    public let crdtResolver: CRDTResolverActor
    private var rebuilding = false
    private var agentIDs: Set<ULID> = []
    private var stateEvents: [AgentSupervisorEvent] = []

    public init(workspaceID: ULID) {
        self.workspaceID = workspaceID
        self.crdtResolver = CRDTResolverActor()
    }

    @discardableResult
    public func applyCRDTOperation(_ operation: CRDTOperation) async -> Bool {
        await crdtResolver.apply(operation)
    }

    public func materializedCRDTState() async -> CRDTMaterializedState {
        await crdtResolver.materializedState()
    }

    public func registerAgent(_ agentID: ULID) {
        agentIDs.insert(agentID)
    }

    public func setRebuilding(_ value: Bool) {
        rebuilding = value
    }

    public func isReadOnly() -> Bool { rebuilding }

    public func receive(_ event: AgentSupervisorEvent) throws {
        guard agentIDs.contains(event.agentID) else {
            throw WorkspaceActorError.agentNotRegistered(event.agentID)
        }
        stateEvents.append(event)
    }

    public func registeredAgents() -> Set<ULID> { agentIDs }

    public func transitionHistory() -> [AgentSupervisorEvent] { stateEvents }
}

public enum WorkspaceActorError: Error, Equatable, Sendable, LocalizedError {
    case agentNotRegistered(ULID)

    public var errorDescription: String? {
        switch self {
        case .agentNotRegistered(let id): return "agente \(id) não registrado nesta sala"
        }
    }
}

/// Root actor: lifecycle, registry de salas/agentes e serviços compartilhados.
/// Portas de rede podem encaminhar CAP para os métodos deste ator sem tocar o
/// estado de uma sala fora de sua própria fronteira.
public actor EngineActor {
    public let paths: ColmeiaPaths
    public let nodeID: UUID
    public let cas: ContentAddressedStore

    private var workspaces: [ULID: WorkspaceActor] = [:]
    private var supervisors: [ULID: AgentSupervisor] = [:]
    private var trackedPIDs: Set<Int32> = []

    public init(paths: ColmeiaPaths = ColmeiaPaths.v2Default(), nodeID: UUID = UUID()) {
        self.paths = paths
        self.nodeID = nodeID
        self.cas = ContentAddressedStore(paths: paths)
    }

    /// Inicialização também executa a recuperação dos processos registrados
    /// antes de um crash e limpa o lock antes de aceitar novos PIDs.
    public func start() async throws {
        try paths.ensureRootLayout()
        try await recoverOrphanProcesses()
        try clearPIDLock()
    }

    public func workspace(_ id: ULID) -> WorkspaceActor {
        if let existing = workspaces[id] { return existing }
        let created = WorkspaceActor(workspaceID: id)
        workspaces[id] = created
        return created
    }

    public func registerAgent(_ agentID: ULID, in workspaceID: ULID) async -> AgentSupervisor {
        let supervisor = supervisors[agentID] ?? AgentSupervisor(agentID: agentID, nodeID: nodeID)
        supervisors[agentID] = supervisor
        let room = workspace(workspaceID)
        await room.registerAgent(agentID)
        return supervisor
    }

    public func supervisor(_ agentID: ULID) -> AgentSupervisor? {
        supervisors[agentID]
    }

    public func trackPID(_ pid: Int32) throws {
        guard pid > 0 else { return }
        trackedPIDs.insert(pid)
        let body = trackedPIDs.sorted().map(String.init).joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: paths.pidsLockFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.pidsLockFile.path)
    }

    public func untrackPID(_ pid: Int32) throws {
        trackedPIDs.remove(pid)
        let body = trackedPIDs.sorted().map(String.init).joined(separator: "\n")
        try Data(body.utf8).write(to: paths.pidsLockFile, options: [.atomic])
    }

    private func recoverOrphanProcesses() async throws {
        guard let data = try? Data(contentsOf: paths.pidsLockFile) else { return }
        let pids = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" })
            .compactMap { Int32($0) }
        trackedPIDs.removeAll()
        for pid in pids where pid > 0 { _ = kill(pid, SIGTERM) }
        if !pids.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        for pid in pids where pid > 0 {
            if kill(pid, 0) == 0 || errno == EPERM { _ = kill(pid, SIGKILL) }
        }
    }

    private func clearPIDLock() throws {
        guard FileManager.default.fileExists(atPath: paths.pidsLockFile.path) else { return }
        try FileManager.default.removeItem(at: paths.pidsLockFile)
    }
}
