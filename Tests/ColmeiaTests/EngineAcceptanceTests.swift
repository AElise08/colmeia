import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

// Testes de aceitação deliberadamente atravessam o socket e PTYs reais. A raiz
// curta evita o limite `sun_path` do macOS; não há acesso direto aos handlers.
private func acceptanceRoot() -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cacc-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Adapter de teste com PTY real: cada processo imprime READY e permanece em
/// `cat`; depois de cada output a classificação o deixa elegível para entrega.
private struct AcceptanceIdleAdapter: AgentAdapter {
    let id = "acceptance-idle"
    let nomeExibicao = "Acceptance idle"

    func disponivel() -> Bool { true }
    func launch(_ config: LaunchConfig) -> LaunchPlan {
        LaunchPlan(executavel: "/bin/sh", args: ["-c", "printf 'READY\\n'; exec cat"])
    }
    func classify(_ contexto: AdapterContexto) throws -> SessionEstado? { .ociosa }
}

private func bootAcceptanceEngine() throws -> (Engine, SocketClient, URL) {
    let root = acceptanceRoot()
    let engine = Engine(paths: ColmeiaPaths(root: root))
    engine.registry.register(AcceptanceIdleAdapter())
    try engine.start()
    let client = SocketClient()
    try client.connect(to: ColmeiaPaths(root: root).engineSocket.path)
    return (engine, client, root)
}

private func acceptanceNode(
    nome: String, adapter: String = "acceptance-idle", comandoOverride: String? = nil, cwd: String
) -> TerminalNode {
    TerminalNode(
        id: ULID.generate(), posicao: Ponto(x: 0, y: 0), tamanho: Tamanho(w: 400, h: 280),
        criadoEm: Date(), nome: nome, adapter: adapter, comandoOverride: comandoOverride, cwd: cwd)
}

private func addAcceptanceNodes(_ nodes: [TerminalNode], workspaceID: ULID, client: SocketClient) async throws {
    let ops = nodes.map {
        DocOp(opID: ULID.generate(), author: .humanoLocal, ts: Date(),
              payload: .nodeAdd(NodeAddOpPayload(node: .terminal($0))))
    }
    _ = try await client.call(.docApply, params: DocApplyParams(workspaceID: workspaceID, ops: ops))
}

private func waitForAcceptance(
    timeout: TimeInterval = 4,
    _ predicate: @escaping () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await predicate() { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw NSError(domain: "EngineAcceptanceTests", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "condição não atingida em \(timeout)s"])
}

private func outputContains(_ events: [Event], _ text: String) -> Bool {
    events.contains { event in
        guard case .output(let output) = event.payload,
              let data = Data(base64Encoded: output.dataB64)
        else { return false }
        return String(decoding: data, as: UTF8.self).contains(text)
    }
}

