import Foundation
import SwiftUI
import os
import ColmeiaKit

struct UndoEntry {
    let id = ULID.generate()
    let undoOps: [OpPayload]
    let redoOps: [OpPayload]
}

struct ConexaoPendente: Equatable {
    var de: ULID
    var ateMundo: Ponto
}

struct AgentMessageSummary: Identifiable, Equatable {
    let id: ULID
    let de: ULID
    let para: ULID
    let texto: String
    let deliveredAt: Date
    let isHuman: Bool
    let attachments: [String]
}

struct WorkspaceHistorySearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
}

struct MissionTimelineItem: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let title: String
    let detail: String
    let symbol: String
}

/// Estado espelhado do engine + intenções da usuária. Toda mutação do documento sai
/// por `doc.apply` (§7.1) — o store aplica otimista e reconcilia pelo eco `document.op`
/// (dedupe por `op_id`). Pilha de undo é local à sessão de UI (§7.3).
@MainActor
final class AppStore: ObservableObject {
    let connection: EngineConnection
    let notifications = NotificationManager()

    @Published private(set) var workspaces: [WorkspaceSummary] = []
    @Published private(set) var workspace: Workspace?
    @Published private(set) var nodes: [ULID: Node] = [:]
    @Published private(set) var connections: [ULID: Connection] = [:]
    @Published private(set) var approvals: [Approval] = []
    @Published private(set) var delegations: [Delegation] = []
    @Published private(set) var routines: [Routine] = []
    /// Estado operacional adicional, sempre espelhado por chamadas/eventos do engine.
    @Published private(set) var memory = WorkspaceMemory()
    @Published private(set) var memoryBriefing = MemoryBriefing(memory: WorkspaceMemory())
    @Published private(set) var memoryProposals: [MemoryProposal] = []
    @Published private(set) var memoryHistory: [MemoryHistoryEntry] = []
    @Published private(set) var deliveries: [Delivery] = []
    @Published private(set) var watchdogConfiguration = WorkerWatchdogConfiguration()
    @Published private(set) var watchdogAlerts: [WatchdogAlertTopicPayload] = []
    @Published private(set) var workerArchives: [WorkerArchiveTombstone] = []
    @Published private(set) var agentMessages: [AgentMessageSummary] = []
    @Published private(set) var workspaceHealth: WorkspaceHealth?
    @Published var viewport = Viewport()
    @Published var selection: ULID?
    @Published var connectionSelection: ULID?
    @Published var conexaoPendente: ConexaoPendente?
    @Published var lastError: String?
    @Published var avisoInfo: String?
    @Published var showNewTerminal = false
    /// Adapter pré-selecionado no diálogo. A criação nunca parte daqui: a pessoa
    /// ainda precisa dar um nome no `NewTerminalSheet`.
    @Published var newTerminalAdapter = KnownAdapter.claudeCode.rawValue
    /// Inventário informado pelo engine local. A UI nunca tenta iniciar um
    /// adapter marcado como indisponível.
    @Published private(set) var adapterAvailability: [String: AdapterAvailability] = [:]
    @Published var showNewPortal = false
    @Published var showApprovals = false
    @Published var showRoutines = false
    /// §7.1 — decisões open carregadas das salas conhecidas.
    @Published private(set) var openDecisions: [Decision] = []
    /// Agregado da sala vinculada ao workspace aberto. A visão de Missão do
    /// Canvas lê daqui sem duplicar o estado canônico do Hub.
    @Published private(set) var missions: [Mission] = []
    @Published private(set) var workstreams: [Workstream] = []
    /// Layout dos frames semânticos. Em Sala, o Hub é a fonte canônica; no uso
    /// local sem Sala, o mesmo mapa é persistido como preferência da instalação.
    @Published private(set) var semanticObjectPositions: [ULID: Ponto] = [:]
    /// Evita recarregar o layout local em cada atualização remota da missão.
    /// Sem esta guarda, um drag ainda em memória poderia ser sobrescrito pelo
    /// próximo evento `mission.changed`.
    private var semanticLayoutWorkspaceID: ULID?
    /// §7.1 — rótulo de sincronização da sala (online/offline/erro).
    @Published private(set) var roomSyncLabel: String = "Local · engine"
    /// §6.3 — modo de visão do canvas (livre / equipe / atenção / execução).
    @Published var canvasViewMode: CanvasViewMode = .livre
    /// §6.1 — filtro opcional por Missão/Frente.
    @Published var canvasFiltroMissao: ULID? = nil
    @Published var canvasFiltroEstado: String? = nil

    @Published var ferramentaDesenho: TracoTipo?
    @Published var corTraco = "preto"
    @Published var espessuraTraco = 3.0
    @Published var textoPendentePonto: Ponto?
    @Published var replaySession: Session?

    @Published private(set) var floors: [Floor] = []
    @Published private(set) var activeFloor: Floor?

    private(set) var terminalControllers: [ULID: TerminalController] = [:]
    private(set) var notaControllers: [ULID: NotaController] = [:]
    private(set) var portalControllers: [ULID: PortalController] = [:]

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var pendingOpIDs: Set<ULID> = []
    /// O socket aceita requests concorrentes, mas operações do documento carregam
    /// dependências de estado (undo depois do move, delete depois do kill, etc.).
    /// Esta cauda preserva a ordem de intenção da UI sem tirar o feedback
    /// otimista da tela (§6.7).
    private var documentRequestTail: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var canvasEventFlushTask: Task<Void, Never>?
    private var pendingCanvasEvents: [EventMessage] = []
    private var avisoTask: Task<Void, Never>?
    private(set) var draggingNodeID: ULID?
    private var dragBase: Ponto?
    var canvasSize: CGSize = CGSize(width: 1200, height: 800)

    private static let log = Logger(subsystem: "colmeia.canvas", category: "documento")

    private static let lastWorkspaceKey = "colmeia.ultimo-workspace"

    init(connection: EngineConnection) {
        self.connection = connection
        connection.onEvent = { [weak self] event in self?.handle(event: event) }
        connection.onConnected = { [weak self] in await self?.resync() }
    }

    var pendingApprovals: [Approval] {
        approvals.filter { $0.estado == .pendente }.sorted { $0.criadaEm < $1.criadaEm }
    }

    func pendingApprovals(nodeID: ULID) -> [Approval] {
        guard let sessionID = terminalControllers[nodeID]?.sessionID else { return [] }
        return pendingApprovals.filter { $0.sessionID == sessionID }
    }

    func node(bySession sessionID: ULID) -> ULID? {
        terminalControllers.first { $0.value.sessionID == sessionID }?.key
    }

    func delegation(for approval: Approval) -> Delegation? {
        delegations.first {
            $0.pendingApprovalID == approval.id
                || ($0.subagentSessionID == approval.sessionID && !$0.estado.isTerminal)
        }
    }

    func terminalName(_ nodeID: ULID) -> String? {
        guard case .terminal(let terminal) = nodes[nodeID] else { return nil }
        return terminal.nome
    }

    /// §6.3 — aplica visão derivada sobre o conjunto de nós.
    func matchesCanvasViewMode(_ node: Node) -> Bool {
        switch canvasViewMode {
        case .livre: return true
        case .missao, .execucao: return true
        case .equipe:
            if case .terminal = node { return true }
            return false
        case .atencao:
            guard case .terminal = node else { return false }
            let controller = terminalControllers[node.id]
            if controller?.estado == .esperandoHumano || controller?.estado == .aprovacaoPendente {
                return true
            }
            guard let sessionID = controller?.sessionID else { return false }
            return pendingApprovals.contains(where: { $0.sessionID == sessionID })
        }
    }

    /// Vinculação semântica disponível hoje: uma Frente pode apontar para um
    /// agente (o próprio id do nó terminal). Frentes ainda sem assignee não
    /// escondem o restante do workspace, mantendo a visão útil durante o
    /// planejamento inicial da missão.
    func matchesSelectedMission(_ node: Node) -> Bool {
        guard canvasViewMode == .missao, canvasFiltroMissao != nil else { return true }
        let assignedNodeIDs = Set(canvasWorkstreams.compactMap { $0.assignee?.agentID })
        guard !assignedNodeIDs.isEmpty else { return true }
        return assignedNodeIDs.contains(node.id)
    }

    // MARK: - Sincronização pós-(re)conexão

    private func resync() async {
        await refreshAdapterAvailability()
        await refreshWorkspaces()
        if let ws = workspace {
            await open(workspaceID: ws.id, restoreViewport: false)
        } else if let saved = UserDefaults.standard.string(forKey: Self.lastWorkspaceKey),
                  let id = ULID(saved), workspaces.contains(where: { $0.id == id }) {
            await open(workspaceID: id)
        } else if let first = workspaces.first {
            await open(workspaceID: first.id)
        }
        await refreshMissions()
        await refreshDecisions()
        await refreshRoomSync()
    }

