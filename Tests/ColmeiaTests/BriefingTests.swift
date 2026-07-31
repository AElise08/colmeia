import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

// Raiz temporária CURTA (sockaddr_un ~104 bytes), como em EngineTests.
private func tempRoot() -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("colmb-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeTerminalNode(
    nome: String, papel: String? = nil, adapter: String = "shell", override: String? = nil
) -> TerminalNode {
    TerminalNode(
        id: ULID.generate(), posicao: Ponto(x: 0, y: 0), tamanho: Tamanho(w: 400, h: 300),
        criadoEm: Date(), nome: nome, papel: papel, adapter: adapter,
        comandoOverride: override, cwd: NSHomeDirectory())
}

private func proposal(_ payload: OpPayload, author: Author = .humanoLocal) -> DocOp {
    DocOp(opID: ULID.generate(), author: author, ts: Date(), payload: payload)
}

private func makeConfig(_ node: TerminalNode, conexoes: [ConexaoVizinha] = []) -> LaunchConfig {
    let now = Date()
    let workspace = Workspace(id: ULID.generate(), nome: "ws", criadoEm: now, atualizadoEm: now)
    return LaunchConfig(node: node, workspace: workspace, conexoes: conexoes)
}

// MARK: - Briefing dos adapters (consciência do Colmeia)

@Suite("Briefing de consciência do Colmeia")
struct BriefingTests {
    @Test func claudeCodeInjetaBriefingComNomePapelEConexoes() {
        let node = makeTerminalNode(nome: "Plinio", papel: "Pesquisador", adapter: "claude-code")
        let vizinho = ConexaoVizinha(nome: "Beta", adapter: "opencode", papel: "Coder")
        let plan = ClaudeCodeAdapter().launch(makeConfig(node, conexoes: [vizinho]))

        #expect(plan.executavel == "claude")
        guard let flagIdx = plan.args.firstIndex(of: "--append-system-prompt"),
              plan.args.indices.contains(flagIdx + 1)
        else {
            Issue.record("LaunchPlan sem --append-system-prompt <texto>: \(plan.args)")
            return
        }
        let briefing = plan.args[flagIdx + 1]
        // gate não-oco: identidade, descoberta da integração, delegação e topologia
        #expect(briefing.contains("Colmeia"))
        #expect(briefing.contains("Plinio"))
        #expect(briefing.contains("Pesquisador"))
        #expect(briefing.contains("Descubra os comandos disponíveis no PATH"))
        #expect(briefing.contains("notas conectadas"))
        #expect(briefing.contains("item correspondente como concluído"))
        #expect(briefing.contains("mecanismo de comunicação descoberto"))
        #expect(briefing.contains("integração local com o canvas"))
        #expect(briefing.contains("crie-o pelo canvas"))
        #expect(briefing.contains("navegador embutido"))
        #expect(briefing.contains("\"Beta\" (opencode, papel Coder)"))
        #expect(!briefing.contains("`colmeia"))
        // env informativa junto
        #expect(plan.envExtra[ColmeiaEnv.nodeNome] == "Plinio")
        #expect(plan.envExtra[ColmeiaEnv.nodePapel] == "Pesquisador")
        #expect(plan.envExtra[ColmeiaEnv.canvasSkill] == "1")
    }

    @Test func briefingSemConexoesApontaParaOStatus() {
        let node = makeTerminalNode(nome: "Solo", adapter: "claude-code")
        let plan = ClaudeCodeAdapter().launch(makeConfig(node))
        guard let flagIdx = plan.args.firstIndex(of: "--append-system-prompt"),
              plan.args.indices.contains(flagIdx + 1)
        else {
            Issue.record("LaunchPlan sem --append-system-prompt <texto>: \(plan.args)")
            return
        }
        let briefing = plan.args[flagIdx + 1]
        #expect(briefing.contains("não tem conexões"))
    }

