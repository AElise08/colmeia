import Foundation
import Testing
@testable import ColmeiaKit
import ColmeiaEngine

@Suite("ULID")
struct ULIDTests {
    @Test func formaCanonica() {
        let ulid = ULID.generate()
        #expect(ulid.string.count == 26)
        #expect(ULID.isValid(ulid.string))
        #expect(ULID(ulid.string) == ulid)
    }

    @Test func ordenavelPorTempoEMonotonico() {
        let now = Date()
        var anterior = ULID.generate(now: now)
        for _ in 0..<1000 {
            let atual = ULID.generate(now: now)
            #expect(anterior < atual)
            anterior = atual
        }
        let depois = ULID.generate(now: now.addingTimeInterval(1))
        #expect(anterior < depois)
    }

    @Test func rejeitaInvalidos() {
        #expect(ULID("") == nil)
        #expect(ULID("01ARZ3NDEKTSV4RRFFQ69G5FA") == nil)
        #expect(ULID("81ARZ3NDEKTSV4RRFFQ69G5FAV") == nil)
        #expect(ULID("01ARZ3NDEKTSV4RRFFQ69G5FAU") == nil)
        #expect(ULID("01arz3ndektsv4rrffq69g5fav")?.string == "01ARZ3NDEKTSV4RRFFQ69G5FAV")
    }

    @Test func codableComoString() throws {
        let ulid = ULID.generate()
        let data = try ColmeiaJSON.encoder().encode([ulid])
        #expect(String(data: data, encoding: .utf8) == "[\"\(ulid.string)\"]")
        let roundtrip = try ColmeiaJSON.decoder().decode([ULID].self, from: data)
        #expect(roundtrip == [ulid])
    }
}

