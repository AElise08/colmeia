import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

// Raiz temporária CURTA: sockaddr_un limita o path do socket a ~104 bytes.
private func tempRoot() -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("colm-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeTerminalNode(nome: String, adapter: String = "shell", override: String? = nil) -> TerminalNode {
    TerminalNode(
        id: ULID.generate(), posicao: Ponto(x: 0, y: 0), tamanho: Tamanho(w: 400, h: 300),
        criadoEm: Date(), nome: nome, adapter: adapter, comandoOverride: override, cwd: NSHomeDirectory())
}

private func proposal(_ payload: OpPayload, author: Author = .humanoLocal) -> DocOp {
    DocOp(opID: ULID.generate(), author: author, ts: Date(), payload: payload)
}

// MARK: - Journal (§8, §22.3)

@Suite("Journal de sessão")
struct JournalTests {
    @Test func seqContinuoDesdeUmEReplay() throws {
        let url = tempRoot().appendingPathComponent("j.jsonl")
        let journal = try SessionJournal(url: url)
        for index in 0..<20 {
            let event = journal.append(
                .output(OutputEventPayload(dataB64: Data("c\(index)".utf8).base64EncodedString())),
                author: .agente("n1"))
            #expect(event?.seq == UInt64(index + 1))
        }
        journal.flush()
        journal.seal()
        let result = JournalReader.read(url: url, repair: false)
        #expect(!result.corrupted)
        #expect(result.events.count == 20)
        #expect(result.events.map(\.seq) == Array(1...20).map(UInt64.init))
        // journal selado não aceita mais appends
        #expect(journal.append(.output(OutputEventPayload(dataB64: "")), author: .sistema) == nil)
    }

    @Test func linhaCorrompidaVaiParaQuarentena() throws {
        let url = tempRoot().appendingPathComponent("j.jsonl")
        let journal = try SessionJournal(url: url)
        for _ in 0..<5 {
            journal.append(.output(OutputEventPayload(dataB64: "YQ==")), author: .sistema)
        }
        journal.seal()
        // corrompe a linha 4 (índice 3)
        var lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[3] = "{lixo!!!"
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let result = JournalReader.read(url: url, repair: true)
        #expect(result.corrupted)
        #expect(result.events.count == 3) // prefixo válido
        #expect(result.quarantinedBytes > 0)
        // nada apagado silenciosamente: quarentena existe, journal reescrito só com o prefixo bom
        let quarantine = url.appendingPathExtension("quarantine")
        #expect(FileManager.default.fileExists(atPath: quarantine.path))
        let reread = JournalReader.read(url: url, repair: false)
        #expect(!reread.corrupted)
        #expect(reread.events.count == 3)
    }

    @Test func buracoDeSeqEhCorrupcao() throws {
        let url = tempRoot().appendingPathComponent("j.jsonl")
        let journal = try SessionJournal(url: url)
        for _ in 0..<4 {
            journal.append(.output(OutputEventPayload(dataB64: "YQ==")), author: .sistema)
        }
        journal.seal()
        var lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.remove(at: 2) // remove seq 3 → buraco
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let result = JournalReader.read(url: url, repair: false)
        #expect(result.corrupted) // §8.1 — leitores DEVEM tratar buraco como corrupção
        #expect(result.events.count == 2)
    }
}

// MARK: - Documento (§7, §24.7, §25.7)

@Suite("Documento do workspace")
struct DocumentStoreTests {
    private func makeState(_ root: URL) throws -> WorkspaceState {
        let paths = ColmeiaPaths(root: root)
        let now = Date()
        let workspace = Workspace(id: ULID.generate(), nome: "ws", criadoEm: now, atualizadoEm: now)
        return try WorkspaceState(paths: paths, workspace: workspace)
    }

