import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

// MARK: - Dedupe do VIVO (§8.4 estendido): attach + re-attach nunca duplicam
//
// O sintoma real na tela ("mesma frase 2x") teria duas fontes possíveis:
// (a) o engine reentregar `session.output` após um segundo attach (recriação do
//     nó / reabertura do workspace) — coberto pelo piso de seq por cliente;
// (b) o cliente alimentar o emulador duas vezes com o mesmo evento — coberto
//     pelo piso `lastSeq` do TerminalReplay, que o controller usa também no vivo.
// Estes testes exercitam os dois contra o engine REAL pelo socket.

private func tempRoot() -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("colm-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeTerminalNode(nome: String, override: String? = nil) -> TerminalNode {
    TerminalNode(
        id: ULID.generate(), posicao: Ponto(x: 0, y: 0), tamanho: Tamanho(w: 400, h: 300),
        criadoEm: Date(), nome: nome, adapter: "shell", comandoOverride: override, cwd: NSHomeDirectory())
}

private func proposal(_ payload: OpPayload) -> DocOp {
    DocOp(opID: ULID.generate(), author: .humanoLocal, ts: Date(), payload: payload)
}

/// Evento `output` sintético a partir do payload do tópico vivo — exatamente a
/// conversão que o controller faz antes de aplicar o piso de seq.
private func vivoComoEvento(_ payload: SessionOutputTopicPayload) -> Event {
    Event(
        seq: payload.seq, ts: Date(), author: .sistema,
        payload: .output(OutputEventPayload(dataB64: payload.dataB64)))
}

/// Bytes efetivamente alimentados no emulador por um plano (só ações .feed).
private func bytesAlimentados(_ acoes: [TerminalReplay.Acao]) -> Data {
    acoes.reduce(into: Data()) { acc, acao in
        if case .feed(let data) = acao { acc.append(data) }
    }
}

@Suite("Dedupe do vivo — attach/reattach (§8.4)", .serialized)
struct TerminalLiveDedupeTests {
    private func boot() throws -> (Engine, SocketClient, URL) {
        let root = tempRoot()
        let engine = Engine(paths: ColmeiaPaths(root: root))
        try engine.start()
        let client = SocketClient()
        try client.connect(to: ColmeiaPaths(root: root).engineSocket.path)
        return (engine, client, root)
    }