@Suite("Aceitação Engine — aprovações, mensagens, notas e remoção", .serialized)
struct EngineAcceptanceTests {
    @Test func approvalResolveInjetaBytesERegistraEstadoPontaAPonta() async throws {
        let (engine, client, root) = try bootAcceptanceEngine()
        defer { client.close(); engine.stop(); try? FileManager.default.removeItem(at: root) }
        _ = try await client.hello(client: "acceptance")
        let workspace = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "approval", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self).workspace
        // O adapter real claude-code detecta o menu; o override apenas substitui o
        // binário externo por um PTY controlado, mantendo a semântica do adapter.
        let node = acceptanceNode(
            nome: "Claude", adapter: "claude-code",
            comandoOverride: "printf 'Do you want to proceed?\\n❯ 1. Yes\\n  2. No\\n'; sleep 5",
            cwd: root.path)
        try await addAcceptanceNodes([node], workspaceID: workspace.id, client: client)
        let session = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: workspace.id, nodeID: node.id),
            expecting: SessionResult.self).session

        var approval: Approval?
        try await waitForAcceptance {
            let list = try await client.call(
                .approvalList,
                params: ApprovalListParams(workspaceID: workspace.id, estado: .pendente),
                expecting: ApprovalListResult.self)
            approval = list.first
            return approval != nil
        }
        let pending = try #require(approval)
        #expect(pending.sessionID == session.id)
        #expect(pending.opcoes?.first == "Yes")

        let resolved = try await client.call(
            .approvalResolve,
            params: ApprovalResolveParams(approvalID: pending.id, decisao: .aprovar),
            expecting: ApprovalResult.self).approval
        #expect(resolved.estado == .aprovada)
        #expect(resolved.resolvidaPor == .humanoLocal)

        let replay = try await client.call(
            .sessionReplay, params: SessionReplayParams(sessionID: session.id), expecting: SessionReplayResult.self)
        #expect(replay.events.contains { event in
            guard case .input(let input) = event.payload else { return false }
            return event.author == .humanoLocal && Data(base64Encoded: input.dataB64) == Data("1".utf8)
        })
        #expect(replay.events.contains { event in
            guard case .approval(let approvalEvent) = event.payload else { return false }
            return approvalEvent.approvalID == pending.id && approvalEvent.acao == .resolvida
                && approvalEvent.decisao == .aprovar && event.author == .humanoLocal
        })
        #expect(replay.events.contains { event in
            guard case .state(let state) = event.payload else { return false }
            return state.para == .aprovacaoPendente
        })
        #expect(replay.events.contains { event in
            guard case .state(let state) = event.payload else { return false }
            return state.para == .rodando && state.motivo == "approval_resolvida"
        })
    }

    @Test func messageSendEntregaEntreDoisPTYsEJournalsAuditamAutores() async throws {
        let (engine, client, root) = try bootAcceptanceEngine()
        defer { client.close(); engine.stop(); try? FileManager.default.removeItem(at: root) }
        _ = try await client.hello(client: "acceptance")
        let workspace = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "messages", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self).workspace
        let a = acceptanceNode(nome: "A", cwd: root.path)
        let b = acceptanceNode(nome: "B", cwd: root.path)
        try await addAcceptanceNodes([a, b], workspaceID: workspace.id, client: client)
        let sessionA = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: workspace.id, nodeID: a.id),
            expecting: SessionResult.self).session
        let sessionB = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: workspace.id, nodeID: b.id),
            expecting: SessionResult.self).session

        try await waitForAcceptance {
            let sessions = try await client.call(
                .sessionList, params: SessionListParams(workspaceID: workspace.id), expecting: SessionListResult.self)
            return sessions.first(where: { $0.id == sessionA.id })?.estado == .ociosa
                && sessions.first(where: { $0.id == sessionB.id })?.estado == .ociosa
        }
        let text = "tarefa para B"
        let sent = try await client.call(
            .messageSend,
            params: MessageSendParams(workspaceID: workspace.id, deNode: a.id, paraNome: "B", texto: text, timeoutSeg: 0),
            expecting: MessageSendResult.self)

        var replayB: SessionReplayResult?
        try await waitForAcceptance {
            replayB = try await client.call(
                .sessionReplay, params: SessionReplayParams(sessionID: sessionB.id), expecting: SessionReplayResult.self)
            return replayB.map { outputContains($0.events, text) } ?? false
        }
        let senderEvents = try await client.call(
            .sessionReplay, params: SessionReplayParams(sessionID: sessionA.id), expecting: SessionReplayResult.self).events
        let destinationEvents = try #require(replayB).events
        let agentA = Author.agente(a.id.string)
        #expect(senderEvents.contains { event in
            guard case .message(let message) = event.payload else { return false }
            return message.direcao == .enviada && message.messageID == sent.messageID
                && message.contraparte == b.id && message.texto == text && event.author == agentA
        })
        #expect(destinationEvents.contains { event in
            guard case .message(let message) = event.payload else { return false }
            return message.direcao == .recebida && message.messageID == sent.messageID
                && message.contraparte == a.id && message.texto == text && event.author == agentA
        })
        let destinationInputs = destinationEvents.compactMap { event -> (Author, Data)? in
            guard case .input(let input) = event.payload,
                  let data = Data(base64Encoded: input.dataB64) else { return nil }
            return (event.author, data)
        }
        #expect(destinationInputs.contains { author, data in
            author == agentA && data == Data(text.utf8)
        })
        #expect(destinationInputs.contains { author, data in
            author == agentA && data == Data([0x0D])
        })
        let snapshot = try await client.call(
            .docSnapshot, params: DocSnapshotParams(workspaceID: workspace.id), expecting: DocSnapshotResult.self).documentSnapshot
        #expect(snapshot.connections.contains {
            $0.semantica == .conversa
                && (($0.de == a.id && $0.para == b.id) || ($0.de == b.id && $0.para == a.id))
        })
    }

    @Test func agenteQueCriaSubagenteRecebeConexaoImediata() async throws {
        let (engine, client, root) = try bootAcceptanceEngine()
        defer { client.close(); engine.stop(); try? FileManager.default.removeItem(at: root) }
        _ = try await client.hello(client: "acceptance-human")
        let workspace = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "subagent", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self).workspace
        let principal = acceptanceNode(nome: "Codex", cwd: root.path)
        try await addAcceptanceNodes([principal], workspaceID: workspace.id, client: client)
        client.close()

        let agent = SocketClient()
        try agent.connect(to: ColmeiaPaths(root: root).engineSocket.path)
        defer { agent.close() }
        _ = try await agent.hello(
            client: "acceptance-agent", author: .agente(principal.id.string))
        let subagent = acceptanceNode(nome: "OpenCode", cwd: root.path)
        let op = DocOp(
            opID: ULID.generate(), author: .agente(principal.id.string), ts: Date(),
            payload: .nodeAdd(NodeAddOpPayload(node: .terminal(subagent))))
        _ = try await agent.call(
            .docApply,
            params: DocApplyParams(workspaceID: workspace.id, ops: [op]),
            expecting: DocApplyResult.self)

        let snapshot = try await agent.call(
            .docSnapshot,
            params: DocSnapshotParams(workspaceID: workspace.id),
            expecting: DocSnapshotResult.self).documentSnapshot
        #expect(snapshot.connections.contains {
            $0.semantica == .conversa && $0.de == principal.id && $0.para == subagent.id
        })
    }

    @Test func noteAppendCriaNotaConexaoArquivoEEventoDeJournal() async throws {
        let (engine, client, root) = try bootAcceptanceEngine()
        defer { client.close(); engine.stop(); try? FileManager.default.removeItem(at: root) }
        let paths = ColmeiaPaths(root: root)
        _ = try await client.hello(client: "acceptance")
        let workspace = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "notes", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self).workspace
        let source = acceptanceNode(nome: "Origem", cwd: root.path)
        try await addAcceptanceNodes([source], workspaceID: workspace.id, client: client)
        let session = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: workspace.id, nodeID: source.id),
            expecting: SessionResult.self).session

        let text = "registrar decisão importante"
        let result = try await client.call(
            .noteAppend,
            params: NoteAppendParams(workspaceID: workspace.id, nodeIDOrigem: source.id, texto: text),
            expecting: NoteAppendResult.self)
        let snapshot = try await client.call(
            .docSnapshot, params: DocSnapshotParams(workspaceID: workspace.id), expecting: DocSnapshotResult.self).documentSnapshot
        guard case .nota(let note)? = snapshot.nodes.first(where: { $0.id == result.notaNodeID }) else {
            Issue.record("note.append deveria criar NotaNode")
            return
        }
        #expect(note.ultimaFonte == .humanoLocal)
        #expect(snapshot.connections.contains {
            $0.de == source.id && $0.para == note.id && $0.semantica == .escritaDeNota
        })
        let file = paths.noteFile(workspace: workspace.id, node: note.id)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: file, encoding: .utf8).contains(text))
        let replay = try await client.call(
            .sessionReplay, params: SessionReplayParams(sessionID: session.id), expecting: SessionReplayResult.self)
        #expect(replay.events.contains { event in
            guard case .note(let noteEvent) = event.payload else { return false }
            return event.author == .humanoLocal && noteEvent.notaNodeID == note.id && noteEvent.resumo == text
        })
    }

    @Test func workspaceDeleteExigeConfirmacaoERemoveEstadoPersistido() async throws {
        let (engine, client, root) = try bootAcceptanceEngine()
        defer { client.close(); engine.stop(); try? FileManager.default.removeItem(at: root) }
        let paths = ColmeiaPaths(root: root)
        _ = try await client.hello(client: "acceptance")
        let workspace = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "delete", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self).workspace
        let node = acceptanceNode(nome: "Persistido", cwd: root.path)
        try await addAcceptanceNodes([node], workspaceID: workspace.id, client: client)
        #expect(FileManager.default.fileExists(atPath: paths.workspaceDir(workspace.id).path))

        do {
            _ = try await client.call(.workspaceDelete, params: WorkspaceDeleteParams(id: workspace.id, confirmar: false))
            Issue.record("workspace.delete sem confirmar deveria falhar")
        } catch let error as ProtocolError {
            #expect(error.known == .confirmation_required)
        }
        #expect(FileManager.default.fileExists(atPath: paths.workspaceDir(workspace.id).path))
        _ = try await client.call(.workspaceDelete, params: WorkspaceDeleteParams(id: workspace.id, confirmar: true))
        let list = try await client.call(.workspaceList, expecting: WorkspaceListResult.self)
        #expect(!list.contains(where: { $0.id == workspace.id }))
        #expect(!FileManager.default.fileExists(atPath: paths.workspaceDir(workspace.id).path))
        do {
            _ = try await client.call(.workspaceOpen, params: WorkspaceOpenParams(id: workspace.id))
            Issue.record("workspace removido não deveria abrir")
        } catch let error as ProtocolError {
            #expect(error.known == .workspace_not_found)
        }
    }
}