    @Test func opsComSeqAnteriorESnapshotReconstroem() throws {
        let root = tempRoot()
        let state = try makeState(root)
        let node = makeTerminalNode(nome: "Claudio")
        let add = try state.applyProposal(proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(node)))), liveNodeIDs: [])
        #expect(add.seq == 1)
        let move = try state.applyProposal(
            proposal(.nodeMove(NodeMoveOpPayload(id: node.id, posicao: Ponto(x: 10, y: 20)))), liveNodeIDs: [])
        #expect(move.seq == 2)
        // §7.3 — anterior carrega os dados de inversão
        #expect(move.anterior?["posicao"]?["x"]?.numberValue == 0)
        #expect(state.nodes[node.id]?.posicao.x == 10)

        // 25.7.1 — document.jsonl sozinho (sem snapshot) reconstrói idêntico
        let reloaded = try makeState2(root, workspace: state.workspace)
        #expect(reloaded.seq == 2)
        #expect(reloaded.nodes[node.id]?.posicao.x == 10)

        // snapshot + reload
        try state.writeSnapshot()
        let reloaded2 = try makeState2(root, workspace: state.workspace)
        #expect(reloaded2.seq == 2)
        #expect(reloaded2.nodes[node.id]?.posicao.x == 10)
    }

    private func makeState2(_ root: URL, workspace: Workspace) throws -> WorkspaceState {
        try WorkspaceState(paths: ColmeiaPaths(root: root), workspace: workspace)
    }

    @Test func nomeDuplicadoESessaoAtivaFalham() throws {
        let state = try makeState(tempRoot())
        let a = makeTerminalNode(nome: "Marcus")
        let b = makeTerminalNode(nome: "marcus") // case-insensitive (§5.2.1)
        _ = try state.applyProposal(proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(a)))), liveNodeIDs: [])
        #expect(throws: ProtocolError.self) {
            _ = try state.applyProposal(proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(b)))), liveNodeIDs: [])
        }
        do {
            _ = try state.applyProposal(proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(b)))), liveNodeIDs: [])
        } catch let error as ProtocolError {
            #expect(error.known == .duplicate_node_name)
        }
        // node.delete com sessão viva → session_already_running (§7.2)
        do {
            _ = try state.applyProposal(proposal(.nodeDelete(NodeDeleteOpPayload(id: a.id))), liveNodeIDs: [a.id])
            Issue.record("delete deveria falhar")
        } catch let error as ProtocolError {
            #expect(error.known == .session_already_running)
        }
    }

    @Test func corrupcaoNoMeioDoJsonlQuarentenaEReconstrucaoParcial() throws {
        let root = tempRoot()
        let state = try makeState(root)
        var ids: [ULID] = []
        for index in 0..<6 {
            let node = makeTerminalNode(nome: "n\(index)")
            ids.append(node.id)
            _ = try state.applyProposal(proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(node)))), liveNodeIDs: [])
        }
        let docURL = ColmeiaPaths(root: root).documentFile(state.workspace.id)
        var lines = try String(contentsOf: docURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[3] = "###corrompido###"
        try lines.joined(separator: "\n").write(to: docURL, atomically: true, encoding: .utf8)

        let reloaded = try makeState2(root, workspace: state.workspace)
        #expect(reloaded.seq == 3) // prefixo válido
        #expect(reloaded.nodes.count == 3)
        #expect(reloaded.corruptionNotice != nil)
        #expect(FileManager.default.fileExists(atPath: docURL.appendingPathExtension("quarantine").path))
    }

    @Test func undoRestauraEstadoExato() throws {
        // 25.7.3 — a inversão usa payload.anterior ecoado pelo engine
        let state = try makeState(tempRoot())
        let node = makeTerminalNode(nome: "Lead")
        _ = try state.applyProposal(proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(node)))), liveNodeIDs: [])
        let move = try state.applyProposal(
            proposal(.nodeMove(NodeMoveOpPayload(id: node.id, posicao: Ponto(x: 99, y: 77)))), liveNodeIDs: [])
        let anterior = try #require(move.anterior?["posicao"])
        let posicaoAnterior = try anterior.decode(as: Ponto.self)
        _ = try state.applyProposal(
            proposal(.nodeMove(NodeMoveOpPayload(id: node.id, posicao: posicaoAnterior))), liveNodeIDs: [])
        #expect(state.nodes[node.id]?.posicao == Ponto(x: 0, y: 0))
    }
}

// MARK: - Rotinas (§17)