    @Test func comandoOverrideEhSagradoSemBriefingNosArgs() {
        let node = makeTerminalNode(
            nome: "Custom", adapter: "claude-code", override: "claude --continue")
        let plan = ClaudeCodeAdapter().launch(makeConfig(node))
        // override substitui executável+args (§10.2): o briefing NÃO entra no plano
        #expect(!plan.args.contains("--append-system-prompt"))
        // …mas a env informativa continua (o engine preserva env_extra no override)
        #expect(plan.envExtra[ColmeiaEnv.nodeNome] == "Custom")
    }

    @Test func todosAdaptersExportamEnvInformativaDoNo() {
        let node = makeTerminalNode(nome: "Env")
        let adapters: [any AgentAdapter] = [
            ShellAdapter(), ClaudeCodeAdapter(), CodexAdapter(), GeminiCliAdapter(), OpenCodeAdapter(),
        ]
        for adapter in adapters {
            let plan = adapter.launch(makeConfig(node))
            #expect(plan.envExtra[ColmeiaEnv.nodeNome] == "Env", "adapter \(adapter.id)")
            #expect(plan.envExtra[ColmeiaEnv.nodePapel] == "", "adapter \(adapter.id)")
            #expect(plan.envExtra[ColmeiaEnv.canvasSkill] == "1", "adapter \(adapter.id)")
        }
    }

    @Test func codexEOpenCodeRecebemBriefingSemTurnoVisivel() {
        let node = makeTerminalNode(nome: "Alfie", adapter: "codex")
        let config = makeConfig(node)
        let codex = CodexAdapter().launch(config)
        #expect(codex.args.first == "-c")
        #expect(codex.args.dropFirst().first?.contains("developer_instructions=") == true)
        #expect(codex.args.dropFirst().first?.contains("Descubra os comandos disponíveis no PATH") == true)
        #expect(codex.args.dropFirst().first?.contains("`colmeia") == false)

        let openCode = OpenCodeAdapter().launch(config)
        #expect(openCode.args.first == "--prompt")
        #expect(openCode.args.dropFirst().first?.contains("Descubra os comandos disponíveis no PATH") == true)
        #expect(openCode.args.dropFirst().first?.contains("`colmeia") == false)
    }

    @Test func codexRetomaQuandoOEngineGaranteUmaCasaIsolada() {
        let node = makeTerminalNode(nome: "Alfie", adapter: "codex")
        let config = LaunchConfig(node: node, workspace: makeConfig(node).workspace, retomarSessao: true)
        let plan = CodexAdapter().launch(config)

        #expect(plan.args.contains("resume"))
        #expect(plan.args.contains("--last"))
    }

    @Test func codexRecebeModeloEscolhidoDoAgente() {
        let node = makeTerminalNode(nome: "Alfie", adapter: "codex")
        let config = LaunchConfig(
            node: node, workspace: makeConfig(node).workspace, modelo: "gpt-test-model")
        let plan = CodexAdapter().launch(config)

        #expect(plan.args.prefix(2) == ["-m", "gpt-test-model"])
    }

    @Test func casaDoCodexPorAgenteNaoConfundeSessoes() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ColmeiaPaths(root: root)
        let workspaceID = ULID.generate()
        let first = try CodexAgentHome.prepare(
            paths: paths, workspaceID: workspaceID, nodeID: ULID.generate(), inheritedEnvironment: [:])
        let second = try CodexAgentHome.prepare(
            paths: paths, workspaceID: workspaceID, nodeID: ULID.generate(), inheritedEnvironment: [:])
        let sessionFile = first.appendingPathComponent("sessions/2026/07/30/agent.jsonl")
        try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: sessionFile)

        #expect(CodexAgentHome.hasSession(in: first))
        #expect(!CodexAgentHome.hasSession(in: second))
    }
}

// MARK: - Consciência pelo socket (env no PTY + notificação de conexão)

@Suite("Consciência do canvas pelo socket", .serialized)
struct CanvasAwarenessSocketTests {
    private func boot() throws -> (Engine, SocketClient, URL) {
        let root = tempRoot()
        let engine = Engine(paths: ColmeiaPaths(root: root))
        try engine.start()
        let client = SocketClient()
        try client.connect(to: ColmeiaPaths(root: root).engineSocket.path)
        return (engine, client, root)
    }