// MARK: - Memória, entregas e operação de workers

@Suite("Aceitação Engine — memória, entregas e workers", .serialized)
struct EngineOperationsAcceptanceTests {
    private func makeAgentClient(root: URL, nodeID: ULID) async throws -> SocketClient {
        let client = SocketClient()
        try client.connect(to: ColmeiaPaths(root: root).engineSocket.path)
        _ = try await client.hello(client: "acceptance-agent", author: .agente(nodeID.string))
        return client
    }

    private func waitUntilClosed(_ sessionID: ULID, workspaceID: ULID, client: SocketClient) async throws {
        try await waitForAcceptance {
            let sessions = try await client.call(
                .sessionList,
                params: SessionListParams(workspaceID: workspaceID),
                expecting: SessionListResult.self
            )
            return sessions.first(where: { $0.id == sessionID })?.estado == .encerrada
        }
    }

    private func completedEvidence(nodeID: ULID, at: Date = Date()) -> DeliveryEvidence {
        DeliveryEvidence(
            id: ULID.generate(),
            tipo: .test,
            referencia: "ColmeiaTests.EngineOperationsAcceptanceTests/delivery",
            descricao: "fixture de aceitação",
            resultadoTeste: .passed,
            autor: .agente(nodeID.string),
            criadaEm: at
        )
    }