@Suite("Rotinas — agenda e elegibilidade")
struct RoutineSchedulingTests {
    @Test func intervaloNuncaRetroativo() {
        let agora = Date()
        let agenda = Agenda(tipo: .intervalo, intervaloSeg: 60, inicio: agora.addingTimeInterval(-3600))
        let proxima = RoutineScheduling.proximaExecucao(agenda: agenda, agora: agora, jaExecutou: true)
        #expect(proxima != nil)
        #expect(proxima! > agora) // §17.4 — recalcula a partir de agora, sem retroativo
        #expect(abs(proxima!.timeIntervalSince(agora) - 60) < 1)
    }

    @Test func inicioNoFuturoValeOInicio() {
        let agora = Date()
        let inicio = agora.addingTimeInterval(500)
        let agenda = Agenda(tipo: .intervalo, intervaloSeg: 60, inicio: inicio)
        #expect(RoutineScheduling.proximaExecucao(agenda: agenda, agora: agora, jaExecutou: false) == inicio)
    }

    @Test func onceNoPassadoNaoDisparaSozinha() {
        let agora = Date()
        let agenda = Agenda(tipo: .once, inicio: agora.addingTimeInterval(-60))
        #expect(RoutineScheduling.proximaExecucao(agenda: agenda, agora: agora, jaExecutou: false) == nil)
        let futura = Agenda(tipo: .once, inicio: agora.addingTimeInterval(60))
        #expect(RoutineScheduling.proximaExecucao(agenda: futura, agora: agora, jaExecutou: false) != nil)
        #expect(RoutineScheduling.proximaExecucao(agenda: futura, agora: agora, jaExecutou: true) == nil)
    }

    @Test func fimRepeticaoCorta() {
        let agora = Date()
        let agenda = Agenda(
            tipo: .intervalo, intervaloSeg: 3600, inicio: agora.addingTimeInterval(-10),
            fimRepeticao: .em(agora.addingTimeInterval(60)))
        #expect(RoutineScheduling.proximaExecucao(agenda: agenda, agora: agora, jaExecutou: true) == nil)
    }

    @Test func diariaProximaHora() {
        let calendar = Calendar.current
        let agora = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let agenda = Agenda(tipo: .diaria, hora: "09:30", inicio: agora.addingTimeInterval(-86400))
        let proxima = RoutineScheduling.proximaExecucao(agenda: agenda, agora: agora, jaExecutou: true)!
        #expect(proxima > agora)
        #expect(calendar.component(.hour, from: proxima) == 9)
        #expect(calendar.component(.minute, from: proxima) == 30)
    }

    @Test func elegibilidade() {
        // §17.3 — a matriz completa
        #expect(RoutineScheduling.elegibilidade(alvoExiste: false, sessaoViva: false, estado: nil) == .puladaAlvoAusente)
        #expect(RoutineScheduling.elegibilidade(alvoExiste: true, sessaoViva: false, estado: nil) == .puladaAlvoAusente)
        #expect(RoutineScheduling.elegibilidade(alvoExiste: true, sessaoViva: true, estado: .rodando) == .puladaOcupado)
        #expect(RoutineScheduling.elegibilidade(alvoExiste: true, sessaoViva: true, estado: .aprovacaoPendente) == .puladaOcupado)
        #expect(RoutineScheduling.elegibilidade(alvoExiste: true, sessaoViva: true, estado: .esperandoHumano) == .executada)
        #expect(RoutineScheduling.elegibilidade(alvoExiste: true, sessaoViva: true, estado: .ociosa) == .executada)
    }
}

// MARK: - Adapter claude-code (§10.3–10.4, 25.3.4)

@Suite("Adapter claude-code")
struct ClaudeCodeAdapterTests {
    private let fixture = """
    \u{1B}[1mBash command\u{1B}[0m

    │ rm -rf build/

    Do you want to proceed?
    ❯ 1. Yes
      2. Yes, and don't ask again this session
      3. No, and tell Claude what to do differently

    """

    @Test func detectaAprovacaoComOpcoes() throws {
        let adapter = ClaudeCodeAdapter()
        let contexto = AdapterContexto(ultimoChunk: Data(), bufferRecente: fixture, silencioSeg: 2)
        let draft = try #require(try adapter.detectApproval(contexto))
        #expect(draft.resumo == "Do you want to proceed?")
        #expect(draft.opcoes?.count == 3)
        #expect(draft.opcoes?.first == "Yes")
        #expect(try adapter.classify(contexto) == .aprovacaoPendente)
    }