    private func replayTexto(_ client: SocketClient, _ sessionID: ULID) async throws -> String {
        let replay = try await client.call(
            .sessionReplay, params: SessionReplayParams(sessionID: sessionID),
            expecting: SessionReplayResult.self)
        return replay.events.compactMap { event -> String? in
            if case .output(let payload) = event.payload,
               let data = Data(base64Encoded: payload.dataB64) {
                return String(decoding: data, as: UTF8.self)
            }
            return nil
        }.joined()
    }

    /// Eventos `system {name: conexao}` do journal da sessão.
    private func avisosDeConexao(_ client: SocketClient, _ sessionID: ULID) async throws -> [String] {
        let replay = try await client.call(
            .sessionReplay, params: SessionReplayParams(sessionID: sessionID),
            expecting: SessionReplayResult.self)
        return replay.events.compactMap { event -> String? in
            if case .system(let payload) = event.payload, payload.name == "conexao" {
                return payload.message
            }
            return nil
        }
    }

    @Test func envDoPTYContemNomeEPapelDoNo() async throws {
        let (engine, client, _) = try boot()
        defer { engine.stop() }
        _ = try await client.hello(client: "test")
        let created = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "env2"), expecting: WorkspaceResult.self)
        let wsID = created.workspace.id
        let node = makeTerminalNode(nome: "Plinio", papel: "Pesquisador", override: "env; sleep 0.2")
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: wsID, ops: [proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(node))))]))
        let started = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: wsID, nodeID: node.id),
            expecting: SessionResult.self)
        var terminou = false
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let list = try await client.call(
                .sessionList, params: SessionListParams(workspaceID: wsID), expecting: [Session].self)
            if let session = list.first(where: { $0.id == started.session.id }), !session.estado.isViva {
                terminou = true
                break
            }
        }
        #expect(terminou)
        let texto = try await replayTexto(client, started.session.id)
        // §10.2 + extensão: env informativa chega ao PTY mesmo com comando_override
        #expect(texto.contains("COLMEIA_NODE_NOME=Plinio"))
        #expect(texto.contains("COLMEIA_NODE_PAPEL=Pesquisador"))
        #expect(texto.contains("COLMEIA_CANVAS_SKILL=1"))
        client.close()
    }

    @Test func notificacaoDeConexaoRespeitaElegibilidadeEEntraNoJournal() async throws {
        let (engine, client, _) = try boot()
        defer { engine.stop() }
        _ = try await client.hello(client: "test")
        let created = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "topo"), expecting: WorkspaceResult.self)
        let wsID = created.workspace.id
        // `cat` mantém a sessão viva sem output espontâneo — estado controlável no teste
        let alfa = makeTerminalNode(nome: "Alfa", override: "printf pronto; cat")
        let beta = makeTerminalNode(nome: "Beta", papel: "Coder", override: "printf pronto; cat")
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: wsID, ops: [
                proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(alfa)))),
                proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(beta)))),
            ]))
        let sessaoAlfa = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: wsID, nodeID: alfa.id),
            expecting: SessionResult.self).session.id
        let sessaoBeta = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: wsID, nodeID: beta.id),
            expecting: SessionResult.self).session.id

        // espera o primeiro output (iniciando → rodando) nas duas sessões
        var rodando = false
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let list = try await client.call(
                .sessionList, params: SessionListParams(workspaceID: wsID), expecting: [Session].self)
            let estados = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.estado) })
            if estados[sessaoAlfa] == .rodando, estados[sessaoBeta] == .rodando {
                rodando = true
                break
            }
        }
        #expect(rodando)

        // Beta elegível (esperando_humano); Alfa segue rodando (inelegível)
        engine.stateQueue.sync {
            if let live = engine.sessions[sessaoBeta] {
                engine.transition(live, to: .esperandoHumano, motivo: "teste")
            }
        }

        let conexao = Connection(
            id: ULID.generate(), de: alfa.id, para: beta.id, semantica: .conversa, estilo: .tracejada)
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: wsID, ops: [
                proposal(.connectionAdd(ConnectionAddOpPayload(connection: conexao))),
            ]))

        // Beta (elegível): aviso imediato — evento system no journal + linha no PTY
        var avisoBeta: String?
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let aviso = try await avisosDeConexao(client, sessaoBeta).first {
                avisoBeta = aviso
                break
            }
        }
        #expect(avisoBeta?.contains("conectado ao nó \"Alfa\"") == true)
        #expect(avisoBeta?.contains("mecanismo de descoberta de comandos") == true)
        // a linha foi de fato injetada no PTY (cat ecoa o input)
        let ecoBeta = try await replayTexto(client, sessaoBeta)
        #expect(ecoBeta.contains("[colmeia] conectado"))

        // Alfa (rodando): NADA ainda — elegibilidade §14.2 (gate negativo não-oco)
        try await Task.sleep(nanoseconds: 700_000_000)
        let avisosAntes = try await avisosDeConexao(client, sessaoAlfa)
        #expect(avisosAntes.isEmpty, "aviso atropelou turno de Alfa: \(avisosAntes)")

        // Alfa fica elegível → o aviso adiado é entregue, com papel do vizinho
        engine.stateQueue.sync {
            if let live = engine.sessions[sessaoAlfa] {
                engine.transition(live, to: .ociosa, motivo: "teste")
            }
        }
        var avisoAlfa: String?
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let aviso = try await avisosDeConexao(client, sessaoAlfa).first {
                avisoAlfa = aviso
                break
            }
        }
        #expect(avisoAlfa?.contains("conectado ao nó \"Beta\" (shell, papel Coder)") == true)

        // remoção: Beta elegível de novo recebe o aviso de desfeita
        engine.stateQueue.sync {
            if let live = engine.sessions[sessaoBeta] {
                engine.transition(live, to: .esperandoHumano, motivo: "teste")
            }
        }
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: wsID, ops: [
                proposal(.connectionDelete(ConnectionDeleteOpPayload(id: conexao.id))),
            ]))
        var desfeita = false
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let avisos = try await avisosDeConexao(client, sessaoBeta)
            if avisos.contains(where: { $0.contains("conexão com o nó \"Alfa\" desfeita") }) {
                desfeita = true
                break
            }
        }
        #expect(desfeita)
        client.close()
    }

    @Test func conexaoDeNotaFicaNoJournalSemSerInjetadaNoTerminal() async throws {
        let (engine, client, _) = try boot()
        defer { engine.stop() }
        _ = try await client.hello(client: "test")
        let workspace = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "nota-sem-chat"), expecting: WorkspaceResult.self).workspace
        let terminal = makeTerminalNode(nome: "Alfie", override: "printf pronto; cat")
        let note = NotaNode(
            id: ULID.generate(), posicao: Ponto(x: 500, y: 0), tamanho: Tamanho(w: 300, h: 200),
            criadoEm: Date(), arquivo: "notes/test.md", cor: "amarela")
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: workspace.id, ops: [
                proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(terminal)))),
                proposal(.nodeAdd(NodeAddOpPayload(node: .nota(note)))),
            ]))
        let sessionID = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: workspace.id, nodeID: terminal.id),
            expecting: SessionResult.self).session.id

        engine.stateQueue.sync {
            if let live = engine.sessions[sessionID] {
                engine.transition(live, to: .esperandoHumano, motivo: "teste")
            }
        }
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: workspace.id, ops: [proposal(.connectionAdd(
                ConnectionAddOpPayload(connection: Connection(
                    id: ULID.generate(), de: terminal.id, para: note.id,
                    semantica: .escritaDeNota, estilo: .solida))))]))

        let avisos = try await avisosDeConexao(client, sessionID)
        #expect(avisos.contains { $0.contains("nota conectada ao seu nó") })
        let textoDoTerminal = try await replayTexto(client, sessionID)
        #expect(!textoDoTerminal.contains("[colmeia] nota conectada"))
        client.close()
    }
}