    @Test func memoriaHumanaAgentePropoeEHumanoAceitaViaSocket() async throws {
        let (engine, human, root) = try bootAcceptanceEngine()
        defer { human.close(); engine.stop(); try? FileManager.default.removeItem(at: root) }
        _ = try await human.hello(client: "acceptance-human")
        let workspace = try await human.call(
            .workspaceCreate,
            params: WorkspaceCreateParams(nome: "memory-acceptance", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self
        ).workspace
        let node = acceptanceNode(nome: "Memory Agent", cwd: root.path)
        try await addAcceptanceNodes([node], workspaceID: workspace.id, client: human)

        let updated = try await human.call(
            .memoryUpdate,
            params: MemoryUpdateParams(workspaceID: workspace.id, content: "Decisão humana inicial."),
            expecting: MemoryGetResult.self
        )
        #expect(updated.memory.content == "Decisão humana inicial.")
        #expect(updated.memory.updatedBy == .humanoLocal)

        let agent = try await makeAgentClient(root: root, nodeID: node.id)
        defer { agent.close() }
        let proposal = try await agent.call(
            .memoryPropose,
            params: MemoryProposeParams(workspaceID: workspace.id, content: "Usar o adapter de fixture nos testes."),
            expecting: MemoryProposal.self
        )
        #expect(proposal.author == .agente(node.id.string))
        #expect(proposal.status == .pending)

        let accepted = try await human.call(
            .memoryAccept,
            params: MemoryProposalResolveParams(workspaceID: workspace.id, proposalID: proposal.id),
            expecting: MemoryGetResult.self
        )
        #expect(accepted.memory.updatedBy == .humanoLocal)
        #expect(accepted.memory.content.contains("Decisão humana inicial."))
        #expect(accepted.memory.content.contains("Usar o adapter de fixture nos testes."))

        let proposals = try await human.call(
            .memoryProposalList,
            params: MemoryProposalListParams(workspaceID: workspace.id),
            expecting: MemoryProposalListResult.self
        )
        #expect(proposals.first(where: { $0.id == proposal.id })?.status == .accepted)
    }

    @Test func deliveryCompletedExigeEvidenciaEHumanoAceitaViaSocket() async throws {
        let (engine, human, root) = try bootAcceptanceEngine()
        defer { human.close(); engine.stop(); try? FileManager.default.removeItem(at: root) }
        _ = try await human.hello(client: "acceptance-human")
        let workspace = try await human.call(
            .workspaceCreate,
            params: WorkspaceCreateParams(nome: "delivery-acceptance", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self
        ).workspace
        let node = acceptanceNode(
            nome: "Delivery Agent", comandoOverride: "printf 'DONE\\n'; exit 0", cwd: root.path)
        try await addAcceptanceNodes([node], workspaceID: workspace.id, client: human)
        let session = try await human.call(
            .sessionStart,
            params: SessionStartParams(workspaceID: workspace.id, nodeID: node.id),
            expecting: SessionResult.self
        ).session
        try await waitUntilClosed(session.id, workspaceID: workspace.id, client: human)

        let agent = try await makeAgentClient(root: root, nodeID: node.id)
        defer { agent.close() }
        let missingEvidence = DeliverySubmission(
            id: ULID.generate(), workspaceID: workspace.id, sessionID: session.id, nodeID: node.id,
            estado: .proposed, resumo: "Concluída sem prova.", evidencias: []
        )
        do {
            _ = try await agent.call(
                .deliverySubmit, params: DeliverySubmitParams(submission: missingEvidence), expecting: DeliveryResult.self)
            Issue.record("delivery completed sem evidência deveria falhar")
        } catch let error as ProtocolError {
            #expect(error.known == .invalid_params)
        }

        let valid = DeliverySubmission(
            id: ULID.generate(), workspaceID: workspace.id, sessionID: session.id, nodeID: node.id,
            estado: .proposed, resumo: "Fixture entregue.", evidencias: [completedEvidence(nodeID: node.id)]
        )
        let submitted = try await agent.call(
            .deliverySubmit, params: DeliverySubmitParams(submission: valid), expecting: DeliveryResult.self
        ).delivery
        #expect(submitted.estado == .proposed)
        #expect(submitted.submetidaPor == .agente(node.id.string))

        let accepted = try await human.call(
            .deliveryAccept, params: DeliveryReviewParams(deliveryID: submitted.id), expecting: DeliveryResult.self
        ).delivery
        #expect(accepted.aceita)
        #expect(accepted.reviewedBy == .humanoLocal)
    }

    @Test func watchdogComecaDesligadoEHumanoAtualizaConfiguracao() async throws {
        let (engine, human, root) = try bootAcceptanceEngine()
        defer { human.close(); engine.stop(); try? FileManager.default.removeItem(at: root) }
        _ = try await human.hello(client: "acceptance-human")
        let workspace = try await human.call(
            .workspaceCreate,
            params: WorkspaceCreateParams(nome: "watchdog-acceptance", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self
        ).workspace

        let initial = try await human.call(
            .watchdogGet, params: WatchdogGetParams(workspaceID: workspace.id), expecting: WatchdogGetResult.self)
        #expect(!initial.configuration.workspacePolicy.enabled)

        let configuration = WorkerWatchdogConfiguration(
            workspacePolicy: WorkerWatchdogPolicy(enabled: true, staleAfter: 90, nudgeInterval: 30, maxNudgesPerEpisode: 1)
        )
        let updated = try await human.call(
            .watchdogUpdate,
            params: WatchdogUpdateParams(workspaceID: workspace.id, configuration: configuration),
            expecting: WatchdogGetResult.self
        )
        #expect(updated.configuration == configuration)
        let reloaded = try await human.call(
            .watchdogGet, params: WatchdogGetParams(workspaceID: workspace.id), expecting: WatchdogGetResult.self)
        #expect(reloaded.configuration == configuration)
    }

    @Test func workerArquivaComEntregaAceitaERestoreSoReexpoeReplay() async throws {
        let (engine, human, root) = try bootAcceptanceEngine()
        defer { human.close(); engine.stop(); try? FileManager.default.removeItem(at: root) }
        _ = try await human.hello(client: "acceptance-human")
        let workspace = try await human.call(
            .workspaceCreate,
            params: WorkspaceCreateParams(nome: "archive-acceptance", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self
        ).workspace
        let node = acceptanceNode(
            nome: "Archived Worker", comandoOverride: "printf 'ARCHIVED\\n'; exit 0", cwd: root.path)
        try await addAcceptanceNodes([node], workspaceID: workspace.id, client: human)
        let session = try await human.call(
            .sessionStart,
            params: SessionStartParams(workspaceID: workspace.id, nodeID: node.id),
            expecting: SessionResult.self
        ).session
        try await waitUntilClosed(session.id, workspaceID: workspace.id, client: human)

        // Sessão encerrada sem entrega aceita nem confirmação humana ainda não arquiva.
        do {
            _ = try await human.call(
                .workerArchive,
                params: WorkerArchiveParams(workspaceID: workspace.id, sessionID: session.id, confirmar: false),
                expecting: WorkerArchiveResult.self
            )
            Issue.record("arquivo sem prova humana deveria falhar")
        } catch let error as ProtocolError {
            #expect(error.known == .invalid_params)
        }

        let agent = try await makeAgentClient(root: root, nodeID: node.id)
        defer { agent.close() }
        let delivery = try await agent.call(
            .deliverySubmit,
            params: DeliverySubmitParams(submission: DeliverySubmission(
                id: ULID.generate(), workspaceID: workspace.id, sessionID: session.id, nodeID: node.id,
                estado: .proposed, resumo: "Worker pode ser arquivado.",
                evidencias: [completedEvidence(nodeID: node.id)]
            )),
            expecting: DeliveryResult.self
        ).delivery
        _ = try await human.call(
            .deliveryAccept, params: DeliveryReviewParams(deliveryID: delivery.id), expecting: DeliveryResult.self)

        let archived = try await human.call(
            .workerArchive,
            params: WorkerArchiveParams(workspaceID: workspace.id, sessionID: session.id, confirmar: false),
            expecting: WorkerArchiveResult.self
        ).tombstone
        #expect(archived.session.id == session.id)
        #expect(archived.deliveryAccepted)
        #expect(!archived.humanConfirmed)

        let restored = try await human.call(
            .workerRestore,
            params: WorkerRestoreParams(workspaceID: workspace.id, archiveID: archived.id),
            expecting: WorkerRestoreResult.self
        )
        #expect(restored.session.id == session.id)
        #expect(restored.session.estado == .encerrada)
        #expect(restored.journal == archived.evidence.journal)
        let sessions = try await human.call(
            .sessionList, params: SessionListParams(workspaceID: workspace.id), expecting: SessionListResult.self)
        #expect(sessions.filter { $0.id == session.id }.count == 1)
        #expect(sessions.first(where: { $0.id == session.id })?.estado == .encerrada)
    }

    @Test func workerArquivaComConfirmacaoHumanaMesmoSemEntrega() async throws {
        let (engine, human, root) = try bootAcceptanceEngine()
        defer { human.close(); engine.stop(); try? FileManager.default.removeItem(at: root) }
        _ = try await human.hello(client: "acceptance-human")
        let workspace = try await human.call(
            .workspaceCreate,
            params: WorkspaceCreateParams(nome: "archive-confirmation", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self
        ).workspace
        let node = acceptanceNode(
            nome: "Confirmed Worker", comandoOverride: "printf 'CONFIRMED\\n'; exit 0", cwd: root.path)
        try await addAcceptanceNodes([node], workspaceID: workspace.id, client: human)
        let session = try await human.call(
            .sessionStart,
            params: SessionStartParams(workspaceID: workspace.id, nodeID: node.id),
            expecting: SessionResult.self
        ).session
        try await waitUntilClosed(session.id, workspaceID: workspace.id, client: human)

        let archived = try await human.call(
            .workerArchive,
            params: WorkerArchiveParams(workspaceID: workspace.id, sessionID: session.id, confirmar: true),
            expecting: WorkerArchiveResult.self
        ).tombstone
        #expect(archived.session.id == session.id)
        #expect(!archived.deliveryAccepted)
        #expect(archived.humanConfirmed)
    }

}