    @Test func injectReplyMapeiaOpcoes() {
        let adapter = ClaudeCodeAdapter()
        let approval = Approval(
            id: ULID.generate(), sessionID: ULID.generate(), nodeNome: "x", resumo: "?",
            opcoes: ["Yes", "Yes, and don't ask again", "No"], estado: .pendente, criadaEm: Date())
        #expect(adapter.injectReply(approval, decisao: .aprovar, opcaoIndex: nil) == Data("1".utf8))
        #expect(adapter.injectReply(approval, decisao: .negar, opcaoIndex: nil) == Data("3".utf8))
        #expect(adapter.injectReply(approval, decisao: .aprovar, opcaoIndex: 1) == Data("2".utf8))
        #expect(adapter.injectReply(approval, decisao: .aprovar, opcaoIndex: 9) == nil) // fora do menu → invalid_params
        let semOpcoes = Approval(
            id: ULID.generate(), sessionID: ULID.generate(), nodeNome: "x", resumo: "?",
            opcoes: nil, estado: .pendente, criadaEm: Date())
        #expect(adapter.injectReply(semOpcoes, decisao: .aprovar, opcaoIndex: nil) == nil) // §10.4 nunca chutar
    }

    @Test func shellNuncaClassifica() throws {
        let adapter = ShellAdapter()
        let contexto = AdapterContexto(ultimoChunk: Data("x".utf8), bufferRecente: "x", silencioSeg: 120)
        #expect(try adapter.classify(contexto) == nil) // 25.3.3
        #expect(try adapter.detectApproval(contexto) == nil)
    }
}

// MARK: - Protocolo ponta a ponta pelo socket (§25.1, §25.9.4)

/// Adapter fake da suíte (25.3.1): registrado sem nenhuma mudança no engine.
private struct ExplosivoAdapter: AgentAdapter {
    let id = "explosivo"
    let nomeExibicao = "Explosivo"
    func disponivel() -> Bool { true }
    func launch(_ config: LaunchConfig) -> LaunchPlan { LaunchPlan(executavel: "/bin/sh", args: ["-c", "echo boom; sleep 0.2"]) }
    func classify(_ contexto: AdapterContexto) throws -> SessionEstado? {
        struct Boom: Error {}
        throw Boom() // 25.3.2 — exceção em classify → modo degradado, terminal segue
    }
}

@Suite("Engine pelo socket", .serialized)
struct EngineSocketTests {
    private func boot() throws -> (Engine, SocketClient, URL) {
        let root = tempRoot()
        let engine = Engine(paths: ColmeiaPaths(root: root))
        engine.registry.register(ExplosivoAdapter())
        try engine.start()
        let client = SocketClient()
        try client.connect(to: ColmeiaPaths(root: root).engineSocket.path)
        return (engine, client, root)
    }

    @Test func handshakeVersaoErradaFalha() async throws {
        let (engine, client, _) = try boot()
        defer { engine.stop() }
        do {
            _ = try await client.hello(client: "test", protocolVersion: 99)
            Issue.record("handshake deveria falhar")
        } catch let error as ProtocolError {
            #expect(error.known == .protocol_version_mismatch) // 25.1.1
        }
        client.close()
    }

