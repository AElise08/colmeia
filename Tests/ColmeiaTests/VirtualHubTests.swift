import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine
@testable import ColmeiaHub

@Suite("Hub virtual local")
struct VirtualHubTests {
    @Test func snapshotSobreviveAoRestartDoEngine() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("colm-hub-\(UUID().uuidString)", isDirectory: true)
        let paths = ColmeiaPaths(root: root)
        try paths.ensureRootLayout()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let room = Room(id: ULID.generate(), name: "Sala persistente", createdAt: now, updatedAt: now)
        let store = RoomStore(room: room)
        try store.addMember(id: "member-a", displayName: "Melissa", roles: [.owner], now: now)
        let session = store.createAgentSession(AgentSessionCreateParams(
            roomID: room.id, workspaceID: ULID.generate(), nodeID: ULID.generate(), objective: "Testar retomada"), now: now)
        _ = try store.appendEvent(
            sessionID: session.id, kind: .messageSent,
            payload: CollaborativeEventPayload(texto: "continua após reiniciar"),
            author: .humano("member-a"), now: now)
        try store.persist(to: paths)

        let restored = try RoomStore.load(from: paths, roomID: room.id)
        let snapshot = restored.snapshot()
        #expect(snapshot.room.name == "Sala persistente")
        #expect(snapshot.members.map(\.id) == ["member-a"])
        #expect(snapshot.agentSessions.map(\.id) == [session.id])
        #expect(snapshot.events.map { $0.payload.texto } == ["continua após reiniciar"])
        #expect(snapshot.roomSeq == 1)
    }

    @Test func fluxoCompletoDeHandoffEBriefingDeEntrada() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let room = Room(id: ULID.generate(), name: "Sala de Handoff", createdAt: now, updatedAt: now)
        let store = RoomStore(room: room)

        let owner = try store.addMember(id: "owner-1", displayName: "Alice (Owner)", roles: [.owner], now: now)
        let worker = try store.addMember(id: "worker-1", displayName: "Bob (Worker)", roles: [.editor], now: now)

        let session = store.createAgentSession(AgentSessionCreateParams(
            roomID: room.id, workspaceID: ULID.generate(), nodeID: ULID.generate(), objective: "Refatorar pipeline"), now: now)
        #expect(session.state == .draft)

        // Transição draft -> ready -> running
        let sessionReady = try store.transitionSession(id: session.id, to: .ready, now: now)
        #expect(sessionReady.state == .ready)
        let sessionRunning = try store.transitionSession(id: session.id, to: .running, now: now)
        #expect(sessionRunning.state == .running)

        // Eventos na sala
        _ = try store.appendEvent(
            sessionID: session.id, kind: .directionApplied,
            payload: CollaborativeEventPayload(direction: "Iniciar análise de performance"),
            author: .humano(owner.id), now: now)

        // Solicitando Handoff do owner para o worker
        let sessionHandoff = try store.requestHandoff(
            sessionID: session.id, fromMemberID: owner.id, toMemberID: worker.id, scope: .both, now: now)
        #expect(sessionHandoff.state == .handoffPending)
        #expect(sessionHandoff.handoff?.toMemberID == worker.id)

        // Aceitando Handoff pelo worker
        let sessionAccepted = try store.acceptHandoff(sessionID: session.id, by: worker.id, now: now)
        #expect(sessionAccepted.state == .running)
        #expect(sessionAccepted.conductorID == worker.id)
        #expect(sessionAccepted.executorID == worker.id)

        // Briefing de entrada determinístico (§9.2)
        guard let briefing = store.buildBriefing(for: session.id, newMemberName: "Carol") else {
            Issue.record("Briefing deveria ser gerado")
            return
        }
        #expect(briefing.contains("1. Objetivo e estado atual"))
        #expect(briefing.contains("Refatorar pipeline"))
        #expect(briefing.contains("2. Últimas mudanças"))
        #expect(briefing.contains("3. Responsabilidades atuais"))
        #expect(briefing.contains("4. Próxima ação"))
        #expect(briefing.contains("5. Como ajudar"))
    }

    @Test func grantsELeasesDeColaboracao() throws {
        let now = Date()
        let room = Room(id: ULID.generate(), name: "Sala de Grants", createdAt: now, updatedAt: now)
        let store = RoomStore(room: room)
        let session = store.createAgentSession(AgentSessionCreateParams(
            roomID: room.id, workspaceID: ULID.generate(), nodeID: ULID.generate(), objective: "Executar build"), now: now)

        // Grant de capacidade
        let grant = store.issueGrant(
            subjectID: "worker-1", resource: "session/\(session.id.string)",
            actions: [.execute, .read], issuedBy: .humano("owner-1"),
            expiresAt: now.addingTimeInterval(3600), contextHash: "hash123", now: now)
        #expect(grant.isActive)
        #expect(store.getGrants(subjectID: "worker-1", activeOnly: true).count == 1)

        // Revogação de grant
        let revokedGrant = try store.revokeGrant(id: grant.id)
        #expect(!revokedGrant.isActive)
        #expect(store.getGrants(subjectID: "worker-1", activeOnly: true).isEmpty)

        // Lease de execução
        let lease = store.acquireLease(sessionID: session.id, scope: .executor, memberID: "worker-1", now: now)
        #expect(lease.sessionID == session.id)

        let renewed = try store.heartbeatLease(leaseID: lease.leaseID, now: now.addingTimeInterval(30))
        #expect(renewed.leaseID == lease.leaseID)

        let released = store.releaseLease(leaseID: lease.leaseID)
        #expect(released)
    }

    @Test func servidorHubRedeTCP() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("colm-hub-tcp-\(UUID().uuidString)", isDirectory: true)
        let paths = ColmeiaPaths(root: root)
        try paths.ensureRootLayout()
        defer { try? FileManager.default.removeItem(at: root) }

        // Escolhe porta aleatória/disponível
        let port: UInt16 = 9876
        let server = HubServer(paths: paths, host: "127.0.0.1", port: port)
        try server.start()
        defer { server.stop() }

        // Conecta cliente TCP via Socket API Darwin
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { if fd >= 0 { Darwin.close(fd) } }

        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        sin.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connRes = withUnsafePointer(to: &sin) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connRes == 0)

        // Handshake hello
        let helloReq = #"{"kind":"request","id":"r-1","method":"hello","params":{"protocol_version":1,"client":"test-tcp","author":"humano:tester"}}"# + "\n"
        _ = helloReq.withCString { send(fd, $0, strlen($0), 0) }

        let lineBuffer = SocketFraming.LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var helloResp: Envelope?
        for _ in 0..<10 {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                let lines = lineBuffer.append(Data(bytes: chunk, count: count))
                if let first = lines.first {
                    helloResp = try? SocketFraming.decodeLine(Envelope.self, from: first)
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard case .response(let resp) = helloResp, resp.ok else {
            Issue.record("Handshake hello no HubServer falhou")
            return
        }
        #expect(resp.id == "r-1")

        // Criar sala via TCP
        let createReq = #"{"kind":"request","id":"r-2","method":"room.create","params":{"name":"Sala TCP"}}"# + "\n"
        _ = createReq.withCString { send(fd, $0, strlen($0), 0) }

        var roomResp: Envelope?
        for _ in 0..<10 {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                let lines = lineBuffer.append(Data(bytes: chunk, count: count))
                if let first = lines.first {
                    roomResp = try? SocketFraming.decodeLine(Envelope.self, from: first)
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard case .response(let roomResult) = roomResp, roomResult.ok else {
            Issue.record("room.create via TCP falhou")
            return
        }
        #expect(roomResult.id == "r-2")

        // Tentar acessar sala inexistente deve falhar com room_not_found (sem fallback para primeira sala)
        let invalidJoinReq = #"{"kind":"request","id":"r-3","method":"room.join","params":{"room_id":"01H00000000000000000000000"}}"# + "\n"
        _ = invalidJoinReq.withCString { send(fd, $0, strlen($0), 0) }

        var errResp: Envelope?
        for _ in 0..<10 {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                let lines = lineBuffer.append(Data(bytes: chunk, count: count))
                if let first = lines.first {
                    errResp = try? SocketFraming.decodeLine(Envelope.self, from: first)
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard case .response(let errResult) = errResp else {
            Issue.record("Resposta de sala inexistente esperada")
            return
        }
        #expect(!errResult.ok)
        #expect(errResult.error?.known == .room_not_found)
    }
}