@Suite("Protocolo §6")
struct ProtocolTests {
    @Test func envelopeRequestDaSpec() throws {
        let line = Data(#"{"kind":"request","id":"r-1","method":"hello","params":{"protocol_version":1,"client":"cli","author":"humano:local"}}"#.utf8)
        let envelope = try SocketFraming.decodeLine(Envelope.self, from: line)
        guard case .request(let request) = envelope else {
            Issue.record("esperava request")
            return
        }
        #expect(request.knownMethod == .hello)
        let params = try request.decodeParams(HelloParams.self)
        #expect(params.protocolVersion == 1)
        #expect(params.author == .humanoLocal)
    }

    @Test func envelopeErroPreservaNameSnakeCase() throws {
        let response = ResponseMessage(
            id: "r-2",
            error: ProtocolError(name: .session_not_found, message: "sessão não existe")
        )
        let data = try SocketFraming.encodeLine(Envelope.response(response))
        let texto = String(decoding: data, as: UTF8.self)
        #expect(texto.contains(#""name":"session_not_found""#))
        let roundtrip = try SocketFraming.decodeLine(Envelope.self, from: data)
        guard case .response(let decoded) = roundtrip else {
            Issue.record("esperava response")
            return
        }
        #expect(decoded.ok == false)
        #expect(decoded.error?.known == .session_not_found)
    }

    @Test func todosOsErrosDaSecao66() {
        let esperados = [
            "protocol_version_mismatch", "workspace_not_found", "node_not_found",
            "session_not_found", "session_already_running", "session_not_running",
            "duplicate_node_name", "adapter_not_found", "adapter_launch_failed",
            "approval_not_found", "approval_already_resolved", "routine_not_found",
            "routine_target_missing", "floor_not_found", "floor_dirty",
            "floor_mechanism_unavailable", "journal_corrupted", "document_corrupted",
            "invalid_params", "confirmation_required", "internal_error",
            "room_not_found", "room_already_exists",
            "member_not_found", "member_already_exists", "member_revoked",
            "invite_invalid", "invite_expired",
            "agent_session_not_found", "agent_session_archived",
            "handoff_invalid", "handoff_already_pending", "conductor_required",
            "grant_not_found", "grant_expired", "grant_revoked",
            "insufficient_permissions", "idempotency_conflict",
            "lease_invalid", "lease_expired",
        ]
        #expect(ProtocolErrorName.allCases.map(\.rawValue) == esperados)
    }

    @Test func inventarioDeMetodos() {
        // 88 base multiplayer + 20 mission model (mission/workstream/decision/relation)
        #expect(ColmeiaMethod.allCases.count == 127)
        #expect(ColmeiaMethod(rawValue: "routine.run_now") == .routineRunNow)
        #expect(ColmeiaMethod(rawValue: "doc.apply") == .docApply)
        #expect(ColmeiaMethod(rawValue: "portal.open") == .portalOpen)
        #expect(ColmeiaMethod(rawValue: "memory.propose") == .memoryPropose)
        #expect(ColmeiaMethod(rawValue: "delivery.submit") == .deliverySubmit)
        #expect(ColmeiaMethod(rawValue: "worker.restore") == .workerRestore)
        #expect(ColmeiaMethod(rawValue: "mission.create") == .missionCreate)
        #expect(ColmeiaMethod(rawValue: "workstream.briefing") == .workstreamBriefing)
        #expect(ColmeiaMethod(rawValue: "decision.decide") == .decisionDecide)
        #expect(ColmeiaMethod(rawValue: "relation.add") == .relationAdd)
    }

    @Test func estadosFinaisDeDelegacaoSaoExplicitos() {
        #expect(!DelegationEstado.queued.isTerminal)
        #expect(!DelegationEstado.running.isTerminal)
        #expect(!DelegationEstado.waitingApproval.isTerminal)
        #expect(DelegationEstado.completed.isTerminal)
        #expect(DelegationEstado.failed.isTerminal)
        #expect(DelegationEstado.canceled.isTerminal)
    }

    @Test func membroLegadoPreservaPapelSingular() throws {
        let data = Data(
            #"{"id":"legacy","display_name":"Legacy","role":"owner","status":"active","joined_at":"2026-07-25T00:03:23.634Z"}"#.utf8)
        let member = try ColmeiaJSON.decoder().decode(Member.self, from: data)
        #expect(member.roles == [.owner])
    }

    @Test func membroLegadoConverteObserverParaViewer() throws {
        let data = Data(
            #"{"id":"legacy","roles":["observer"],"status":"active","joined_at":"2026-07-25T00:03:23.634Z"}"#.utf8)
        let member = try ColmeiaJSON.decoder().decode(Member.self, from: data)
        #expect(member.roles == [.viewer])
    }

    @Test func topicos() {
        // 19 base + 13 multiplayer + 2 event ack/reject = 29
        #expect(ColmeiaTopic.allCases.count == 29)
        #expect(ColmeiaTopic(rawValue: "session.output") == .sessionOutput)
        #expect(ColmeiaTopic(rawValue: "engine.warning") == .engineWarning)
        #expect(ColmeiaTopic(rawValue: "memory.changed") == .memoryChanged)
        #expect(ColmeiaTopic(rawValue: "worker.archived") == .workerArchived)
    }

    @Test func campoDesconhecidoIgnorado() throws {
        let line = Data(#"{"kind":"event","topic":"engine.warning","params":{"name":"x","message":"y"},"novo_campo":42}"#.utf8)
        let envelope = try SocketFraming.decodeLine(Envelope.self, from: line)
        guard case .event(let event) = envelope else {
            Issue.record("esperava event")
            return
        }
        let payload = try event.decodeParams(EngineWarningTopicPayload.self)
        #expect(payload.name == "x")
    }
}

@Suite("Domínio §5 e ops §7.2")
struct DomainTests {
    /// O wire trunca em milissegundos (§0); roundtrips exigem Date com precisão de ms.
    private let ts = Date(timeIntervalSince1970: 1_753_272_000.5)

    private func makeTerminal() -> TerminalNode {
        TerminalNode(
            id: ULID.generate(),
            posicao: Ponto(x: 10, y: 20),
            tamanho: Tamanho(w: 640, h: 400),
            criadoEm: ts,
            nome: "Claudio",
            adapter: KnownAdapter.claudeCode.rawValue,
            cwd: "/tmp"
        )
    }

    @Test func nodeDiscriminadoPorTipo() throws {
        let node = Node.terminal(makeTerminal())
        let data = try SocketFraming.encodeLine(node)
        let texto = String(decoding: data, as: UTF8.self)
        #expect(texto.contains(#""tipo":"terminal""#))
        #expect(texto.contains(#""monitorar_atividade":true"#))
        let roundtrip = try SocketFraming.decodeLine(Node.self, from: data)
        #expect(roundtrip == node)
    }

    @Test func portalNodeDiscriminadoPorTipo() throws {
        // [v1.5 antecipado] — decode de portal deixou de ser rejeitado
        let portal = PortalNode(
            id: ULID.generate(),
            posicao: Ponto(x: 120, y: 120),
            tamanho: Tamanho(w: 720, h: 520),
            criadoEm: ts,
            url: "https://example.com",
            titulo: "Exemplo"
        )
        let node = Node.portal(portal)
        let data = try SocketFraming.encodeLine(node)
        let texto = String(decoding: data, as: UTF8.self)
        #expect(texto.contains(#""tipo":"portal""#))
        #expect(texto.contains(#""url":"https:\/\/example.com""# ) || texto.contains(#""url":"https://example.com""#))
        let roundtrip = try SocketFraming.decodeLine(Node.self, from: data)
        #expect(roundtrip == node)
        #expect(roundtrip.tipo == .portal)
        // titulo é opcional
        let semTitulo = Node.portal(PortalNode(
            id: ULID.generate(), posicao: Ponto(x: 0, y: 0), tamanho: Tamanho(w: 300, h: 200),
            criadoEm: ts, url: "about:blank"))
        let roundtrip2 = try SocketFraming.decodeLine(Node.self, from: SocketFraming.encodeLine(semTitulo))
        #expect(roundtrip2 == semTitulo)
    }

    @Test func opComTipoDaSpec() throws {
        let op = DocOp(
            opID: ULID.generate(),
            author: .humanoLocal,
            ts: ts,
            payload: .nodeMove(NodeMoveOpPayload(id: ULID.generate(), posicao: Ponto(x: 1, y: 2)))
        )
        let data = try SocketFraming.encodeLine(op)
        let texto = String(decoding: data, as: UTF8.self)
        #expect(texto.contains(#""tipo":"node.move""#))
        let roundtrip = try SocketFraming.decodeLine(DocOp.self, from: data)
        #expect(roundtrip == op)
        #expect(roundtrip.seq == nil)
    }

    @Test func eventoDeJournalRoundtrip() throws {
        let event = Event(
            seq: 1,
            ts: ts,
            author: .agente("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            payload: .state(StateEventPayload(de: .rodando, para: .aprovacaoPendente, motivo: "detect_approval"))
        )
        let data = try SocketFraming.encodeLine(event)
        let texto = String(decoding: data, as: UTF8.self)
        #expect(texto.contains(#""tipo":"state""#))
        #expect(texto.contains(#""para":"aprovacao_pendente""#))
        #expect(texto.contains(#""author":"agente:01ARZ3NDEKTSV4RRFFQ69G5FAV""#))
        let roundtrip = try SocketFraming.decodeLine(Event.self, from: data)
        #expect(roundtrip == event)
    }

    @Test func fimRepeticaoNunca() throws {
        let agenda = Agenda(tipo: .intervalo, intervaloSeg: 300, inicio: ts, fimRepeticao: .nunca)
        let data = try SocketFraming.encodeLine(agenda)
        #expect(String(decoding: data, as: UTF8.self).contains(#""fim_repeticao":"nunca""#))
        let roundtrip = try SocketFraming.decodeLine(Agenda.self, from: data)
        #expect(roundtrip == agenda)
    }

    @Test func timestampISO8601ComFracao() throws {
        let workspace = Workspace(
            id: ULID.generate(),
            nome: "meu canvas",
            criadoEm: Date(timeIntervalSince1970: 1_753_272_000),
            atualizadoEm: Date(timeIntervalSince1970: 1_753_272_000.5)
        )
        let data = try SocketFraming.encodeLine(workspace)
        let texto = String(decoding: data, as: UTF8.self)
        #expect(texto.contains(#""criado_em":"2025-07-23T12:00:00.000Z""#))
        let roundtrip = try SocketFraming.decodeLine(Workspace.self, from: data)
        #expect(roundtrip == workspace)
    }
}

@Suite("Framing §6.1")
struct FramingTests {
    @Test func lineBufferRemontaChunksArbitrarios() {
        let buffer = SocketFraming.LineBuffer()
        var lines: [Data] = []
        lines += buffer.append(Data("{\"a\":1}\n{\"b\"".utf8))
        lines += buffer.append(Data(":2}".utf8))
        lines += buffer.append(Data("\n\n{\"c\":3}\n".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
    }
}

@Suite("Storage §20")
struct PathsTests {
    @Test func layoutDaSecao20() throws {
        let workspaceID = try #require(ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV"))
        let sessionID = try #require(ULID("01BX5ZZKBKACTAV9WEVGEMMVRZ"))
        let paths = ColmeiaPaths(root: URL(fileURLWithPath: "/tmp/colmeia-test"))
        #expect(paths.engineSocket.path == "/tmp/colmeia-test/engine.sock")
        #expect(paths.workspaceFile(workspaceID).path == "/tmp/colmeia-test/workspaces/\(workspaceID.string)/workspace.json")
        #expect(paths.documentFile(workspaceID).lastPathComponent == "document.jsonl")
        #expect(paths.documentSnapshotFile(workspaceID).lastPathComponent == "document.snapshot.json")
        #expect(paths.sessionJournal(workspace: workspaceID, session: sessionID).path.hasSuffix("sessions/\(sessionID.string).jsonl"))
        #expect(paths.sessionScrollback(workspace: workspaceID, session: sessionID).path.hasSuffix("\(sessionID.string).scrollback"))
        #expect(paths.noteFile(workspace: workspaceID, node: sessionID).path.hasSuffix("notes/\(sessionID.string).md"))
        #expect(paths.routinesFile(workspaceID).lastPathComponent == "routines.json")
        #expect(paths.floorsFile(workspaceID).lastPathComponent == "floors.json")
    }

    @Test func envColmeiaSocketTemPrecedencia() {
        let path = ColmeiaPaths.socketPath(environment: [ColmeiaEnv.socket: "/tmp/x.sock"])
        #expect(path == "/tmp/x.sock")
    }
}

@Suite("Engine stub")
struct EngineStubTests {
    @Test func versaoCompartilhada() {
        #expect(ColmeiaEngineInfo.version == ColmeiaVersion.string)
    }

    @Test func comparacaoDeVersaoDistingueAppAntigoDeEngineAntigo() {
        #expect(ColmeiaVersion.compare("0.2.3", "0.2.4") == .orderedAscending)
        #expect(ColmeiaVersion.compare("0.2.4", "0.2.4") == .orderedSame)
        #expect(ColmeiaVersion.compare("1.0.0", "0.9.9") == .orderedDescending)
        #expect(ColmeiaVersion.compare("0.2.4", "0.2.4-beta") == .orderedSame)
    }
}