    @Test func metodoAntesDoHelloEDepoisFluxoCompleto() async throws {
        let (engine, client, _) = try boot()
        defer { engine.stop() }
        // antes do hello → erro
        do {
            _ = try await client.call(.engineStatus, expecting: EngineStatusResult.self)
            Issue.record("deveria exigir handshake")
        } catch let error as ProtocolError {
            #expect(error.known == .invalid_params)
        }
        _ = try await client.hello(client: "test")

        // workspace + documento
        let created = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "sala"), expecting: WorkspaceResult.self)
        let wsID = created.workspace.id
        _ = try await client.call(.workspaceOpen, params: WorkspaceOpenParams(id: wsID))
        _ = try await client.call(
            .subscribe, params: SubscribeParams(topics: [.documentOp], workspaceID: wsID))

        let node = makeTerminalNode(nome: "Claudio")
        let apply = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: wsID, ops: [proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(node))))]),
            expecting: DocApplyResult.self)
        #expect(apply.seqFinal == 1)

        // eco via document.op (§6.5) para o assinante
        var ecoRecebido = false
        let deadline = Date().addingTimeInterval(5)
        for await event in client.events {
            if event.knownTopic == .documentOp,
               let payload = try? event.decodeParams(DocumentOpTopicPayload.self) {
                #expect(payload.seq == 1)
                #expect(payload.op.tipo == .nodeAdd)
                #expect(payload.op.anterior == nil)
                ecoRecebido = true
                break
            }
            if Date() > deadline { break }
        }
        #expect(ecoRecebido)

        // workspace_not_found com nome estável (§6.6)
        do {
            _ = try await client.call(.docSnapshot, params: DocSnapshotParams(workspaceID: ULID.generate()))
            Issue.record("deveria falhar")
        } catch let error as ProtocolError {
            #expect(error.known == .workspace_not_found)
        }

        let status = try await client.call(.engineStatus, expecting: EngineStatusResult.self)
        #expect(status.workspacesAbertos == 1)
        #expect(status.sessionsAtivas == 0)
        client.close()
    }

    @Test func sessaoRealJournalEReplay() async throws {
        let (engine, client, _) = try boot()
        defer { engine.stop() }
        _ = try await client.hello(client: "test")
        let created = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "pty"), expecting: WorkspaceResult.self)
        let wsID = created.workspace.id
        let node = makeTerminalNode(nome: "Echo", override: "printf 'ola-colmeia'; sleep 0.2")
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: wsID, ops: [proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(node))))]))
        let started = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: wsID, nodeID: node.id),
            expecting: SessionResult.self)
        #expect(started.session.estado == .iniciando)
        #expect(started.session.pid != nil)

        // segundo start no mesmo nó → session_already_running (§24.2)
        do {
            _ = try await client.call(.sessionStart, params: SessionStartParams(workspaceID: wsID, nodeID: node.id))
            Issue.record("deveria falhar")
        } catch let error as ProtocolError {
            #expect(error.known == .session_already_running)
        }

        // espera encerrar
        var final: Session?
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let list = try await client.call(
                .sessionList, params: SessionListParams(workspaceID: wsID), expecting: [Session].self)
            if let session = list.first(where: { $0.id == started.session.id }), !session.estado.isViva {
                final = session
                break
            }
        }
        #expect(final?.estado == .encerrada) // exit 0

        // replay da sessão encerrada (§8.4): seq contínuo desde 1, output presente, authors válidos
        let replay = try await client.call(
            .sessionReplay, params: SessionReplayParams(sessionID: started.session.id),
            expecting: SessionReplayResult.self)
        #expect(!replay.events.isEmpty)
        #expect(replay.events.map(\.seq) == Array(1...UInt64(replay.events.count)))
        let outputs = replay.events.compactMap { event -> Data? in
            if case .output(let payload) = event.payload { return Data(base64Encoded: payload.dataB64) }
            return nil
        }
        let texto = outputs.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(texto.contains("ola-colmeia"))
        let estadosFinais = replay.events.compactMap { event -> SessionEstado? in
            if case .state(let payload) = event.payload { return payload.para }
            return nil
        }
        #expect(estadosFinais.contains(.encerrada))
        client.close()
    }

    @Test func adapterQueExplodeDegradaSemMatarASessao() async throws {
        let (engine, client, _) = try boot()
        defer { engine.stop() }
        _ = try await client.hello(client: "test")
        let created = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "deg"), expecting: WorkspaceResult.self)
        let wsID = created.workspace.id
        let node = makeTerminalNode(nome: "Kaboom", adapter: "explosivo")
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: wsID, ops: [proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(node))))]))
        let started = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: wsID, nodeID: node.id),
            expecting: SessionResult.self)
        var final: Session?
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let list = try await client.call(
                .sessionList, params: SessionListParams(workspaceID: wsID), expecting: [Session].self)
            if let session = list.first(where: { $0.id == started.session.id }), !session.estado.isViva {
                final = session
                break
            }
        }
        #expect(final?.estado == .encerrada) // 25.3.2 — degradou, mas o terminal viveu até o fim
        let replay = try await client.call(
            .sessionReplay, params: SessionReplayParams(sessionID: started.session.id),
            expecting: SessionReplayResult.self)
        let systemEvents = replay.events.compactMap { event -> SystemEventPayload? in
            if case .system(let payload) = event.payload { return payload }
            return nil
        }
        #expect(systemEvents.contains { $0.name == "adapter_degradado" })
        client.close()
    }

    @Test func rotinaAlvoAusenteAutoDesabilita() async throws {
        let (engine, client, _) = try boot()
        defer { engine.stop() }
        _ = try await client.hello(client: "test")
        let created = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "rot"), expecting: WorkspaceResult.self)
        let wsID = created.workspace.id
        let node = makeTerminalNode(nome: "Alvo")
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: wsID, ops: [proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(node))))]))
        let routine = try await client.call(
            .routineCreate,
            params: RoutineCreateParams(
                nome: "ping", workspaceID: wsID, alvo: node.id, comando: "echo ping",
                agenda: Agenda(tipo: .intervalo, intervaloSeg: 3600, inicio: Date())),
            expecting: RoutineResult.self)
        // sem sessão viva: 3 execuções → pulada_alvo_ausente + auto-desabilitada (25.6.4)
        for _ in 0..<3 {
            let run = try await client.call(
                .routineRunNow, params: RoutineRunNowParams(routineID: routine.routine.id),
                expecting: RoutineRunNowResult.self)
            #expect(run.resultado == .puladaAlvoAusente)
        }
        let list = try await client.call(
            .routineList, params: RoutineListParams(workspaceID: wsID), expecting: [Routine].self)
        #expect(list.first?.habilitada == false)
        #expect(list.first?.ultimaExecucao?.resultado == .puladaAlvoAusente)
        client.close()
    }

    @Test func attachEmendaReplayComVivoSemBuracoNemDuplicata() async throws {
        let (engine, client, _) = try boot()
        defer { engine.stop() }
        _ = try await client.hello(client: "test")
        let created = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "att"), expecting: WorkspaceResult.self)
        let wsID = created.workspace.id
        _ = try await client.call(
            .subscribe, params: SubscribeParams(topics: [.sessionState], workspaceID: wsID))
        let node = makeTerminalNode(
            nome: "Fluxo", override: "for i in $(seq 1 30); do printf \"linha-$i \"; sleep 0.02; done")
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: wsID, ops: [proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(node))))]))
        let started = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: wsID, nodeID: node.id),
            expecting: SessionResult.self)
        try await Task.sleep(nanoseconds: 200_000_000) // deixa parte do output acontecer antes do attach
        let attach = try await client.call(
            .sessionAttach, params: SessionAttachParams(sessionID: started.session.id),
            expecting: SessionAttachResult.self)
        let replaySeqs = attach.replay.filter { $0.tipo == .output }.map(\.seq)
        var liveSeqs: [UInt64] = []
        for await event in client.events {
            if event.knownTopic == .sessionOutput,
               let payload = try? event.decodeParams(SessionOutputTopicPayload.self),
               payload.sessionID == started.session.id {
                liveSeqs.append(payload.seq)
            }
            if event.knownTopic == .sessionState,
               let payload = try? event.decodeParams(SessionStateTopicPayload.self),
               payload.sessionID == started.session.id, !payload.estado.isViva {
                break // sessão encerrou — todo output já foi publicado antes (stateQueue serial)
            }
        }
        // 25.2.1 — emenda sem duplicata (replay ∩ vivo = ∅)…
        #expect(Set(replaySeqs).isDisjoint(with: Set(liveSeqs)))
        // …e sem buraco: replay ∪ vivo == exatamente os outputs do journal completo
        let full = try await client.call(
            .sessionReplay, params: SessionReplayParams(sessionID: started.session.id),
            expecting: SessionReplayResult.self)
        let fullOutputSeqs = Set(full.events.filter { $0.tipo == .output }.map(\.seq))
        #expect(Set(replaySeqs).union(liveSeqs) == fullOutputSeqs)
        #expect(!liveSeqs.isEmpty, "attach no meio do stream deveria receber vivo")
        client.close()
    }
}