    /// Recriação do nó no meio do stream: o controller novo re-attacha SEM
    /// `desde_seq` (replay completo) enquanto o vivo continua fluindo. O engine
    /// NÃO pode reentregar seqs já publicados, e o piso do cliente NÃO pode
    /// alimentar duas vezes o que o replay e o vivo trazem em sobreposição.
    @Test func reattachNoMeioDoStreamNaoDuplicaNemFura() async throws {
        let (engine, client, _) = try boot()
        defer { engine.stop() }
        _ = try await client.hello(client: "test")
        let created = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "dedupe"), expecting: WorkspaceResult.self)
        let wsID = created.workspace.id
        _ = try await client.call(
            .subscribe, params: SubscribeParams(topics: [.sessionState], workspaceID: wsID))
        let node = makeTerminalNode(
            nome: "Vivo", override: "for i in $(seq 1 60); do printf \"tokentown-linha-$i \"; sleep 0.02; done")
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: wsID, ops: [proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(node))))]))
        let started = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: wsID, nodeID: node.id),
            expecting: SessionResult.self)
        let sessionID = started.session.id

        // Coletor consome o stream de eventos em paralelo às chamadas (como a UI).
        let collector = Task { () -> [SessionOutputTopicPayload] in
            var vivos: [SessionOutputTopicPayload] = []
            for await event in client.events {
                if event.knownTopic == .sessionOutput,
                   let payload = try? event.decodeParams(SessionOutputTopicPayload.self),
                   payload.sessionID == sessionID {
                    vivos.append(payload)
                }
                if event.knownTopic == .sessionState,
                   let payload = try? event.decodeParams(SessionStateTopicPayload.self),
                   payload.sessionID == sessionID, !payload.estado.isViva {
                    break // stateQueue serial: todo output já foi publicado antes
                }
            }
            return vivos
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        let attach1 = try await client.call(
            .sessionAttach, params: SessionAttachParams(sessionID: sessionID),
            expecting: SessionAttachResult.self)
        try await Task.sleep(nanoseconds: 300_000_000)
        // "Recriação do nó": controller novo, lastSeq zerado → attach sem desde_seq.
        let attach2 = try await client.call(
            .sessionAttach, params: SessionAttachParams(sessionID: sessionID),
            expecting: SessionAttachResult.self)
        let vivos = await collector.value

        let replay1Seqs = attach1.replay.filter { $0.tipo == .output }.map(\.seq)
        let replay2Seqs = attach2.replay.filter { $0.tipo == .output }.map(\.seq)
        let vivoSeqs = vivos.map(\.seq)

        // O gate não pode ser oco: o segundo replay TEM que sobrepor o vivo já
        // entregue (é essa sobreposição que causaria a duplicação na tela).
        #expect(!Set(replay2Seqs).intersection(vivoSeqs).isEmpty,
                "re-attach deveria sobrepor output já publicado ao vivo")

        // Engine: nunca reentrega — o stream vivo é estritamente crescente
        // mesmo com dois attaches na mesma conexão.
        #expect(zip(vivoSeqs, vivoSeqs.dropFirst()).allSatisfy { $0 < $1 },
                "session.output reentregue/desordenado: \(vivoSeqs)")

        // Sem buraco: replay ∪ vivo cobre exatamente os outputs do journal.
        let full = try await client.call(
            .sessionReplay, params: SessionReplayParams(sessionID: sessionID),
            expecting: SessionReplayResult.self)
        let outputsDoJournal = full.events.filter { $0.tipo == .output }
        #expect(Set(replay1Seqs).union(replay2Seqs).union(vivoSeqs)
            == Set(outputsDoJournal.map(\.seq)))
        #expect(!vivoSeqs.isEmpty, "attach no meio do stream deveria receber vivo")

        // Cliente (ponto único de ingestão): replay1 → vivo → replay2 com o MESMO
        // piso de seq alimenta o emulador com cada byte exatamente uma vez.
        var lastSeq: UInt64 = 0
        var alimentado = Data()
        alimentado += bytesAlimentados(TerminalReplay.plan(events: attach1.replay, lastSeq: &lastSeq))
        alimentado += bytesAlimentados(TerminalReplay.plan(events: vivos.map(vivoComoEvento), lastSeq: &lastSeq))
        alimentado += bytesAlimentados(TerminalReplay.plan(events: attach2.replay, lastSeq: &lastSeq))
        let esperado = outputsDoJournal.reduce(into: Data()) { acc, event in
            if case .output(let payload) = event.payload, let data = Data(base64Encoded: payload.dataB64) {
                acc.append(data)
            }
        }
        #expect(alimentado == esperado, "bytes alimentados divergem do journal (dup ou buraco)")
        client.close()
    }

    /// Reabrir um nó encerrado (replay completo duas vezes): com o piso preservado
    /// o segundo replay não alimenta NADA; com controller recriado (piso zerado,
    /// emulador novo) reconstrói exatamente os mesmos bytes — nunca o dobro.
    @Test func reabrirNoEncerradoNaoRealimentaOEmulador() async throws {
        let (engine, client, _) = try boot()
        defer { engine.stop() }
        _ = try await client.hello(client: "test")
        let created = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "reopen"), expecting: WorkspaceResult.self)
        let wsID = created.workspace.id
        _ = try await client.call(
            .subscribe, params: SubscribeParams(topics: [.sessionState], workspaceID: wsID))
        let node = makeTerminalNode(nome: "Curto", override: "printf 'alfa beta gama'")
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: wsID, ops: [proposal(.nodeAdd(NodeAddOpPayload(node: .terminal(node))))]))
        let started = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: wsID, nodeID: node.id),
            expecting: SessionResult.self)
        for await event in client.events {
            if event.knownTopic == .sessionState,
               let payload = try? event.decodeParams(SessionStateTopicPayload.self),
               payload.sessionID == started.session.id, !payload.estado.isViva {
                break
            }
        }

        let attach1 = try await client.call(
            .sessionAttach, params: SessionAttachParams(sessionID: started.session.id),
            expecting: SessionAttachResult.self)
        let attach2 = try await client.call(
            .sessionAttach, params: SessionAttachParams(sessionID: started.session.id),
            expecting: SessionAttachResult.self)

        var lastSeq: UInt64 = 0
        let fed1 = bytesAlimentados(TerminalReplay.plan(events: attach1.replay, lastSeq: &lastSeq))
        #expect(!fed1.isEmpty)
        // Mesmo controller (piso preservado): segundo replay é no-op absoluto.
        let fed2 = bytesAlimentados(TerminalReplay.plan(events: attach2.replay, lastSeq: &lastSeq))
        #expect(fed2.isEmpty, "re-attach com piso preservado realimentou o emulador")
        // Controller recriado (piso zerado + emulador NOVO): mesma tela, não o dobro.
        var lastSeqNovo: UInt64 = 0
        let fedNovo = bytesAlimentados(TerminalReplay.plan(events: attach2.replay, lastSeq: &lastSeqNovo))
        #expect(fedNovo == fed1)
        client.close()
    }
}
