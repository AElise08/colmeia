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
    @Published private(set) var routines: [Routine] = []
    @Published var viewport = Viewport()
    @Published var selection: ULID?
    @Published var connectionSelection: ULID?
    @Published var conexaoPendente: ConexaoPendente?
    @Published var lastError: String?
    @Published var avisoInfo: String?
    @Published var showNewTerminal = false
    @Published var showNewPortal = false
    @Published var showApprovals = false
    @Published var showRoutines = false

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
    private var viewportTask: Task<Void, Never>?
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

    // MARK: - Sincronização pós-(re)conexão

    private func resync() async {
        await refreshWorkspaces()
        if let ws = workspace {
            await open(workspaceID: ws.id, restoreViewport: false)
        } else if let saved = UserDefaults.standard.string(forKey: Self.lastWorkspaceKey),
                  let id = ULID(saved), workspaces.contains(where: { $0.id == id }) {
            await open(workspaceID: id)
        } else if let first = workspaces.first {
            await open(workspaceID: first.id)
        }
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

    func open(workspaceID: ULID, restoreViewport: Bool = true) async {
        do {
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
            selection = nil
            connectionSelection = nil
            conexaoPendente = nil
            draggingNodeID = nil
            dragBase = nil

            workspace = result.workspace
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
            await refreshRoutines()
            await refreshFloors()
        } catch {
            report(error, "workspace.open")
        }
    }

    func renameWorkspace(_ nome: String) {
        guard workspace != nil else { return }
        perform(.workspaceRename(WorkspaceRenameOpPayload(nome: nome)))
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

    func refreshRoutines() async {
        guard let ws = workspace else { return }
        routines = (try? await connection.call(
            .routineList,
            params: RoutineListParams(workspaceID: ws.id),
            expecting: RoutineListResult.self
        )) ?? []
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
        performMany([payload], undoable: undoable)
    }

    /// Vários payloads em UM `doc.apply` — o engine aplica em ordem na mesma request,
    /// evitando corrida entre Tasks (ex.: substituir conexão = delete + add).
    func performMany(_ payloads: [OpPayload], undoable: Bool = true) {
        guard workspace != nil, !payloads.isEmpty else { return }
        let staged = stageOptimistic(payloads, undoable: undoable)
        Task {
            do {
                try await propose(staged)
            } catch {
                self.report(error, "doc.apply \(payloads.map(\.tipo.rawValue).joined(separator: ","))")
            }
        }
    }

    /// Como `performMany`, mas AGUARDA a response do engine e rethrowa a rejeição —
    /// para fluxos que dependem da op EXISTIR no engine antes do próximo passo
    /// (ex.: node.add → session.start, §7.1/§9.1). Rejeição desfaz o otimista.
    func performManyAguardando(_ payloads: [OpPayload], undoable: Bool = true) async throws {
        guard workspace != nil, !payloads.isEmpty else { return }
        let staged = stageOptimistic(payloads, undoable: undoable)
        try await propose(staged)
    }

    private struct StagedApply {
        let ops: [DocOp]
        /// Inversas (na ordem de desfazer) para reverter a aplicação otimista.
        let rollback: [OpPayload]
        let undoEntryID: ULID?
    }

    /// Aplica otimista no espelho local, registra undo e devolve o necessário
    /// para propor ao engine e reverter se ele rejeitar.
    private func stageOptimistic(_ payloads: [OpPayload], undoable: Bool) -> StagedApply {
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
        return StagedApply(ops: ops, rollback: inverses.reversed(), undoEntryID: undoEntryID)
    }

    /// Proposta + reconciliação: rejeição do engine desfaz a aplicação otimista —
    /// sem isso, um `node.add` rejeitado viraria nó-fantasma só-local (raiz do
    /// toast "session.start: node_not_found").
    private func propose(_ staged: StagedApply) async throws {
        guard let ws = workspace else { return }
        do {
            _ = try await connection.call(.docApply, params: DocApplyParams(workspaceID: ws.id, ops: staged.ops))
        } catch {
            for op in staged.ops { pendingOpIDs.remove(op.opID) }
            for payload in staged.rollback { apply(payload) }
            if let undoEntryID = staged.undoEntryID {
                undoStack.removeAll { $0.id == undoEntryID }
            }
            throw error
        }
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
        switch (a.tipo, b.tipo) {
        case (.terminal, .nota): semantica = .escritaDeNota
        case (.terminal, .terminal): semantica = .conversa
        default: semantica = .visual
        }
        let jaExiste = connections.values.contains {
            $0.semantica == semantica &&
                (($0.de == origem && $0.para == destino) ||
                    (semantica == .conversa && $0.de == destino && $0.para == origem))
        }
        if jaExiste {
            aviso("\(nodeName(origem)) e \(nodeName(destino)) já estão conectados")
            return
        }
        var ops: [OpPayload] = []
        if semantica == .escritaDeNota,
           let anterior = connections.values.first(where: { $0.semantica == .escritaDeNota && $0.de == origem }) {
            ops.append(.connectionDelete(ConnectionDeleteOpPayload(id: anterior.id)))
            aviso("conexão de nota de \(nodeName(origem)) substituída")
        } else if semantica == .escritaDeNota {
            aviso("\(nodeName(origem)) agora escreve nesta nota (colmeia note)")
        }
        let estilo: ConnectionEstilo = semantica == .escritaDeNota ? .solida : .tracejada
        ops.append(.connectionAdd(ConnectionAddOpPayload(connection: Connection(
            id: ULID.generate(), de: origem, para: destino, semantica: semantica, estilo: estilo
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

    /// `node.delete` de terminal com sessão viva falha no engine (§7.2); a UI
    /// pergunta antes e mata a sessão primeiro quando confirmado.
    func deleteNode(_ id: ULID) async {
        if let controller = terminalControllers[id], controller.viva {
            await controller.kill()
        }
        perform(.nodeDelete(NodeDeleteOpPayload(id: id)))
    }

    /// Nó + sessão. O `session.start` SÓ dispara depois de o `doc.apply` do node.add
    /// ser CONFIRMADO pelo engine (§7.1/§9.1) — nunca um start órfão com node_id que
    /// o engine não conhece. Com `renomearSeDuplicado` (quick-start), colisão de nome
    /// (`duplicate_node_name`, §5.2.1) re-gera o próximo livre consultando a verdade
    /// do engine e tenta de novo, com limite; erro remanescente vira toast.
    func addTerminal(
        nome: String,
        papel: String?,
        adapter: String,
        comandoOverride: String?,
        cwd: String,
        monitorarAtividade: Bool,
        renomearSeDuplicado: Bool = false
    ) async {
        guard let ws = workspace else { return }
        let tamanho = Tamanho(w: 640, h: 420)
        var nomeAtual = nome
        let maxTentativas = 5
        for tentativa in 0...maxTentativas {
            let node = TerminalNode(
                id: ULID.generate(),
                posicao: centerPosition(for: tamanho),
                tamanho: tamanho,
                z: nextZ(),
                criadoEm: Date(),
                nome: nomeAtual,
                papel: papel?.isEmpty == true ? nil : papel,
                adapter: adapter,
                comandoOverride: comandoOverride?.isEmpty == true ? nil : comandoOverride,
                cwd: cwd,
                monitorarAtividade: monitorarAtividade
            )
            do {
                try await performManyAguardando([.nodeAdd(NodeAddOpPayload(node: .terminal(node)))])
            } catch let error as ProtocolError where error.known == .duplicate_node_name
                && renomearSeDuplicado && tentativa < maxTentativas {
                nomeAtual = await nomeLivreNoEngine(base: Self.baseNome(adapter: adapter), workspaceID: ws.id)
                continue
            } catch {
                report(error, "node.add \"\(nomeAtual)\"")
                return
            }
            selection = node.id
            let controller = terminalController(for: node.id)
            do {
                try await controller.start(workspaceID: ws.id)
            } catch {
                report(error, "session.start")
            }
            return
        }
    }

    /// Um passo (§5.2.1): nó no centro da viewport + sessão na hora, com defaults.
    func quickStartTerminal(adapter: String) async {
        guard let ws = workspace else { return }
        await addTerminal(
            nome: nomeAutomatico(adapter: adapter),
            papel: nil,
            adapter: adapter,
            comandoOverride: nil,
            cwd: ws.caminhoRaiz ?? FileManager.default.homeDirectoryForCurrentUser.path,
            monitorarAtividade: true,
            renomearSeDuplicado: true
        )
    }

    /// "claude-1", "shell-2"… único no workspace, case-insensitive (§5.2.1),
    /// contra o espelho local (nós de TODOS os andares — como o engine enxerga).
    func nomeAutomatico(adapter: String) -> String {
        Self.nomeLivre(base: Self.baseNome(adapter: adapter), usados: nomesTerminaisLocais())
    }

    static func baseNome(adapter: String) -> String {
        switch KnownAdapter(rawValue: adapter) {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .geminiCli: return "gemini"
        case .opencode: return "opencode"
        case .shell: return "shell"
        case .none: return adapter.lowercased()
        }
    }

    static func nomeLivre(base: String, usados: Set<String>) -> String {
        var n = 1
        while usados.contains("\(base)-\(n)".lowercased()) { n += 1 }
        return "\(base)-\(n)"
    }

    private func nomesTerminaisLocais() -> Set<String> {
        Set(nodes.values.compactMap { node -> String? in
            if case .terminal(let t) = node { return t.nome.lowercased() }
            return nil
        })
    }

    /// Nome livre contra a VERDADE do engine (doc.snapshot) unida ao espelho local —
    /// se o espelho estiver defasado, quem manda é o engine (§5.2.1).
    private func nomeLivreNoEngine(base: String, workspaceID: ULID) async -> String {
        var usados = nomesTerminaisLocais()
        if let result = try? await connection.call(
            .docSnapshot,
            params: DocSnapshotParams(workspaceID: workspaceID),
            expecting: DocSnapshotResult.self
        ) {
            for node in result.documentSnapshot.nodes {
                if case .terminal(let t) = node { usados.insert(t.nome.lowercased()) }
            }
        }
        return Self.nomeLivre(base: base, usados: usados)
    }

    func addNota() {
        guard workspace != nil else { return }
        let id = ULID.generate()
        let node = NotaNode(
            id: id,
            posicao: centerPosition(for: Tamanho(w: 320, h: 240)),
            tamanho: Tamanho(w: 320, h: 240),
            z: nextZ(),
            criadoEm: Date(),
            arquivo: "notes/\(id.string).md",
            cor: "amarelo"
        )
        perform(.nodeAdd(NodeAddOpPayload(node: .nota(node))))
        selection = id
    }

    /// Novo portal no centro da viewport. URL vazia/ilegível → about:blank (a view
    /// põe o foco na barra de URL). Criação pela UI é `node.add` comum — o método
    /// `portal.open` (validação http/https) é a via de CLI/agentes.
    func addPortal(url bruto: String?) {
        guard workspace != nil else { return }
        let url = bruto.flatMap(PortalURL.normalizar) ?? "about:blank"
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
        do {
            try await controller.start(workspaceID: ws.id)
        } catch {
            report(error, "session.start (relançar)")
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

    func zoom(by factor: Double) {
        var v = viewport
        let anchorX = v.x + Double(canvasSize.width) / (2 * v.zoom)
        let anchorY = v.y + Double(canvasSize.height) / (2 * v.zoom)
        v.zoom = min(max(v.zoom * factor, Viewport.zoomRange.lowerBound), Viewport.zoomRange.upperBound)
        v.x = anchorX - Double(canvasSize.width) / (2 * v.zoom)
        v.y = anchorY - Double(canvasSize.height) / (2 * v.zoom)
        setViewport(v)
    }

    func zoomReset() {
        var v = viewport
        v.zoom = 1.0
        setViewport(v)
    }

    private func scheduleViewportPersist() {
        guard viewportTask == nil else { return }
        viewportTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self else { return }
            self.viewportTask = nil
            guard self.workspace != nil else { return }
            self.perform(.viewportSet(ViewportSetOpPayload(viewport: self.viewport)), undoable: false)
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

        if tipo == .texto, let texto {
            perform(.nodeUpdate(NodeUpdateOpPayload(id: nodeID, campos: .object(["texto": .string(texto)]))))
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

    func createFloor(nome: String, branch: String?) async {
        guard let ws = workspace else { return }
        do {
            let result = try await connection.call(
                .floorCreate,
                params: FloorCreateParams(workspaceID: ws.id, nome: nome, branch: branch),
                expecting: FloorResult.self
            )
            floors.append(result.floor)
            await switchFloor(result.floor)
        } catch {
            report(error, "floor.create")
        }
    }

    func switchFloor(_ floor: Floor?) async {
        guard let floor else {
            activeFloor = nil
            return
        }
        do {
            let result = try await connection.call(
                .floorSwitch,
                params: FloorSwitchParams(floorID: floor.id),
                expecting: FloorSwitchResult.self
            )
            activeFloor = result.floor
        } catch {
            report(error, "floor.switch")
        }
    }

    func landFloor(_ floor: Floor) async {
        do {
            _ = try await connection.call(.floorLand, params: FloorLandParams(floorID: floor.id, confirmar: true))
            activeFloor = nil
            await refreshFloors()
        } catch {
            report(error, "floor.land")
        }
    }

    func discardFloor(_ floor: Floor) async {
        do {
            _ = try await connection.call(.floorDiscard, params: FloorDiscardParams(floorID: floor.id, confirmar: true))
            activeFloor = nil
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
        guard let topic = event.knownTopic else { return }
        switch topic {
        case .sessionOutput:
            break
        case .sessionState:
            guard let payload = try? event.decodeParams(SessionStateTopicPayload.self) else { return }
            if let nodeID = node(bySession: payload.sessionID) {
                terminalControllers[nodeID]?.updateEstado(payload.estado, motivo: payload.motivo)
                if payload.estado == .morta {
                    notifications.notifySessaoMorta(node: nodeName(nodeID), nodeID: nodeID, motivo: payload.motivo)
                }
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
            let nodeID = node(bySession: payload.approval.sessionID)
            notifications.notifyAprovacao(payload.approval, nodeID: nodeID)
        case .approvalResolved:
            guard let payload = try? event.decodeParams(ApprovalTopicPayload.self) else { return }
            upsert(approval: payload.approval)
        case .noteAppended:
            guard let payload = try? event.decodeParams(NoteAppendedTopicPayload.self) else { return }
            notaControllers[payload.nodeID]?.reloadFromDisk()
        case .routineFired:
            guard let payload = try? event.decodeParams(RoutineFiredTopicPayload.self) else { return }
            if let routine = routines.first(where: { $0.id == payload.routineID }), routine.notificar {
                notifications.notifyRotina(routine, resultado: payload.resultado)
            }
            Task { await refreshRoutines() }
        case .floorChanged:
            Task { await refreshFloors() }
        case .messageDelivered:
            break
        case .engineWarning:
            if let payload = try? event.decodeParams(EngineWarningTopicPayload.self) {
                lastError = "engine: \(payload.name) — \(payload.message)"
            }
        }
    }

    func nodeName(_ nodeID: ULID) -> String {
        if case .terminal(let t)? = nodes[nodeID] { return t.nome }
        return nodeID.string
    }

    private func report(_ error: Error, _ contexto: String) {
        if error is SocketClientError { return }
        lastError = "\(contexto): \(String(describing: error))"
    }
}