    private func refreshAdapterAvailability() async {
        do {
            let adapters = try await connection.call(.adapterList, expecting: AdapterListResult.self)
            adapterAvailability = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0) })
            // Codex é o padrão quando está presente; caso contrário, escolha o
            // primeiro adapter utilizável e nunca pré-selecione um ausente.
            let preference = [
                KnownAdapter.codex.rawValue,
                KnownAdapter.claudeCode.rawValue,
                KnownAdapter.geminiCli.rawValue,
                KnownAdapter.opencode.rawValue,
                KnownAdapter.shell.rawValue,
            ]
            if let preferred = preference.first(where: { adapterAvailability[$0]?.disponivel == true }) {
                newTerminalAdapter = preferred
            }
        } catch {
            // A tela mostra que ainda não há inventário; o detalhe permanece no
            // log, sem expor protocolo/erro técnico em um banner para a pessoa.
            Self.log.error("adapter.list falhou: \(String(describing: error))")
        }
    }

    func adapterInfo(_ id: String) -> AdapterAvailability? {
        adapterAvailability[id]
    }

    func adapterPodeSerSelecionado(_ id: String) -> Bool {
        if id == KnownAdapter.geminiCli.rawValue || id == KnownAdapter.shell.rawValue {
            return true
        }
        return adapterAvailability[id]?.disponivel == true
    }

    func motivoAdapterIndisponivel(_ id: String) -> String {
        if let info = adapterAvailability[id], !info.disponivel {
            return "\(info.nome) não está instalado neste Mac."
        }
        if adapterAvailability.isEmpty {
            return "Verificando os apps de terminal disponíveis…"
        }
        return "Este tipo de terminal não está disponível neste Mac."
    }

    func refreshWorkspaces() async {
        do {
            workspaces = try await connection.call(.workspaceList, expecting: WorkspaceListResult.self)
        } catch {
            report(error, "workspace.list")
        }
    }

    // MARK: - Workspaces

    func createWorkspace(nome: String, caminhoRaiz: String?) async {
        do {
            let result = try await connection.call(
                .workspaceCreate,
                params: WorkspaceCreateParams(nome: nome, caminhoRaiz: caminhoRaiz),
                expecting: WorkspaceResult.self
            )
            await refreshWorkspaces()
            await open(workspaceID: result.workspace.id)
        } catch {
            report(error, "workspace.create")
        }
    }

    /// Exporta somente a projeção portátil do canvas. Journals, sessões vivas,
    /// cookies, tokens e paths locais ficam fora do arquivo por construção.
    func exportWorkspace(to url: URL) async {
        guard let ws = workspace else { return }
        do {
            let result = try await connection.call(
                .docSnapshot,
                params: DocSnapshotParams(workspaceID: ws.id),
                expecting: DocSnapshotResult.self)
            try WorkspaceArchive(workspace: ws, snapshot: result.documentSnapshot).write(to: url)
            avisoInfo = "Workspace exportado para \(url.lastPathComponent)."
        } catch {
            report(error, "workspace.export")
        }
    }

    func exportDiagnostics(to url: URL) async {
        guard let ws = workspace else { return }
        do {
            let snapshot = try await connection.call(
                .docSnapshot,
                params: DocSnapshotParams(workspaceID: ws.id),
                expecting: DocSnapshotResult.self).documentSnapshot
            let history = try await connection.call(
                .docHistory,
                params: DocHistoryParams(workspaceID: ws.id, desdeSeq: 1),
                expecting: DocHistoryResult.self).ops
            let sessions = try await connection.call(
                .sessionList,
                params: SessionListParams(workspaceID: ws.id),
                expecting: SessionListResult.self).map(DiagnosticSession.init)
            let health = workspaceHealth ?? WorkspaceHealth(
                workspaceID: ws.id, state: .open, snapshotAvailable: true,
                journalAvailable: true, quarantineAvailable: false)
            try WorkspaceDiagnostic(
                workspace: ws, health: health, snapshot: snapshot,
                operations: history, sessions: sessions).write(to: url)
            avisoInfo = "Diagnóstico exportado para \(url.lastPathComponent)."
        } catch {
            report(error, "workspace.diagnostics.export")
        }
    }

    /// Importa um arquivo portátil como um novo workspace. IDs de nós são
    /// preservados para manter conexões, enquanto o workspace recebe nova
    /// identidade; conteúdo de notas volta pelos endpoints controlados do Engine.
    func importWorkspace(from url: URL, caminhoRaiz: String? = nil) async {
        do {
            let archive = try WorkspaceArchive.read(from: url)
            let importedID = ULID.generate()
            let imported = archive.reidentified(
                workspaceID: importedID,
                name: archive.workspace.nome,
                rootPath: caminhoRaiz)
            let result = try await connection.call(
                .workspaceCreate,
                params: WorkspaceCreateParams(
                    nome: imported.workspace.nome,
                    caminhoRaiz: imported.workspace.caminhoRaiz,
                    id: importedID),
                expecting: WorkspaceResult.self)
            await refreshWorkspaces()
            await open(workspaceID: result.workspace.id)
            var payloads = imported.snapshot.nodes.map { OpPayload.nodeAdd(NodeAddOpPayload(node: $0)) }
            payloads.append(contentsOf: imported.snapshot.connections.map { .connectionAdd(ConnectionAddOpPayload(connection: $0)) })
            try await performManyAguardando(payloads)
            for (nodeIDString, content) in imported.snapshot.noteContents ?? [:]
                where ULID(nodeIDString) != nil {
                guard let nodeID = ULID(nodeIDString) else { continue }
                _ = try await connection.call(
                    .noteReplace,
                    params: NoteReplaceParams(workspaceID: importedID, nodeID: nodeID, conteudo: content))
            }
            avisoInfo = "Workspace importado de \(url.lastPathComponent)."
        } catch {
            report(error, "workspace.import")
        }
    }

    func open(workspaceID: ULID, restoreViewport: Bool = true) async {
        do {
            // Fechar explicitamente o workspace anterior materializa o snapshot
            // antes da troca e deixa as sessões vivas para o próximo reattach.
            // Isso evita que duas abas lógicas disputem o mesmo espelho local.
            if let previous = workspace, previous.id != workspaceID {
                _ = try? await connection.call(
                    .workspaceClose,
                    params: WorkspaceCloseParams(id: previous.id),
                    expecting: EmptyResult.self)
            }
            let result = try await connection.call(
                .workspaceOpen,
                params: WorkspaceOpenParams(id: workspaceID),
                expecting: WorkspaceOpenResult.self
            )
            for controller in terminalControllers.values { controller.detach() }
            terminalControllers.removeAll()
            notaControllers.removeAll()
            portalControllers.removeAll()
            undoStack.removeAll()
            redoStack.removeAll()
            // Requests do workspace anterior continuam podendo receber response
            // depois da troca, mas não podem reconciliar/segurar o novo canvas.
            // Os op_ids são ULIDs globais, então descartar este dedupe local é
            // seguro; o próximo open recomeça da verdade do engine.
            pendingOpIDs.removeAll()
            documentRequestTail = nil
            selection = nil
            connectionSelection = nil
            conexaoPendente = nil
            draggingNodeID = nil
            dragBase = nil
            // Estes recursos são isolados por workspace e não fazem parte do
            // DocumentSnapshot; limpar antes do refresh evita conteúdo antigo
            // aparecer enquanto as requests do workspace novo estão em voo.
            memory = WorkspaceMemory()
            memoryBriefing = MemoryBriefing(memory: WorkspaceMemory())
            memoryProposals = []
            memoryHistory = []
            deliveries = []
            watchdogConfiguration = WorkerWatchdogConfiguration()
            watchdogAlerts = []
            workerArchives = []
            agentMessages = []
            missions = []
            workstreams = []
            semanticObjectPositions = [:]
            semanticLayoutWorkspaceID = nil
            workspaceHealth = nil
            delegations = []

            workspace = result.workspace
            workspaceHealth = result.health
            if restoreViewport {
                viewport = result.workspace.viewport
            }
            nodes = Dictionary(uniqueKeysWithValues: result.documentSnapshot.nodes.map { ($0.id, $0) })
            connections = Dictionary(uniqueKeysWithValues: result.documentSnapshot.connections.map { ($0.id, $0) })
            UserDefaults.standard.set(workspaceID.string, forKey: Self.lastWorkspaceKey)

            _ = try? await connection.call(
                .subscribe,
                params: SubscribeParams(topics: ColmeiaTopic.allCases, workspaceID: workspaceID)
            )
            await reattachSessions()
            await refreshApprovals()
            await refreshDelegations()
            await refreshRoutines()
            await refreshFloors()
            await refreshOperationalState()
            await refreshAgentMessages()
        } catch {
            report(error, "workspace.open")
        }
    }

    /// Fecha o workspace visual sem encerrar sessões vivas (§6.4). A próxima
    /// abertura reconecta as sessões persistidas pelo Engine.
    func closeWorkspace() async {
        guard let current = workspace else { return }
        do {
            _ = try await connection.call(
                .workspaceClose,
                params: WorkspaceCloseParams(id: current.id),
                expecting: EmptyResult.self)
            for controller in terminalControllers.values { controller.detach() }
            terminalControllers.removeAll()
            workspace = nil
            workspaceHealth = nil
            nodes.removeAll()
            connections.removeAll()
            missions.removeAll()
            workstreams.removeAll()
            semanticObjectPositions.removeAll()
            semanticLayoutWorkspaceID = nil
            canvasFiltroMissao = nil
            selection = nil
            avisoInfo = "Workspace fechado; sessões permanecem disponíveis para retomar."
        } catch {
            report(error, "workspace.close")
        }
    }

    func renameWorkspace(_ nome: String) {
        guard workspace != nil else { return }
        perform(.workspaceRename(WorkspaceRenameOpPayload(nome: nome)))
    }

    func setPrimaryAgent(_ nodeID: ULID) async {
        guard let ws = workspace else { return }
        do {
            let result = try await connection.call(
                .workspaceUpdate,
                params: WorkspaceUpdateParams(id: ws.id, primaryNodeID: nodeID),
                expecting: WorkspaceResult.self)
            workspace = result.workspace
        } catch {
            report(error, "workspace.primary")
        }
    }

    /// Reabrir a UI com sessões vivas DEVE reconectar todos os terminais (§8.4).
    private func reattachSessions() async {
        guard let ws = workspace else { return }
        let sessions = (try? await connection.call(
            .sessionList,
            params: SessionListParams(workspaceID: ws.id),
            expecting: SessionListResult.self
        )) ?? []
        // `session.list` pode trazer o histórico do nó; vale a viva, senão a mais recente.
        // Attaches em paralelo: replay de journals grandes não pode serializar o launch (§21.1).
        let porNode = Dictionary(grouping: sessions, by: \.nodeID)
        await withTaskGroup(of: Void.self) { group in
            for (nodeID, candidatas) in porNode {
                guard case .terminal = nodes[nodeID] else { continue }
                let escolhida = candidatas.first(where: { $0.estado.isViva })
                    ?? candidatas.max(by: { $0.iniciadaEm < $1.iniciadaEm })
                guard let session = escolhida else { continue }
                let controller = terminalController(for: nodeID)
                controller.adopt(session: session)
                group.addTask { @MainActor in
                    if session.estado.isViva {
                        await controller.attach()
                    } else {
                        await controller.restoreDeadFrame()
                    }
                }
            }
        }
    }

    private func refreshApprovals() async {
        guard let ws = workspace else { return }
        approvals = (try? await connection.call(
            .approvalList,
            params: ApprovalListParams(workspaceID: ws.id),
            expecting: ApprovalListResult.self
        )) ?? []
    }

    private func refreshDelegations() async {
        guard let ws = workspace else { return }
        delegations = (try? await connection.call(
            .delegationList,
            params: DelegationListParams(workspaceID: ws.id),
            expecting: [Delegation].self
        )) ?? []
    }

    func refreshRoutines() async {
        guard let ws = workspace else { return }
        routines = (try? await connection.call(
            .routineList,
            params: RoutineListParams(workspaceID: ws.id),
            expecting: RoutineListResult.self
        )) ?? []
    }

    // MARK: - Estado operacional: memória, entregas, watchdog e arquivo

    /// Recarrega os espelhos que não participam do documento do canvas. Falhas
    /// individuais não apagam o último estado exibido, útil durante reconexão.
    func refreshOperationalState() async {
        await refreshMemory()
        await refreshDeliveries()
        await refreshWatchdog()
        await refreshWorkerArchives()
        await refreshMissions()
        await refreshDecisions()
        await refreshRoomSync()
    }

    func refreshAgentMessages() async {
        guard let ws = workspace else { return }
        do {
            let messages = try await connection.call(
                .chatMessageList,
                params: ChatMessageListParams(workspaceID: ws.id, limit: 200),
                expecting: ChatMessageListResult.self)
            agentMessages = messages.map(agentMessageSummary)
        } catch {
            report(error, "chat.history")
        }
    }

    func refreshWorkspaceHealth() async {
        guard let ws = workspace else { return }
        workspaceHealth = try? await connection.call(
            .workspaceHealth,
            params: WorkspaceHealthParams(workspaceID: ws.id),
            expecting: WorkspaceHealthResult.self)
    }

    /// Busca no histórico estruturado sem expor payloads de operações ou
    /// output ANSI à UI de busca. Conteúdo de arquivos/notas é indexado pela
    /// própria árvore do workspace.
    func searchWorkspaceHistory(_ query: String) async -> [WorkspaceHistorySearchResult] {
        guard let ws = workspace else { return [] }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return [] }
        var output: [WorkspaceHistorySearchResult] = []
        if let operations = try? await connection.call(
            .docHistory,
            params: DocHistoryParams(workspaceID: ws.id, desdeSeq: 1),
            expecting: DocHistoryResult.self).ops {
            output.append(contentsOf: operations.compactMap { op in
                let type = op.tipo.rawValue
                let author = String(describing: op.author).lowercased()
                guard type.lowercased().contains(term) || author.contains(term) else { return nil }
                return WorkspaceHistorySearchResult(
                    id: "op-\(op.opID.string)",
                    title: type,
                    detail: "seq \(op.seq.map(String.init) ?? "—") · \(op.author)",
                    symbol: "arrow.triangle.branch")
            })
        }
        if let messages = try? await connection.call(
            .chatMessageList,
            params: ChatMessageListParams(workspaceID: ws.id, limit: 2_000),
            expecting: ChatMessageListResult.self) {
            output.append(contentsOf: messages.compactMap { message in
                guard message.text.lowercased().contains(term) else { return nil }
                return WorkspaceHistorySearchResult(
                    id: "chat-\(message.id.string)",
                    title: "Chat · \(nodeName(message.toNodeID))",
                    detail: message.text,
                    symbol: "bubble.left.and.bubble.right")
            })
        }
        return Array(output.prefix(100))
    }

    func appendHumanChatMessage(
        toNodeID: ULID,
        text: String,
        attachments: [URL] = []
    ) async throws {
        guard let ws = workspace else { return }
        let result = try await connection.call(
            .chatMessageAppend,
            params: ChatMessageAppendParams(
                workspaceID: ws.id,
                toNodeID: toNodeID,
                text: text,
                attachments: attachments.map(\.path)),
            expecting: ChatMessageResult.self)
        upsert(agentMessage: agentMessageSummary(result.message))
    }

    /// §7.1 — Decisões abertas nas salas do engine local.
    func refreshDecisions() async {
        do {
            let rooms: RoomListResult = try await connection.call(
                .roomList, expecting: RoomListResult.self)
            var collected: [Decision] = []
            for room in rooms where room.state == .active {
                let list: DecisionListResult = try await connection.call(
                    .decisionList,
                    params: DecisionListParams(roomID: room.id, state: .open),
                    expecting: DecisionListResult.self)
                collected.append(contentsOf: list)
            }
            openDecisions = collected.sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        } catch {
            // engine indisponível — mantém cache
        }
    }

    /// Recarrega o agregado Missão → Frente da sala associada ao workspace.
    /// Salas de outros workspaces ficam fora do Canvas atual; se não houver
    /// sala vinculada, o estado é explicitamente vazio para não exibir dados
    /// de uma sessão anterior.
    func refreshMissions() async {
        guard let workspaceID = workspace?.id else {
            missions = []
            workstreams = []
            return
        }
        do {
            let rooms: RoomListResult = try await connection.call(
                .roomList, expecting: RoomListResult.self)
            let linkedRooms = rooms.filter {
                $0.state == .active && $0.workspaceID == workspaceID
            }
            var loadedMissions: [Mission] = []
            var loadedWorkstreams: [Workstream] = []
            for room in linkedRooms {
                let roomMissions: MissionListResult = try await connection.call(
                    .missionList,
                    params: MissionListParams(roomID: room.id),
                    expecting: MissionListResult.self)
                loadedMissions.append(contentsOf: roomMissions)
                for mission in roomMissions {
                    let fronts: WorkstreamListResult = try await connection.call(
                        .workstreamList,
                        params: WorkstreamListParams(roomID: room.id, missionID: mission.id),
                        expecting: WorkstreamListResult.self)
                    loadedWorkstreams.append(contentsOf: fronts)
                }
            }
            missions = loadedMissions.sorted { lhs, rhs in
                lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
            }
            workstreams = loadedWorkstreams.sorted { lhs, rhs in
                lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
            }
            if let filtro = canvasFiltroMissao, !missions.contains(where: { $0.id == filtro }) {
                canvasFiltroMissao = nil
            }
        } catch {
            // Em reconexão, conserva o último agregado exibível.
            Self.log.error("mission/workstream refresh falhou: \(String(describing: error))")
        }
    }

    /// Injeta o snapshot obtido pelo painel multiplayer quando a Sala está em
    /// um Hub remoto (nesse caso o Engine local não conhece necessariamente a
    /// sala). O próximo refresh canônico substitui este cache normalmente.
    func updateMissionSnapshot(_ missions: [Mission], workstreams: [Workstream]) {
        self.missions = missions.sorted { $0.updatedAt > $1.updatedAt }
        self.workstreams = workstreams.sorted { $0.updatedAt > $1.updatedAt }
        loadSemanticObjectPositionsIfNeeded()
        if let filtro = canvasFiltroMissao, !self.missions.contains(where: { $0.id == filtro }) {
            canvasFiltroMissao = nil
        }
    }

    func semanticObjectPosition(_ id: ULID, index: Int = 0) -> Ponto {
        if let position = semanticObjectPositions[id] { return position }
        return Ponto(x: 80 + Double(index % 3) * 440, y: 100 + Double(index / 3) * 300)
    }

    func moveSemanticObject(_ id: ULID, to position: Ponto, persist: Bool = false) {
        guard CanvasMath.posicaoSana(position) else { return }
        semanticObjectPositions[id] = position
        if persist { persistSemanticObjectPositions() }
    }

    /// Substitui o layout recebido do Hub, preservando apenas ULIDs e posições
    /// dentro dos limites do canvas. O fallback local continua disponível
    /// quando não há uma Sala ativa.
    func replaceSemanticObjectPositions(_ positions: [String: Ponto]) {
        semanticObjectPositions = positions.reduce(into: [:]) { result, entry in
            guard let id = ULID(entry.key), CanvasMath.posicaoSana(entry.value) else { return }
            result[id] = entry.value
        }
    }

    private func semanticLayoutKey(for workspaceID: ULID) -> String {
        "colmeia.semantic-layout.\(workspaceID.string)"
    }

    private func loadSemanticObjectPositionsIfNeeded() {
        guard let workspaceID = workspace?.id else { return }
        guard semanticLayoutWorkspaceID != workspaceID else { return }
        semanticLayoutWorkspaceID = workspaceID
        semanticObjectPositions = [:]
        let key = semanticLayoutKey(for: workspaceID)
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? ColmeiaJSON.decoder().decode([String: Ponto].self, from: data)
        else { return }
        semanticObjectPositions = decoded.reduce(into: [:]) { result, entry in
            if let id = ULID(entry.key) { result[id] = entry.value }
        }
    }

    private func persistSemanticObjectPositions() {
        guard let workspaceID = workspace?.id else { return }
        let encoded = semanticObjectPositions.reduce(into: [String: Ponto]()) {
            $0[$1.key.string] = $1.value
        }
        if let data = try? ColmeiaJSON.encoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: semanticLayoutKey(for: workspaceID))
        }
    }

    /// Aplica o delta semântico recebido do Hub remoto. O Hub envia o
    /// agregado completo para que a UI não dependa de uma segunda leitura
    /// durante uma reconexão.
    func applyRemoteMissionEvent(_ event: EventMessage) {
        switch event.knownTopic {
        case .missionChanged:
            guard let payload = try? event.decodeParams(MissionChangedTopicPayload.self) else { return }
            if let index = missions.firstIndex(where: { $0.id == payload.mission.id }) {
                missions[index] = payload.mission
            } else {
                missions.append(payload.mission)
            }
            missions.sort { $0.updatedAt > $1.updatedAt }
            if let filtro = canvasFiltroMissao, !missions.contains(where: { $0.id == filtro }) {
                canvasFiltroMissao = nil
            }
        case .workstreamChanged:
            guard let payload = try? event.decodeParams(WorkstreamChangedTopicPayload.self) else { return }
            if let index = workstreams.firstIndex(where: { $0.id == payload.workstream.id }) {
                workstreams[index] = payload.workstream
            } else {
                workstreams.append(payload.workstream)
            }
            workstreams.sort { $0.updatedAt > $1.updatedAt }
        default:
            break
        }
    }

    /// Aplica uma decisão recebida pelo Hub sem depender de uma leitura do
    /// Engine local (que pode nem conhecer a sala remota).
    func applyRemoteDecisionEvent(_ event: EventMessage) {
        guard let payload = try? event.decodeParams(DecisionChangedTopicPayload.self) else { return }
        if payload.decision.state == .open {
            if let index = openDecisions.firstIndex(where: { $0.id == payload.decision.id }) {
                openDecisions[index] = payload.decision
            } else {
                openDecisions.append(payload.decision)
            }
        } else {
            openDecisions.removeAll { $0.id == payload.decision.id }
        }
        openDecisions.sort { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    func applyRemoteSemanticLayoutEvent(_ event: EventMessage) {
        guard let payload = try? event.decodeParams(RoomLayoutChangedTopicPayload.self) else { return }
        replaceSemanticObjectPositions(payload.positions)
    }

    var canvasMission: Mission? {
        guard let id = canvasFiltroMissao else { return nil }
        return missions.first { $0.id == id }
    }

    var canvasWorkstreams: [Workstream] {
        guard let mission = canvasMission else { return [] }
        return workstreams.filter { $0.missionID == mission.id }
    }

    var canvasMissionDecisions: [Decision] {
        guard let mission = canvasMission else { return [] }
        return openDecisions.filter { $0.missionID == mission.id }
    }

    var canvasMissionDeliveries: [Delivery] {
        guard let mission = canvasMission else { return [] }
        return deliveries.filter { $0.missionID == mission.id }
    }

    /// Linha do tempo derivada do agregado já sincronizado. Ela conecta o
    /// briefing (missão/frentes), decisões abertas e entregas sem inventar uma
    /// segunda fonte de eventos no cliente.
    var canvasMissionTimeline: [MissionTimelineItem] {
        guard let mission = canvasMission else { return [] }
        var items = [MissionTimelineItem(
            id: "mission-\(mission.id.string)", date: mission.updatedAt,
            title: mission.title,
            detail: "Missão · \(mission.state.rawValue.replacingOccurrences(of: "_", with: " "))",
            symbol: "flag.checkered")]
        items += canvasWorkstreams.map {
            MissionTimelineItem(
                id: "workstream-\($0.id.string)", date: $0.updatedAt,
                title: $0.title,
                detail: "Frente · \($0.state.rawValue.replacingOccurrences(of: "_", with: " "))",
                symbol: "arrow.triangle.branch")
        }
        items += canvasMissionDecisions.map {
            MissionTimelineItem(
                id: "decision-\($0.id.string)", date: $0.updatedAt,
                title: $0.question,
                detail: "Decisão · \($0.state.rawValue)",
                symbol: "questionmark.bubble")
        }
        items += canvasMissionDeliveries.map {
            MissionTimelineItem(
                id: "delivery-\($0.id.string)", date: $0.atualizadaEm,
                title: $0.resumo,
                detail: "Entrega · \($0.estado.rawValue)",
                symbol: "shippingbox")
        }
        return items.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date > rhs.date
        }
    }

    /// §7.1 — rótulo de status da Sala (online/sincronizando/offline/erro).
    func refreshRoomSync() async {
        do {
            let status: EngineStatusResult = try await connection.call(
                .engineStatus, expecting: EngineStatusResult.self)
            roomSyncLabel = "Online · engine \(status.versao) · \(status.workspacesAbertos) workspace(s)"
        } catch {
            roomSyncLabel = "Offline · engine indisponível"
        }
    }

    func refreshMemory() async {
        guard let ws = workspace else { return }
        do {
            let result = try await connection.call(
                .memoryGet, params: MemoryGetParams(workspaceID: ws.id), expecting: MemoryGetResult.self)
            memory = result.memory
            memoryBriefing = result.briefing
            memoryProposals = try await connection.call(
                .memoryProposalList,
                params: MemoryProposalListParams(workspaceID: ws.id),
                expecting: MemoryProposalListResult.self)
            memoryHistory = try await connection.call(
                .memoryHistory, params: MemoryHistoryParams(workspaceID: ws.id), expecting: MemoryHistoryResult.self)
        } catch {
            report(error, "memory.refresh")
        }
    }

    func updateMemory(_ content: String) async {
        guard let ws = workspace else { return }
        do {
            let result = try await connection.call(
                .memoryUpdate, params: MemoryUpdateParams(workspaceID: ws.id, content: content),
                expecting: MemoryGetResult.self)
            memory = result.memory
            memoryBriefing = result.briefing
            await refreshMemory()
        } catch {
            report(error, "memory.update")
        }
    }

    func proposeMemory(_ content: String, proposalID: ULID? = nil) async {
        guard let ws = workspace else { return }
        do {
            let proposal = try await connection.call(
                .memoryPropose,
                params: MemoryProposeParams(workspaceID: ws.id, proposalID: proposalID, content: content),
                expecting: MemoryProposal.self)
            upsert(memoryProposal: proposal)
        } catch {
            report(error, "memory.propose")
        }
    }

    func acceptMemoryProposal(_ proposalID: ULID, editedContent: String? = nil) async {
        guard let ws = workspace else { return }
        do {
            let result = try await connection.call(
                .memoryAccept,
                params: MemoryProposalResolveParams(
                    workspaceID: ws.id, proposalID: proposalID, editedContent: editedContent),
                expecting: MemoryGetResult.self)
            memory = result.memory
            memoryBriefing = result.briefing
            await refreshMemory()
        } catch {
            report(error, "memory.accept")
        }
    }

    func rejectMemoryProposal(_ proposalID: ULID, note: String? = nil) async {
        guard let ws = workspace else { return }
        do {
            let proposal = try await connection.call(
                .memoryReject,
                params: MemoryProposalResolveParams(workspaceID: ws.id, proposalID: proposalID, note: note),
                expecting: MemoryProposal.self)
            upsert(memoryProposal: proposal)
            await refreshMemory()
        } catch {
            report(error, "memory.reject")
        }
    }

    func refreshDeliveries() async {
        guard let ws = workspace else { return }
        do {
            deliveries = try await connection.call(
                .deliveryList, params: DeliveryListParams(workspaceID: ws.id), expecting: DeliveryListResult.self)
        } catch {
            report(error, "delivery.list")
        }
    }

    func submitDelivery(_ submission: DeliverySubmission) async {
        guard workspace?.id == submission.workspaceID else { return }
        do {
            let result = try await connection.call(
                .deliverySubmit, params: DeliverySubmitParams(submission: submission), expecting: DeliveryResult.self)
            upsert(delivery: result.delivery)
        } catch {
            report(error, "delivery.submit")
        }
    }

    func acceptDelivery(_ deliveryID: ULID) async {
        do {
            let result = try await connection.call(
                .deliveryAccept, params: DeliveryReviewParams(deliveryID: deliveryID), expecting: DeliveryResult.self)
            upsert(delivery: result.delivery)
        } catch {
            report(error, "delivery.accept")
        }
    }

    func reopenDelivery(_ deliveryID: ULID) async {
        do {
            let result = try await connection.call(
                .deliveryReopen, params: DeliveryReviewParams(deliveryID: deliveryID), expecting: DeliveryResult.self)
            upsert(delivery: result.delivery)
        } catch {
            report(error, "delivery.reopen")
        }
    }

    func refreshWatchdog() async {
        guard let ws = workspace else { return }
        do {
            let result = try await connection.call(
                .watchdogGet, params: WatchdogGetParams(workspaceID: ws.id), expecting: WatchdogGetResult.self)
            watchdogConfiguration = result.configuration
        } catch {
            report(error, "watchdog.get")
        }
    }

    func updateWatchdog(_ configuration: WorkerWatchdogConfiguration) async {
        guard let ws = workspace else { return }
        do {
            let result = try await connection.call(
                .watchdogUpdate,
                params: WatchdogUpdateParams(workspaceID: ws.id, configuration: configuration),
                expecting: WatchdogGetResult.self)
            watchdogConfiguration = result.configuration
        } catch {
            report(error, "watchdog.update")
        }
    }

    func refreshWorkerArchives() async {
        guard let ws = workspace else { return }
        do {
            workerArchives = try await connection.call(
                .workerList, params: WorkerListParams(workspaceID: ws.id), expecting: WorkerListResult.self)
        } catch {
            report(error, "worker.list")
        }
    }

    func archiveWorker(sessionID: ULID, confirmar: Bool = false) async {
        guard let ws = workspace else { return }
        do {
            let result = try await connection.call(
                .workerArchive,
                params: WorkerArchiveParams(workspaceID: ws.id, sessionID: sessionID, confirmar: confirmar),
                expecting: WorkerArchiveResult.self)
            upsert(workerArchive: result.tombstone)
        } catch {
            report(error, "worker.archive")
        }
    }

    /// Ação explicitamente humana: encerra a sessão, espera o engine confirmar o
    /// fim do processo e só então cria o tombstone. Nunca é chamada pelo watchdog.
    func terminateAndArchiveWorker(sessionID: ULID) async {
        guard let ws = workspace else { return }
        do {
            let current: SessionListResult = try await connection.call(
                .sessionList,
                params: SessionListParams(workspaceID: ws.id),
                expecting: SessionListResult.self)
            if current.first(where: { $0.id == sessionID })?.estado.isViva == true {
                _ = try await connection.call(
                    .sessionKill,
                    params: SessionKillParams(sessionID: sessionID, sinal: .term),
                    expecting: EmptyResult.self)
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(300))
                    let sessions: SessionListResult = try await connection.call(
                        .sessionList,
                        params: SessionListParams(workspaceID: ws.id),
                        expecting: SessionListResult.self)
                    if sessions.first(where: { $0.id == sessionID })?.estado.isViva != true {
                        break
                    }
                }
            }
            await archiveWorker(sessionID: sessionID, confirmar: true)
        } catch {
            report(error, "worker.terminate_and_archive")
        }
    }

    /// Reativa apenas a referência para replay; o contrato não recria um processo.
    func restoreWorkerReplay(_ archiveID: ULID) async {
        guard let ws = workspace else { return }
        do {
            let result = try await connection.call(
                .workerRestore,
                params: WorkerRestoreParams(workspaceID: ws.id, archiveID: archiveID),
                expecting: WorkerRestoreResult.self)
            replaySession = result.session
        } catch {
            report(error, "worker.restore")
        }
    }

    private func upsert(memoryProposal: MemoryProposal) {
        if let index = memoryProposals.firstIndex(where: { $0.id == memoryProposal.id }) {
            memoryProposals[index] = memoryProposal
        } else {
            memoryProposals.append(memoryProposal)
        }
        memoryProposals.sort { $0.createdAt < $1.createdAt }
    }

    private func upsert(delivery: Delivery) {
        if let index = deliveries.firstIndex(where: { $0.id == delivery.id }) {
            deliveries[index] = delivery
        } else {
            deliveries.append(delivery)
        }
        deliveries.sort { $0.criadaEm < $1.criadaEm }
    }

    private func upsert(workerArchive: WorkerArchiveTombstone) {
        if let index = workerArchives.firstIndex(where: { $0.id == workerArchive.id }) {
            workerArchives[index] = workerArchive
        } else {
            workerArchives.append(workerArchive)
        }
        workerArchives.sort { $0.archivedAt < $1.archivedAt }
    }

    // MARK: - Controllers

    func terminalController(for nodeID: ULID) -> TerminalController {
        if let existing = terminalControllers[nodeID] { return existing }
        let controller = TerminalController(nodeID: nodeID, connection: connection)
        terminalControllers[nodeID] = controller
        return controller
    }

    func notaController(for node: NotaNode) -> NotaController {
        if let existing = notaControllers[node.id] { return existing }
        guard let ws = workspace else { fatalError("nota sem workspace aberto") }
        let controller = NotaController(node: node, workspaceID: ws.id)
        notaControllers[node.id] = controller
        return controller
    }

    /// Um controller (e um WKWebView) por portal. Navegação interna do webview e
    /// título viram `node.update` (não-undoable: estado derivado da navegação).
    func portalController(for node: PortalNode) -> PortalController {
        if let existing = portalControllers[node.id] { return existing }
        let controller = PortalController(nodeID: node.id)
        let nodeID = node.id
        controller.onURLNavegada = { [weak self] nova in
            guard let self, case .portal(let atual)? = self.nodes[nodeID], atual.url != nova else { return }
            self.perform(.nodeUpdate(NodeUpdateOpPayload(
                id: nodeID, campos: .object(["url": .string(nova)]))), undoable: false)
        }
        controller.onTitulo = { [weak self] titulo in
            guard let self, case .portal(let atual)? = self.nodes[nodeID], atual.titulo != titulo else { return }
            self.perform(.nodeUpdate(NodeUpdateOpPayload(
                id: nodeID, campos: .object(["titulo": .string(titulo)]))), undoable: false)
        }
        portalControllers[node.id] = controller
        return controller
    }

    func returnFocusToCanvas() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    // MARK: - Documento: propor ops

    func perform(_ payload: OpPayload, undoable: Bool = true) {
        // Callbacks de controles SwiftUI/WebKit podem chegar um run-loop depois de
        // o nó ter sido apagado. Sem esta guarda, um `node.update` sem alvo sai
        // pelo socket e vira erro enganoso; só descartamos o caso inequivocamente
        // obsoleto no espelho local. Se o nó existe aqui mas o engine o rejeita,
        // o erro legítimo continua sendo reportado normalmente.
        if case .nodeUpdate(let update) = payload, nodes[update.id] == nil {
            Self.log.debug("node.update obsoleto descartado para \(update.id.string)")
            return
        }
        performMany([payload], undoable: undoable)
    }

    /// Vários payloads em UM `doc.apply` — o engine aplica em ordem na mesma request,
    /// evitando corrida entre Tasks (ex.: substituir conexão = delete + add).
    func performMany(_ payloads: [OpPayload], undoable: Bool = true) {
        guard let workspace, !payloads.isEmpty else { return }
        let staged = stageOptimistic(payloads, workspaceID: workspace.id, undoable: undoable)
        let request = enqueueDocumentProposal(staged)
        Task {
            do {
                try await request.value
            } catch {
                self.report(error, "doc.apply \(payloads.map(\.tipo.rawValue).joined(separator: ","))")
            }
        }
    }

    /// Como `performMany`, mas AGUARDA a response do engine e rethrowa a rejeição —
    /// para fluxos que dependem da op EXISTIR no engine antes do próximo passo
    /// (ex.: node.add → session.start, §7.1/§9.1). Rejeição desfaz o otimista.
    func performManyAguardando(_ payloads: [OpPayload], undoable: Bool = true) async throws {
        guard let workspace, !payloads.isEmpty else { return }
        let staged = stageOptimistic(payloads, workspaceID: workspace.id, undoable: undoable)
        try await enqueueDocumentProposal(staged).value
    }

    /// Reserva imediatamente uma posição na fila. `Task` criado em MainActor
    /// mantém a ordem mesmo quando duas ações SwiftUI entram no mesmo run loop;
    /// sem essa reserva, duas Tasks poderiam observar a mesma cauda e emitir
    /// `doc.apply` em ordem inversa no socket.
    private func enqueueDocumentProposal(_ staged: StagedApply) -> Task<Void, Error> {
        let anterior = documentRequestTail
        let request = Task { [weak self] () throws -> Void in
            await anterior?.value
            guard let self else { throw CancellationError() }
            try await self.propose(staged)
        }
        documentRequestTail = Task {
            _ = try? await request.value
        }
        return request
    }

    private struct StagedApply {
        /// Workspace em que a intenção nasceu. A UI pode trocar de workspace
        /// enquanto uma response está em voo; rollback no canvas novo seria
        /// corrupção local, não reconciliação.
        let workspaceID: ULID
        let ops: [DocOp]
        /// Inversas (na ordem de desfazer) para reverter a aplicação otimista.
        let rollback: [OpPayload]
        let undoEntryID: ULID?
    }

    /// Aplica otimista no espelho local, registra undo e devolve o necessário
    /// para propor ao engine e reverter se ele rejeitar.
    private func stageOptimistic(
        _ payloads: [OpPayload],
        workspaceID: ULID,
        undoable: Bool
    ) -> StagedApply {
        var ops: [DocOp] = []
        var inverses: [OpPayload] = []
        for payload in payloads {
            if let inverse = inverse(of: payload) {
                inverses.append(inverse)
            }
            let op = DocOp(opID: ULID.generate(), author: .humanoLocal, ts: Date(), payload: payload)
            pendingOpIDs.insert(op.opID)
            apply(payload)
            ops.append(op)
        }
        var undoEntryID: ULID?
        if undoable, !inverses.isEmpty {
            let entry = UndoEntry(undoOps: inverses.reversed(), redoOps: payloads)
            undoStack.append(entry)
            redoStack.removeAll()
            undoEntryID = entry.id
        }
        return StagedApply(
            workspaceID: workspaceID,
            ops: ops,
            rollback: inverses.reversed(),
            undoEntryID: undoEntryID
        )
    }

    /// Proposta + reconciliação: rejeição do engine desfaz a aplicação otimista —
    /// sem isso, um `node.add` rejeitado viraria nó-fantasma só-local (raiz do
    /// toast "session.start: node_not_found").
    private func propose(_ staged: StagedApply) async throws {
        do {
            _ = try await connection.call(
                .docApply,
                params: DocApplyParams(workspaceID: staged.workspaceID, ops: staged.ops)
            )
        } catch {
            for op in staged.ops { pendingOpIDs.remove(op.opID) }
            if isBenignStaleNodeUpdate(error, staged: staged) {
                // WebKit e o editor de nota podem publicar seu último callback
                // depois de um `node.delete` recebido de outro cliente. O engine é
                // a verdade: remover o espelho local impede novo callback/retry.
                // Esta é a ÚNICA rejeição silenciosa; qualquer outro erro continua
                // indo ao toast e preserva o comportamento de diagnóstico.
                if workspace?.id == staged.workspaceID {
                    for nodeID in staleNodeUpdateIDs(in: staged.ops) {
                        discardLocallyDeletedNode(nodeID)
                    }
                    if let undoEntryID = staged.undoEntryID {
                        undoStack.removeAll { $0.id == undoEntryID }
                    }
                }
                return
            }
            // Não tocar no espelho se a usuária já entrou em outro workspace:
            // a resposta é do canvas antigo e o novo veio de workspace.open.
            if workspace?.id == staged.workspaceID {
                for payload in staged.rollback { apply(payload) }
                if let undoEntryID = staged.undoEntryID {
                    undoStack.removeAll { $0.id == undoEntryID }
                }
            }
            throw error
        }
    }

    private func staleNodeUpdateIDs(in ops: [DocOp]) -> Set<ULID> {
        Set(ops.compactMap { op in
            if case .nodeUpdate(let payload) = op.payload { return payload.id }
            return nil
        })
    }

    private func isBenignStaleNodeUpdate(_ error: Error, staged: StagedApply) -> Bool {
        guard let protocolError = error as? ProtocolError,
              protocolError.known == .node_not_found,
              !staged.ops.isEmpty,
              staleNodeUpdateIDs(in: staged.ops).count == staged.ops.count
        else { return false }
        return true
    }

    private func discardLocallyDeletedNode(_ nodeID: ULID) {
        nodes[nodeID] = nil
        connections = connections.filter { _, connection in
            connection.de != nodeID && connection.para != nodeID
        }
        if selection == nodeID { selection = nil }
        terminalControllers[nodeID]?.detach()
        terminalControllers.removeValue(forKey: nodeID)
        notaControllers.removeValue(forKey: nodeID)
        portalControllers.removeValue(forKey: nodeID)
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        performMany(entry.undoOps, undoable: false)
        redoStack.append(entry)
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        performMany(entry.redoOps, undoable: false)
        undoStack.append(entry)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Inversa calculada do estado corrente ANTES de aplicar (§7.3).
    private func inverse(of payload: OpPayload) -> OpPayload? {
        switch payload {
        case .nodeAdd(let p):
            return .nodeDelete(NodeDeleteOpPayload(id: p.node.id))
        case .nodeMove(let p):
            guard let node = nodes[p.id] else { return nil }
            return .nodeMove(NodeMoveOpPayload(id: p.id, posicao: node.posicao))
        case .nodeResize(let p):
            guard let node = nodes[p.id] else { return nil }
            return .nodeResize(NodeResizeOpPayload(id: p.id, tamanho: node.tamanho))
        case .nodeUpdate(let p):
            guard let node = nodes[p.id], let camposNovos = p.campos.objectValue,
                  let atual = (try? JSONValue(encoding: node))?.objectValue else { return nil }
            var anteriores: [String: JSONValue] = [:]
            for chave in camposNovos.keys {
                anteriores[chave] = atual[chave] ?? .null
            }
            return .nodeUpdate(NodeUpdateOpPayload(id: p.id, campos: .object(anteriores)))
        case .nodeDelete(let p):
            guard let node = nodes[p.id] else { return nil }
            return .nodeAdd(NodeAddOpPayload(node: node))
        case .connectionAdd(let p):
            return .connectionDelete(ConnectionDeleteOpPayload(id: p.connection.id))
        case .connectionDelete(let p):
            guard let conn = connections[p.id] else { return nil }
            return .connectionAdd(ConnectionAddOpPayload(connection: conn))
        case .tracoAdd(let p):
            return .tracoDelete(TracoDeleteOpPayload(nodeID: p.nodeID, tracoID: p.traco.id))
        case .tracoDelete(let p):
            guard case .desenho(let desenho)? = nodes[p.nodeID],
                  let traco = desenho.tracos.first(where: { $0.id == p.tracoID }) else { return nil }
            return .tracoAdd(TracoAddOpPayload(nodeID: p.nodeID, traco: traco))
        case .viewportSet:
            return nil
        case .workspaceRename:
            guard let nome = workspace?.nome else { return nil }
            return .workspaceRename(WorkspaceRenameOpPayload(nome: nome))
        }
    }

    // MARK: - Documento: aplicar no espelho local

    private func apply(_ payload: OpPayload) {
        switch payload {
        case .nodeAdd(let p):
            nodes[p.node.id] = p.node
        case .nodeMove(let p):
            nodes[p.id] = nodes[p.id].map { mutatePosicao($0, p.posicao) }
        case .nodeResize(let p):
            nodes[p.id] = nodes[p.id].map { mutateTamanho($0, p.tamanho) }
        case .nodeUpdate(let p):
            guard let node = nodes[p.id] else { return }
            nodes[p.id] = merged(node: node, campos: p.campos) ?? node
        case .nodeDelete(let p):
            nodes[p.id] = nil
            if selection == p.id { selection = nil }
            terminalControllers[p.id]?.detach()
            terminalControllers.removeValue(forKey: p.id)
            notaControllers.removeValue(forKey: p.id)
            portalControllers.removeValue(forKey: p.id) // solta o WKWebView
        case .connectionAdd(let p):
            connections[p.connection.id] = p.connection
        case .connectionDelete(let p):
            connections[p.id] = nil
        case .tracoAdd(let p):
            guard case .desenho(var desenho)? = nodes[p.nodeID] else { return }
            if !desenho.tracos.contains(where: { $0.id == p.traco.id }) {
                desenho.tracos.append(p.traco)
            }
            nodes[p.nodeID] = .desenho(desenho)
        case .tracoDelete(let p):
            guard case .desenho(var desenho)? = nodes[p.nodeID] else { return }
            desenho.tracos.removeAll { $0.id == p.tracoID }
            nodes[p.nodeID] = .desenho(desenho)
        case .viewportSet(let p):
            viewport = p.viewport
        case .workspaceRename(let p):
            workspace?.nome = p.nome
        }
    }

    private func mutatePosicao(_ node: Node, _ posicao: Ponto) -> Node {
        switch node {
        case .terminal(var n): n.posicao = posicao; return .terminal(n)
        case .nota(var n): n.posicao = posicao; return .nota(n)
        case .desenho(var n): n.posicao = posicao; return .desenho(n)
        case .portal(var n): n.posicao = posicao; return .portal(n)
        }
    }

    private func mutateTamanho(_ node: Node, _ tamanho: Tamanho) -> Node {
        switch node {
        case .terminal(var n): n.tamanho = tamanho; return .terminal(n)
        case .nota(var n): n.tamanho = tamanho; return .nota(n)
        case .desenho(var n): n.tamanho = tamanho; return .desenho(n)
        case .portal(var n): n.tamanho = tamanho; return .portal(n)
        }
    }

    /// Merge raso de `campos` sobre o nó serializado (§7.2 node.update).
    private func merged(node: Node, campos: JSONValue) -> Node? {
        guard var objeto = (try? JSONValue(encoding: node))?.objectValue,
              let novos = campos.objectValue else { return nil }
        for (chave, valor) in novos {
            objeto[chave] = valor
        }
        let data = try? ColmeiaJSON.encoder().encode(JSONValue.object(objeto))
        return data.flatMap { try? ColmeiaJSON.decoder().decode(Node.self, from: $0) }
    }

    // MARK: - Ações de canvas

    func moveNode(_ id: ULID, to posicao: Ponto) {
        guard nodes[id] != nil else { return }
        guard CanvasMath.posicaoSana(posicao) else {
            Self.log.error("node.move rejeitado: posição insana (\(posicao.x), \(posicao.y)) para \(id.string)")
            return
        }
        perform(.nodeMove(NodeMoveOpPayload(id: id, posicao: posicao)))
    }

    func resizeNode(_ id: ULID, to tamanho: Tamanho) {
        guard nodes[id] != nil else { return }
        guard tamanho.w.isFinite, tamanho.h.isFinite,
              tamanho.w <= CanvasMath.limitePosicao, tamanho.h <= CanvasMath.limitePosicao else {
            Self.log.error("node.resize rejeitado: tamanho insano (\(tamanho.w), \(tamanho.h)) para \(id.string)")
            return
        }
        perform(.nodeResize(NodeResizeOpPayload(id: id, tamanho: tamanho)))
    }

    /// Edição inline de texto solto: altera conteúdo e área de hit-test juntos.
    /// A pré-condição local evita o update tardio de uma view desmontada, mas não
    /// mascara rejeições do engine para um nó que a UI ainda enxerga.
    func updateTextoSolto(_ id: ULID, texto: String) {
        guard case .desenho = nodes[id] else {
            Self.log.debug("edição de texto obsoleta descartada para \(id.string)")
            return
        }
        let limpo = texto.trimmingCharacters(in: .newlines)
        guard !limpo.isEmpty else { return }
        performMany([
            .nodeUpdate(NodeUpdateOpPayload(id: id, campos: .object(["texto": .string(limpo)]))),
            .nodeResize(NodeResizeOpPayload(id: id, tamanho: CanvasMath.tamanhoInicialDeTexto(limpo)))
        ])
    }

    // MARK: - Drag de nó (base + translação; ecos ignorados durante o gesto)

    func beginNodeDrag(_ id: ULID) {
        guard let node = nodes[id] else { return }
        draggingNodeID = id
        dragBase = node.posicao
        selection = id
    }

    var nodeDragBase: Ponto? { dragBase }

    /// Atualização local (sem op) durante o gesto — conexões e minimapa seguem o nó.
    func dragNode(_ id: ULID, to posicao: Ponto) {
        guard draggingNodeID == id, CanvasMath.posicaoSana(posicao) else { return }
        nodes[id] = nodes[id].map { mutatePosicao($0, posicao) }
    }

    func endNodeDrag(_ id: ULID, at posicao: Ponto) {
        guard draggingNodeID == id else { return }
        let base = dragBase
        draggingNodeID = nil
        dragBase = nil
        guard let base else { return }
        nodes[id] = nodes[id].map { mutatePosicao($0, base) }
        guard CanvasMath.posicaoSana(posicao) else {
            Self.log.error("drag descartado: destino insano (\(posicao.x), \(posicao.y)) para \(id.string)")
            return
        }
        perform(.nodeMove(NodeMoveOpPayload(id: id, posicao: posicao)))
    }

    func cancelNodeDrag() {
        guard let id = draggingNodeID, let base = dragBase else {
            draggingNodeID = nil
            dragBase = nil
            return
        }
        draggingNodeID = nil
        dragBase = nil
        nodes[id] = nodes[id].map { mutatePosicao($0, base) }
    }

    // MARK: - Conexões pela UI (§5.3)

    func connect(from origem: ULID, to destino: ULID) {
        guard origem != destino, let a = nodes[origem], let b = nodes[destino] else { return }
        let semantica: ConnectionSemantica
        var de = origem
        var para = destino
        switch (a.tipo, b.tipo) {
        case (.terminal, .nota): semantica = .escritaDeNota
        case (.nota, .terminal):
            semantica = .escritaDeNota
            de = destino
            para = origem
        case (.terminal, .terminal): semantica = .conversa
        default: semantica = .visual
        }
        let jaExiste = connections.values.contains {
            $0.semantica == semantica &&
                (($0.de == de && $0.para == para) ||
                    (semantica == .conversa && $0.de == para && $0.para == de))
        }
        if jaExiste {
            aviso("\(nodeName(origem)) e \(nodeName(destino)) já estão conectados")
            return
        }
        var ops: [OpPayload] = []
        if semantica == .escritaDeNota {
            aviso("\(nodeName(de)) conectado a mais uma nota")
        }
        let estilo: ConnectionEstilo = semantica == .escritaDeNota ? .solida : .tracejada
        ops.append(.connectionAdd(ConnectionAddOpPayload(connection: Connection(
            id: ULID.generate(), de: de, para: para, semantica: semantica, estilo: estilo
        ))))
        performMany(ops)
    }

    func deleteConnection(_ id: ULID) {
        guard connections[id] != nil else { return }
        if connectionSelection == id { connectionSelection = nil }
        perform(.connectionDelete(ConnectionDeleteOpPayload(id: id)))
    }

    /// Alvo do drop: nó de maior z cujo retângulo (mundo) contém o ponto.
    func node(atWorldPoint ponto: Ponto, excluindo: ULID? = nil) -> ULID? {
        nodes.values
            .filter { node in
                node.id != excluindo &&
                    CGRect(x: node.posicao.x, y: node.posicao.y, width: node.tamanho.w, height: node.tamanho.h)
                    .contains(CGPoint(x: ponto.x, y: ponto.y))
            }
            .max { ($0.z, $0.id.string) < ($1.z, $1.id.string) }?
            .id
    }

    func aviso(_ texto: String) {
        avisoInfo = texto
        avisoTask?.cancel()
        avisoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.avisoInfo = nil
        }
    }

    /// Abre o único caminho de criação de terminais. O diálogo oferece um nome
    /// único pronto para uso e ainda permite personalizá-lo.
    func presentNewTerminal(adapter: String = KnownAdapter.claudeCode.rawValue) {
        if adapterPodeSerSelecionado(adapter) {
            newTerminalAdapter = adapter
        }
        showNewTerminal = true
    }

    /// Sugestão imediatamente utilizável, mas sempre editável no diálogo.
    /// O menor sufixo livre mantém nomes curtos sem expor ULID ou contador global.
    func suggestedTerminalName(adapter: String) -> String {
        let base: String
        switch KnownAdapter(rawValue: adapter) {
        case .codex: base = "Codex"
        case .opencode: base = "OpenCode"
        case .geminiCli: base = "Gemini"
        case .claudeCode: base = "Claude"
        case .shell: base = "Terminal"
        case nil: base = "Agente"
        }
        let existing = Set(nodes.values.compactMap { node -> String? in
            guard case .terminal(let terminal) = node else { return nil }
            return terminal.nome.lowercased()
        })
        if !existing.contains(base.lowercased()) { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    /// `node.delete` de terminal com sessão viva falha no engine (§7.2); a UI
    /// pergunta antes e mata a sessão primeiro quando confirmado.
    func deleteNode(_ id: ULID) async {
        if let controller = terminalControllers[id], controller.viva {
            let encerrou = await controller.killAndWait()
            guard encerrou else {
                aviso("a sessão ainda está encerrando; tente apagar o nó novamente em instantes")
                return
            }
        }
        do {
            // `node.delete` depende do efeito de `session.kill`: aguardar tanto o
            // state final quanto a response de doc.apply evita a rejeição
            // intermitente `session_already_running` (§6.7/§7.2).
            try await performManyAguardando([.nodeDelete(NodeDeleteOpPayload(id: id))])
        } catch {
            report(error, "node.delete")
        }
    }

    /// Nó + sessão. O `session.start` SÓ dispara depois de o `doc.apply` do node.add
    /// ser CONFIRMADO pelo engine (§7.1/§9.1) — nunca um start órfão com node_id que
    /// o engine não conhece. O nome sempre vem do diálogo de criação; não há
    /// fallback automático que exponha números ou IDs como identidade do agente.
    func addTerminal(
        nome: String,
        papel: String?,
        adapter: String,
        comandoOverride: String?,
        cwd: String,
        monitorarAtividade: Bool
    ) async {
        guard let ws = workspace else { return }
        let nomeLimpo = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nomeLimpo.isEmpty else {
            aviso("Informe um nome para criar o terminal")
            return
        }
        if nodes.values.contains(where: { node in
            if case .terminal(let terminal) = node {
                return terminal.nome.caseInsensitiveCompare(nomeLimpo) == .orderedSame
            }
            return false
        }) {
            aviso("Já existe um terminal com esse nome. Escolha outro.")
            return
        }
        guard adapterPodeSerSelecionado(adapter) else {
            aviso(motivoAdapterIndisponivel(adapter))
            return
        }
        let floorAtCreation = activeFloor
        let tamanho = Tamanho(w: 640, h: 420)
        let node = TerminalNode(
            id: ULID.generate(),
            posicao: centerPosition(for: tamanho),
            tamanho: tamanho,
            z: nextZ(),
            criadoEm: Date(),
            nome: nomeLimpo,
            papel: papel?.isEmpty == true ? nil : papel,
            adapter: adapter,
            comandoOverride: comandoOverride?.isEmpty == true ? nil : comandoOverride,
            cwd: floorAtCreation?.caminho ?? cwd,
            monitorarAtividade: monitorarAtividade
        )
        do {
            try await performManyAguardando([.nodeAdd(NodeAddOpPayload(node: .terminal(node)))])
        } catch {
            report(error, "node.add")
            return
        }
        selection = node.id
        let controller = terminalController(for: node.id)
        do {
            try await controller.start(
                workspaceID: ws.id,
                floorID: floorAtCreation?.id)
        } catch {
            report(error, "session.start")
        }
    }

    func setTerminalFontSize(nodeID: ULID, size: Double) {
        guard case .terminal(let terminal)? = nodes[nodeID] else { return }
        let normalized = Double(TerminalAppearance.tamanhoNormalizado(size))
        var aparencia = terminal.aparencia ?? Aparencia()
        aparencia.tamanhoFonte = normalized
        guard let campos = try? JSONValue(encoding: ["aparencia": aparencia]) else { return }
        terminalControllers[nodeID]?.applyFontSize(normalized)
        perform(.nodeUpdate(NodeUpdateOpPayload(id: nodeID, campos: campos)))
    }

    func addNota(cor preferida: String? = nil) {
        guard workspace != nil else { return }
        let id = ULID.generate()
        let node = NotaNode(
            id: id,
            posicao: centerPosition(for: Tamanho(w: 320, h: 240)),
            tamanho: Tamanho(w: 320, h: 240),
            z: nextZ(),
            criadoEm: Date(),
            arquivo: "notes/\(id.string).md",
            cor: preferida ?? Self.noteColorForAuthor(Author.humano(InstallationIdentity.current().string).rawValue)
        )
        perform(.nodeAdd(NodeAddOpPayload(node: .nota(node))))
        selection = id
    }

    /// Cor estável por pessoa: cada colaborador nasce com uma nota visualmente distinta.
    static func noteColorForAuthor(_ authorID: String) -> String {
        let palette = ["amarelo", "rosa", "verde", "azul", "roxo"]
        let hash = authorID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }

    /// Novo portal no centro da viewport. URL vazia abre o DuckDuckGo; texto sem
    /// esquema pode virar busca. Criação pela UI é `node.add` comum — o método
    /// `portal.open` (validação http/https) é a via de CLI/agentes.
    func addPortal(url bruto: String?) {
        guard workspace != nil else { return }
        let url = bruto.flatMap(PortalURL.normalizar) ?? PortalURL.paginaInicial
        let tamanho = Tamanho(w: 720, h: 520)
        let node = PortalNode(
            id: ULID.generate(),
            posicao: centerPosition(for: tamanho),
            tamanho: tamanho,
            z: nextZ(),
            criadoEm: Date(),
            url: url
        )
        perform(.nodeAdd(NodeAddOpPayload(node: .portal(node))))
        selection = node.id
    }

    func relaunch(nodeID: ULID) async {
        guard let ws = workspace else { return }
        let controller = terminalController(for: nodeID)
        let floorID = floors.first {
            $0.estado == .ativo && $0.nos.contains(nodeID)
        }?.id
        do {
            try await controller.start(workspaceID: ws.id, floorID: floorID)
        } catch {
            report(error, "session.start (relançar)")
        }
    }

    /// Troca o adapter/modelo do mesmo agente sem criar outro nó. A sessão antiga
    /// é encerrada, o nó conserva identidade, papel, conexões e workspace, e a
    /// atividade recente é enviada como handoff para o novo adapter.
    func switchAgentAdapter(nodeID: ULID, to adapter: String) async {
        guard let ws = workspace,
              case .terminal(let terminal)? = nodes[nodeID] else { return }
        guard terminal.adapter != adapter else { return }
        guard adapterPodeSerSelecionado(adapter) else {
            aviso(motivoAdapterIndisponivel(adapter))
            return
        }

        let controller = terminalController(for: nodeID)
        let atividadeRecente = controller.linhasRecentes.suffix(8).joined(separator: "\n")
        if controller.viva {
            guard await controller.killAndWait() else {
                aviso("O agente ainda está encerrando. Tente trocar o modelo novamente em instantes.")
                return
            }
        }

        do {
            let campos: JSONValue = .object(["adapter": .string(adapter), "modelo": .null])
            try await performManyAguardando([
                .nodeUpdate(NodeUpdateOpPayload(id: nodeID, campos: campos))
            ], undoable: false)

            let floorID = floors.first {
                $0.estado == .ativo && $0.nos.contains(nodeID)
            }?.id
            try await controller.start(workspaceID: ws.id, floorID: floorID)

            if adapter != KnownAdapter.shell.rawValue {
                let contexto = atividadeRecente.isEmpty ? "(sem saída recente registrada)" : atividadeRecente
                controller.sendCommand("""
                You are taking over an existing Colmeia agent session.
                Keep the same identity, workspace, role, files, and task context. Continue from the recent activity below; do not restart the project or repeat completed work.
                Previous adapter: \(terminal.adapter)
                Agent: \(terminal.nome)
                Role: \(terminal.papel ?? "not specified")
                Recent activity:
                \(contexto)
                Acknowledge the handoff briefly, then wait for the next instruction.
                """)
            }
            avisoInfo = "\(terminal.nome) agora usa \(adapter). O contexto recente foi enviado como handoff."
        } catch {
            report(error, "agent.adapter.switch")
        }
    }

    /// Altera o modelo dentro do mesmo runtime. Para o Codex, a retomada usa a
    /// sessão isolada do agente, mantendo a conversa; só o modelo do próximo
    /// turno muda.
    func switchAgentModel(nodeID: ULID, to modelo: String?) async {
        guard let ws = workspace,
              case .terminal(let terminal)? = nodes[nodeID] else { return }
        guard terminal.adapter == KnownAdapter.codex.rawValue else {
            aviso("A seleção de modelo no Agent Chat está disponível para Codex.")
            return
        }
        let normalized = modelo?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelFinal = normalized?.isEmpty == true ? nil : normalized
        guard terminal.modelo != modelFinal else { return }

        let controller = terminalController(for: nodeID)
        if controller.viva {
            let didStop = await controller.killAndWait()
            if !didStop {
                aviso("O agente ainda está encerrando. Tente mudar o modelo novamente em instantes.")
                return
            }
        }
        do {
            let campos = try JSONValue(encoding: ["modelo": modelFinal])
            try await performManyAguardando([
                .nodeUpdate(NodeUpdateOpPayload(id: nodeID, campos: campos))
            ], undoable: false)
            let floorID = floors.first {
                $0.estado == .ativo && $0.nos.contains(nodeID)
            }?.id
            try await controller.start(workspaceID: ws.id, floorID: floorID)
            avisoInfo = "\(terminal.nome) agora usa \(modelFinal ?? "o modelo padrão do Codex"). A conversa do agente foi retomada."
        } catch {
            report(error, "agent.model.switch")
        }
    }

    private func nextZ() -> Int {
        (nodes.values.map(\.z).max() ?? 0) + 1
    }

    private func centerPosition(for tamanho: Tamanho) -> Ponto {
        Ponto(
            x: viewport.x + Double(canvasSize.width) / (2 * viewport.zoom) - tamanho.w / 2,
            y: viewport.y + Double(canvasSize.height) / (2 * viewport.zoom) - tamanho.h / 2
        )
    }

    // MARK: - Viewport (fora do undo, throttled §7.2)

    func setViewport(_ novo: Viewport) {
        var clamped = novo
        clamped.zoom = min(max(novo.zoom, Viewport.zoomRange.lowerBound), Viewport.zoomRange.upperBound)
        viewport = clamped
        scheduleViewportPersist()
    }

    /// Pan por delta de TELA (scroll/drag) — dividir pelo zoom converte para mundo.
    func panBy(telaDX: Double, telaDY: Double) {
        guard telaDX.isFinite, telaDY.isFinite else { return }
        var v = viewport
        v.x -= telaDX / v.zoom
        v.y -= telaDY / v.zoom
        setViewport(v)
    }

    /// Zoom multiplicativo. Sem âncora explícita ancora no CENTRO da viewport
    /// (⌘+/⌘− do menu); gesto/scroll passam a âncora = posição do cursor em TELA
    /// (coordenadas do canvas, topo-esquerda) — §18.2 navegação universal.
    func zoom(by factor: Double, ancoraTela: Ponto? = nil) {
        setViewport(CanvasMath.zoomAncorado(
            viewport: viewport, fator: factor, ancoraTela: ancoraTela ?? centroDaTela))
    }

    /// Zoom absoluto ancorado (âncora default = centro da viewport).
    func zoomTo(_ zoomAlvo: Double, ancoraTela: Ponto? = nil) {
        setViewport(CanvasMath.zoomAncorado(
            viewport: viewport, zoomAlvo: zoomAlvo, ancoraTela: ancoraTela ?? centroDaTela))
    }

    /// ⌘0 — 100% ancorado no centro da viewport (antes ancorava na origem e o
    /// conteúdo "pulava" para longe do que a usuária estava olhando).
    func zoomReset() {
        zoomTo(1.0)
    }

    private var centroDaTela: Ponto {
        Ponto(x: Double(canvasSize.width) / 2, y: Double(canvasSize.height) / 2)
    }

    private func scheduleViewportPersist() {
        guard viewportTask == nil else { return }
        viewportTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self else { return }
            self.viewportTask = nil
            guard let workspace = self.workspace else { return }
            if let floor = self.activeFloor {
                // Persistência própria do andar: uma troca idempotente para o
                // mesmo floor salva a câmera sem contaminar o viewport do térreo.
                _ = try? await self.connection.call(
                    .floorSwitch,
                    params: FloorSwitchParams(
                        workspaceID: workspace.id,
                        floorID: floor.id,
                        viewport: self.viewport),
                    expecting: FloorSwitchResult.self)
            } else {
                self.perform(
                    .viewportSet(ViewportSetOpPayload(viewport: self.viewport)),
                    undoable: false)
            }
        }
    }

    func focus(nodeID: ULID) {
        guard let node = nodes[nodeID] else { return }
        selection = nodeID
        var v = viewport
        v.x = node.posicao.x + node.tamanho.w / 2 - Double(canvasSize.width) / (2 * v.zoom)
        v.y = node.posicao.y + node.tamanho.h / 2 - Double(canvasSize.height) / (2 * v.zoom)
        setViewport(v)
    }

    func focus(sessionID: ULID) {
        if let nodeID = node(bySession: sessionID) {
            focus(nodeID: nodeID)
        }
    }

    /// Centraliza a visão Atenção nos agentes que realmente exigem uma ação.
    /// O modo pode ter dezenas de nós fora da câmera atual; contar esses nós
    /// sem reposicionar a câmera fazia a UI mostrar o alerta, mas não o cartão.
    func focusAttention() {
        let attentionNodes = nodes.values.filter {
            nodeIsVisibleOnActiveFloor($0.id) && matchesCanvasViewMode($0)
        }

        guard !attentionNodes.isEmpty else {
            if let approval = pendingApprovals.first {
                focus(sessionID: approval.sessionID)
            }
            return
        }
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }

        let bounds = attentionNodes.reduce(CGRect.null) { result, node in
            result.union(CGRect(
                x: node.posicao.x,
                y: node.posicao.y,
                width: node.tamanho.w,
                height: node.tamanho.h))
        }.insetBy(dx: -120, dy: -120)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let availableWidth = max(1, Double(canvasSize.width) - 80)
        let availableHeight = max(1, Double(canvasSize.height) - 80)
        var next = viewport
        next.zoom = min(
            Viewport.zoomRange.upperBound,
            max(
                Viewport.zoomRange.lowerBound,
                min(availableWidth / bounds.width, availableHeight / bounds.height)
            )
        )
        next.x = bounds.midX - Double(canvasSize.width) / (2 * next.zoom)
        next.y = bounds.midY - Double(canvasSize.height) / (2 * next.zoom)
        selection = nil
        setViewport(next)
    }

    // MARK: - Desenho (§15.2)

    /// Traço termina no DesenhoNode sob o primeiro ponto; sem nó ali, cria uma
    /// "camada de rabisco" implícita cobrindo o traço (§15.2, PODE).
    func finishStroke(worldPoints: [Ponto], tipo: TracoTipo, texto: String? = nil) {
        guard !worldPoints.isEmpty else { return }
        let pontos: [Ponto]
        switch tipo {
        case .livre:
            guard worldPoints.count >= 2 else { return }
            pontos = worldPoints
        case .seta, .retangulo, .elipse:
            guard worldPoints.count >= 2 else { return }
            pontos = [worldPoints.first!, worldPoints.last!]
        case .texto:
            pontos = [worldPoints.first!]
        }

        // Texto não é um cartão de desenho: é um nó compacto com uma única ação
        // `.texto`, sem fundo/borda. O lote cria conteúdo + hit area de uma vez,
        // evitando o antigo node.add → node.update tardio.
        if tipo == .texto {
            let conteudo = (texto ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !conteudo.isEmpty else { return }
            let novo = DesenhoNode(
                id: ULID.generate(),
                posicao: pontos[0],
                tamanho: CanvasMath.tamanhoInicialDeTexto(conteudo),
                z: nextZ(),
                criadoEm: Date(),
                texto: conteudo
            )
            let traco = Traco(
                id: ULID.generate(), pontos: [Ponto(x: 0, y: 0)],
                espessura: espessuraTraco, cor: corTraco, tipo: .texto
            )
            performMany([
                .nodeAdd(NodeAddOpPayload(node: .desenho(novo))),
                .tracoAdd(TracoAddOpPayload(nodeID: novo.id, traco: traco))
            ])
            selection = novo.id
            return
        }

        let alvo = nodes.values.first { node in
            guard case .desenho = node else { return false }
            return CGRect(x: node.posicao.x, y: node.posicao.y, width: node.tamanho.w, height: node.tamanho.h)
                .contains(CGPoint(x: pontos[0].x, y: pontos[0].y))
        }

        let nodeID: ULID
        let origem: Ponto
        if let alvo, tipo != .texto || nodeTexto(alvo.id) == nil {
            nodeID = alvo.id
            origem = alvo.posicao
        } else {
            let minX = pontos.map(\.x).min()! - 30
            let minY = pontos.map(\.y).min()! - 30
            let maxX = pontos.map(\.x).max()! + 30
            let maxY = pontos.map(\.y).max()! + 30
            let novo = DesenhoNode(
                id: ULID.generate(),
                posicao: Ponto(x: minX, y: minY),
                tamanho: Tamanho(w: max(80, maxX - minX), h: max(60, maxY - minY)),
                z: nextZ(),
                criadoEm: Date(),
                texto: tipo == .texto ? texto : nil
            )
            perform(.nodeAdd(NodeAddOpPayload(node: .desenho(novo))))
            nodeID = novo.id
            origem = novo.posicao
        }

        let relativos = pontos.map { Ponto(x: $0.x - origem.x, y: $0.y - origem.y) }
        let traco = Traco(id: ULID.generate(), pontos: relativos, espessura: espessuraTraco, cor: corTraco, tipo: tipo)
        perform(.tracoAdd(TracoAddOpPayload(nodeID: nodeID, traco: traco)))
    }

    func deleteUltimoTraco(nodeID: ULID) {
        guard case .desenho(let desenho)? = nodes[nodeID], let ultimo = desenho.tracos.last else { return }
        perform(.tracoDelete(TracoDeleteOpPayload(nodeID: nodeID, tracoID: ultimo.id)))
    }

    private func nodeTexto(_ id: ULID) -> String? {
        if case .desenho(let d)? = nodes[id] { return d.texto }
        return nil
    }

    // MARK: - Andares (§18.5)

    /// Camadas do canvas: no térreo, nós de andares ficam ocultos; dentro de um
    /// andar, seus nós ficam normais e os nós-base permanecem visíveis atenuados.
    /// Nós pertencentes a outros andares não vazam para a camada ativa.
    func floorOpacity(for nodeID: ULID) -> Double {
        let owner = floors.first { $0.nos.contains(nodeID) }
        guard let activeFloor else {
            return owner == nil ? 1 : 0
        }
        if owner?.id == activeFloor.id { return 1 }
        if owner != nil { return 0 }
        return 0.28
    }

    func nodeIsVisibleOnActiveFloor(_ nodeID: ULID) -> Bool {
        floorOpacity(for: nodeID) > 0
    }

    func refreshFloors() async {
        guard let ws = workspace else { return }
        floors = (try? await connection.call(
            .floorList,
            params: FloorListParams(workspaceID: ws.id),
            expecting: FloorListResult.self
        )) ?? []
        if let ativo = activeFloor, let atualizado = floors.first(where: { $0.id == ativo.id }) {
            activeFloor = atualizado.estado == .ativo ? atualizado : nil
        }
    }

    @discardableResult
    func createFloor(nome: String, branch: String?) async -> Bool {
        guard let ws = workspace else { return false }
        do {
            let result = try await connection.call(
                .floorCreate,
                params: FloorCreateParams(workspaceID: ws.id, nome: nome, branch: branch),
                expecting: FloorResult.self
            )
            floors.append(result.floor)
            return await switchFloor(result.floor)
        } catch {
            report(error, "floor.create")
            return false
        }
    }

    @discardableResult
    func switchFloor(_ floor: Floor?) async -> Bool {
        guard let ws = workspace else { return false }
        viewportTask?.cancel()
        viewportTask = nil
        let viewportSaindo = viewport
        do {
            let result = try await connection.call(
                .floorSwitch,
                params: FloorSwitchParams(
                    workspaceID: ws.id,
                    floorID: floor?.id,
                    viewport: viewportSaindo),
                expecting: FloorSwitchResult.self
            )
            activeFloor = result.floor
            // Atribuição direta: o engine acabou de persistir o contexto anterior;
            // não agendar uma escrita do viewport restaurado no contexto novo.
            viewport = result.floor?.viewport ?? ws.viewport
            return true
        } catch {
            report(error, "floor.switch")
            return false
        }
    }

    func landFloor(_ floor: Floor) async {
        do {
            _ = try await connection.call(.floorLand, params: FloorLandParams(floorID: floor.id, confirmar: true))
            activeFloor = nil
            if let workspace { viewport = workspace.viewport }
            await refreshFloors()
        } catch {
            report(error, "floor.land")
        }
    }

    func discardFloor(_ floor: Floor) async {
        do {
            _ = try await connection.call(.floorDiscard, params: FloorDiscardParams(floorID: floor.id, confirmar: true))
            activeFloor = nil
            if let workspace { viewport = workspace.viewport }
            await refreshFloors()
        } catch {
            report(error, "floor.discard")
        }
    }

    // MARK: - Aprovações

    func resolve(approval: Approval, decisao: ApprovalDecisao, opcaoIndex: Int?) async {
        do {
            let result = try await connection.call(
                .approvalResolve,
                params: ApprovalResolveParams(approvalID: approval.id, decisao: decisao, opcaoIndex: opcaoIndex),
                expecting: ApprovalResult.self
            )
            upsert(approval: result.approval)
        } catch {
            report(error, "approval.resolve")
        }
    }

    private func upsert(approval: Approval) {
        if let index = approvals.firstIndex(where: { $0.id == approval.id }) {
            approvals[index] = approval
        } else {
            approvals.append(approval)
        }
    }

    // MARK: - Eventos do engine

    private func handle(event: EventMessage) {
        // Operações remotas de documento podem chegar em rajadas (drag remoto,
        // replay ou sync). Coalescer o ciclo de UI evita uma invalidação por
        // evento; a ordem do Engine continua preservada dentro do batch.
        if event.knownTopic == .documentOp {
            pendingCanvasEvents.append(event)
            scheduleCanvasEventFlush()
            return
        }
        handleImmediately(event: event)
    }

    private func scheduleCanvasEventFlush() {
        guard canvasEventFlushTask == nil else { return }
        canvasEventFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.flushCanvasEvents()
        }
    }

    private func flushCanvasEvents() {
        canvasEventFlushTask = nil
        let events = pendingCanvasEvents
        pendingCanvasEvents.removeAll(keepingCapacity: true)
        for event in events {
            handleImmediately(event: event)
        }
    }

    private func handleImmediately(event: EventMessage) {
        guard let topic = event.knownTopic else { return }
        switch topic {
        case .sessionOutput:
            break
        case .sessionState:
            guard let payload = try? event.decodeParams(SessionStateTopicPayload.self) else { return }
            let resolvedNodeID = payload.nodeID
                ?? node(bySession: payload.sessionID)
                ?? nodes.values.compactMap { node -> ULID? in
                    guard case .terminal(let t) = node else { return nil }
                    return t.sessionID == payload.sessionID ? t.id : nil
                }.first
            guard let nodeID = resolvedNodeID, case .terminal = nodes[nodeID] else { return }
            let controller = terminalController(for: nodeID)
            if controller.sessionID != payload.sessionID {
                guard let sessionWorkspaceID = payload.workspaceID ?? workspace?.id else { return }
                let stub = Session(
                    id: payload.sessionID,
                    workspaceID: sessionWorkspaceID,
                    nodeID: nodeID,
                    adapter: {
                        if case .terminal(let t) = nodes[nodeID] { return t.adapter }
                        return "shell"
                    }(),
                    estado: payload.estado,
                    iniciadaEm: Date(),
                    cols: 80,
                    rows: 24
                )
                controller.adopt(session: stub)
                if payload.estado.isViva {
                    Task { await controller.attach() }
                }
            } else {
                controller.updateEstado(payload.estado, motivo: payload.motivo)
            }
            if payload.estado == .morta {
                notifications.notifySessaoMorta(
                    node: nodeName(nodeID),
                    nodeID: nodeID,
                    motivo: payload.motivo,
                    destination: notificationDestination(nodeID: nodeID))
            }
        case .documentOp:
            guard let payload = try? event.decodeParams(DocumentOpTopicPayload.self),
                  payload.workspaceID == workspace?.id else { return }
            if pendingOpIDs.remove(payload.op.opID) != nil { return }
            if case .viewportSet = payload.op.payload { return }
            if case .nodeMove(let move) = payload.op.payload {
                if move.id == draggingNodeID { return }
                guard CanvasMath.posicaoSana(move.posicao) else {
                    Self.log.error("eco node.move ignorado: posição insana para \(move.id.string)")
                    return
                }
            }
            apply(payload.op.payload)
        case .approvalCreated:
            guard let payload = try? event.decodeParams(ApprovalTopicPayload.self) else { return }
            upsert(approval: payload.approval)
            Task { await refreshDelegations() }
            let nodeID = node(bySession: payload.approval.sessionID)
            notifications.notifyAprovacao(
                payload.approval,
                nodeID: nodeID,
                destination: notificationDestination(nodeID: nodeID))
        case .approvalResolved:
            guard let payload = try? event.decodeParams(ApprovalTopicPayload.self) else { return }
            upsert(approval: payload.approval)
            Task { await refreshDelegations() }
        case .noteAppended:
            guard let payload = try? event.decodeParams(NoteAppendedTopicPayload.self) else { return }
            notaControllers[payload.nodeID]?.reloadFromDisk()
        case .missionChanged, .workstreamChanged:
            applyRemoteMissionEvent(event)
        case .decisionChanged:
            // A decisão pode ser compartilhada sem carregar payload privado
            // para todos os clientes; a leitura canônica atualiza a fila Agora.
            Task { await refreshDecisions() }
        case .roomLayoutChanged:
            applyRemoteSemanticLayoutEvent(event)
        case .routineFired:
            guard let payload = try? event.decodeParams(RoutineFiredTopicPayload.self) else { return }
            if let routine = routines.first(where: { $0.id == payload.routineID }), routine.notificar {
                notifications.notifyRotina(
                    routine,
                    resultado: payload.resultado,
                    destination: notificationDestination(nodeID: routine.alvo))
            }
            Task { await refreshRoutines() }
        case .floorChanged:
            if let payload = try? event.decodeParams(FloorChangedTopicPayload.self),
               payload.floor.estado == .orfao {
                notifications.notifyAndarOrfao(
                    nome: payload.floor.nome,
                    destination: NotificationDestination(
                        workspaceID: payload.floor.origem,
                        floorID: payload.floor.id))
            }
            Task { await refreshFloors() }
        case .memoryChanged:
            guard let payload = try? event.decodeParams(MemoryChangedTopicPayload.self),
                  payload.workspaceID == workspace?.id else { return }
            if let memory = payload.memory { self.memory = memory }
            if let proposal = payload.proposal { upsert(memoryProposal: proposal) }
            // Histórico/briefing não trafegam no evento para evitar conteúdo
            // desnecessário; a leitura canônica é atualizada em segundo plano.
            Task { await refreshMemory() }
        case .deliveryChanged:
            guard let payload = try? event.decodeParams(DeliveryChangedTopicPayload.self),
                  payload.delivery.workspaceID == workspace?.id else { return }
            let wasKnown = deliveries.contains(where: { $0.id == payload.delivery.id })
            upsert(delivery: payload.delivery)
            if !wasKnown {
                notifications.notifyEntrega(
                    resumo: payload.delivery.resumo,
                    destination: notificationDestination(nodeID: node(bySession: payload.delivery.sessionID)))
            }
        case .watchdogAlert:
            guard let payload = try? event.decodeParams(WatchdogAlertTopicPayload.self),
                  payload.workspaceID == workspace?.id else { return }
            if !watchdogAlerts.contains(where: {
                $0.sessionID == payload.sessionID && $0.episode == payload.episode && $0.kind == payload.kind
            }) {
                watchdogAlerts.append(payload)
                if watchdogAlerts.count > 100 { watchdogAlerts.removeFirst(watchdogAlerts.count - 100) }
            }
        case .workerArchived:
            guard let payload = try? event.decodeParams(WorkerArchivedTopicPayload.self),
                  payload.workspaceID == workspace?.id else { return }
            upsert(workerArchive: payload.tombstone)
        case .messageDelivered:
            guard let payload = try? event.decodeParams(MessageDeliveredTopicPayload.self) else { return }
            upsert(agentMessage: AgentMessageSummary(
                id: payload.messageID,
                de: payload.de,
                para: payload.para,
                texto: payload.texto,
                deliveredAt: Date(),
                isHuman: false,
                attachments: []))
        case .engineWarning:
            if let payload = try? event.decodeParams(EngineWarningTopicPayload.self) {
                lastError = "engine: \(payload.name) — \(payload.message)"
            }
        case .sessionEventAppended:
            guard let payload = try? event.decodeParams(SessionEventAppendedTopicPayload.self) else { return }
            if let texto = payload.event.payload.texto,
               let data = texto.data(using: .utf8),
               let docOp = try? ColmeiaJSON.decoder().decode(DocOp.self, from: data) {
                if pendingOpIDs.remove(docOp.opID) != nil { return }
                apply(docOp.payload)
            }
        case .memberJoined, .memberLeft, .memberUpdated:
            break
        case .roomUpdated:
            Task { await refreshMissions() }
        case .presenceChanged:
            break
        case .eventAck, .eventReject, .grantIssued, .grantRevoked,
             .leaseAcquired, .leaseRevoked, .handoffRequested,
             .handoffAccepted, .conductorChanged:
            break
        }
    }

    private func agentMessageSummary(_ message: ChatMessage) -> AgentMessageSummary {
        AgentMessageSummary(
            id: message.id,
            de: message.fromNodeID ?? message.toNodeID,
            para: message.toNodeID,
            texto: message.text,
            deliveredAt: message.createdAt,
            isHuman: message.fromNodeID == nil,
            attachments: message.attachments)
    }

    private func upsert(agentMessage: AgentMessageSummary) {
        if let index = agentMessages.firstIndex(where: { $0.id == agentMessage.id }) {
            agentMessages[index] = agentMessage
        } else {
            agentMessages.append(agentMessage)
            agentMessages.sort { lhs, rhs in
                lhs.deliveredAt == rhs.deliveredAt ? lhs.id < rhs.id : lhs.deliveredAt < rhs.deliveredAt
            }
            if agentMessages.count > 200 { agentMessages.removeFirst(agentMessages.count - 200) }
        }
    }

    func nodeName(_ nodeID: ULID) -> String {
        if case .terminal(let t)? = nodes[nodeID] { return t.nome }
        return nodeID.string
    }

    private func notificationDestination(nodeID: ULID?) -> NotificationDestination {
        let owner = nodeID.flatMap { id in floors.first { $0.nos.contains(id) } }
        return NotificationDestination(
            workspaceID: workspace?.id,
            floorID: owner?.id,
            nodeID: nodeID)
    }

    private func report(_ error: Error, _ contexto: String) {
        if error is SocketClientError { return }
        // O banner é para a pessoa; método do protocolo, § de spec e texto cru
        // do processo permanecem no log para diagnóstico.
        Self.log.error("falha técnica [\(contexto)]: \(String(describing: error))")
        lastError = mensagemAmigavel(para: error, contexto: contexto)
    }

    private func mensagemAmigavel(para error: Error, contexto: String) -> String {
        let relancando = contexto.contains("relançar")
        let acao = relancando ? "relançar o terminal" : "iniciar o terminal"

        if contexto.hasPrefix("session.start") {
            if let protocolError = error as? ProtocolError {
                switch protocolError.known {
                case .adapter_launch_failed:
                    return "Não foi possível \(acao): esse app não está instalado neste Mac."
                case .adapter_not_found:
                    return "Não foi possível \(acao): esse tipo de terminal não está disponível."
                case .session_already_running:
                    return "Esse terminal já está em execução."
                case .node_not_found:
                    return "Esse terminal não existe mais neste projeto."
                default:
                    break
                }
            }
            return "Não foi possível \(acao). Tente novamente."
        }

        if let protocolError = error as? ProtocolError {
            switch protocolError.known {
            case .duplicate_node_name:
                return "Já existe um terminal com esse nome. Escolha outro."
            case .workspace_not_found:
                return "Este projeto não está mais disponível."
            case .session_not_found:
                return "A sessão não está mais disponível."
            default:
                break
            }
        }
        return "Não foi possível concluir esta ação. Tente novamente."
    }
}
