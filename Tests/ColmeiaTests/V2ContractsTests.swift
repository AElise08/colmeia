import Foundation
import Testing
import ColmeiaKit
import ColmeiaEngine

@Suite("Contratos da especificação v2")
struct V2ContractsTests {
    @Test func hlcOrdenaECodificaSemRelogioDeParede() throws {
        let node = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let a = HLC(wall_time: 10, counter: 1, node_id: node)
        let b = HLC(wall_time: 10, counter: 2, node_id: node)
        #expect(a < b)
        #expect(HLC(a.description) == a)

        let clock = HLCClock(node_id: node, wallTime: { 10 })
        let first = clock.tick()
        let merged = clock.merge(HLC(wall_time: first.wall_time, counter: first.counter + 4, node_id: UUID()))
        #expect(merged > first)
    }

    @Test func capRejeitaTransicaoTerminal() throws {
        #expect(CAPState.idle.allowedNextStates == [.briefing, .shutdown])
        #expect(CAPState.shutdown.allowedNextStates.isEmpty)
        #expect(throws: CAPStateTransitionError.self) {
            try CAPState.validateTransition(from: .shutdown, to: .working)
        }
    }

    @Test func workerExigeGrantExecuteExato() throws {
        let worker = "agente:\(ULID.generate().string)"
        let command = "swift test --filter Smoke"
        let grant = CapabilityGrant(
            id: ULID.generate(), roomID: ULID.generate(), subjectID: worker,
            resource: "command:\(command)", actions: [.execute],
            issuedBy: .humano("owner"), expiresAt: Date().addingTimeInterval(60))
        #expect(WorkerCapabilityPolicy.allowsExecute(
            command: command, subjectID: worker, grants: [grant]))
        #expect(!WorkerCapabilityPolicy.allowsExecute(
            command: "swift test --filter Other", subjectID: worker, grants: [grant]))
        #expect(!WorkerCapabilityPolicy.allowsExecute(
            command: command, subjectID: "agente:outro", grants: [grant]))
    }

    @Test func executionJobTemCicloTipadoEExpiracao() throws {
        let now = Date()
        var job = try WorkerExecutionJob(
            roomID: ULID.generate(), sessionID: ULID.generate(), subjectID: "agente:w",
            command: "echo seguro", requestedBy: .humano("owner"),
            createdAt: now, expiresAt: now.addingTimeInterval(30))
        try job.transition(to: .running, now: now)
        try job.transition(to: .completed, result: "ok", now: now)
        #expect(job.state == .completed)
        #expect(job.result == "ok")
        #expect(throws: WorkerExecutionJobError.self) {
            try job.transition(to: .running, now: now)
        }
    }

    @Test func capNDJSONMantemCamposNormativos() throws {
        let clock = HLC(wall_time: 10, counter: 0, node_id: UUID())
        let request = CAPToolInvocationRequestPayload(
            request_id: ULID.generate(), tool_name: "portal.navigate",
            args: ["url": "https://github.com"], requires_approval: true)
        let envelope = CAPEnvelope(
            msgID: ULID.generate(),
            type: CAP.toolInvocationRequestType,
            timestamp: clock,
            payload: try JSONValue(encoding: request),
            additionalFields: ["trace": "kept"])
        let decoded = try CAPEnvelope(ndjsonLine: envelope.encodeNDJSON())
        #expect(decoded.capVersion == CAP.version)
        #expect(decoded.type == "tool.invocation_request")
        #expect(decoded.unknownFields["trace"]?.stringValue == "kept")
        let decodedRequest = try decoded.payload.decode(as: CAPToolInvocationRequestPayload.self)
        #expect(decodedRequest.tool_name == "portal.navigate")
        #expect(decodedRequest.requires_approval)
    }

    @Test func crdtResolveLWWERGATombstones() throws {
        let node = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let one = HLC(wall_time: 1, counter: 0, node_id: node)
        let two = HLC(wall_time: 2, counter: 0, node_id: node)
        let four = HLC(wall_time: 4, counter: 0, node_id: node)
        let five = HLC(wall_time: 5, counter: 0, node_id: node)
        let six = HLC(wall_time: 6, counter: 0, node_id: node)
        let resolver = CRDTResolver()
        #expect(resolver.apply(.set(target: "node-1", value: "old", timestamp: one)))
        #expect(resolver.apply(.set(target: "node-1", value: "new", timestamp: two)))
        #expect(resolver.value(for: "node-1")?.stringValue == "new")

        #expect(resolver.apply(.insert(id: four, value: "A")))
        #expect(resolver.apply(.insert(id: five, left: four, value: "B")))
        #expect(resolver.text == "AB")
        #expect(resolver.apply(.delete(target: four, operation_id: six)))
        #expect(resolver.text == "B")
        #expect(resolver.characters.first?.isTombstone == true)
    }

    @Test func crdtAguardaDependenciaCausal() throws {
        let node = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let first = HLC(wall_time: 1, counter: 0, node_id: node)
        let second = HLC(wall_time: 2, counter: 0, node_id: node)
        let resolver = CRDTResolver()
        let dependent = CRDTOperation.insert(id: second, left: first, value: "B", causal_deps: [first])
        #expect(!resolver.apply(dependent))
        #expect(resolver.pendingCount == 1)
        #expect(resolver.apply(.insert(id: first, value: "A")))
        #expect(resolver.text == "AB")
    }

    @Test func casELayoutDoWorkspaceV2() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("colmeia-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ColmeiaPaths(root: root)
        try paths.ensureRootLayout()
        let workspace = ULID.generate()
        try paths.ensureWorkspaceLayout(workspace)
        #expect(FileManager.default.fileExists(atPath: paths.casDir.path))
        #expect(FileManager.default.fileExists(atPath: paths.journalsDir(workspace).path))
        #expect(paths.crdtOpsWAL(workspace).lastPathComponent == "crdt_ops.wal")

        let cas = ContentAddressedStore(paths: paths)
        let blob = try await cas.put(Data("hello".utf8))
        #expect(blob.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(try await cas.read(blob.sha256) == Data("hello".utf8))
    }

    @Test func snapshotCorrompidoReconstruiDoWAL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("colmeia-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshotURL = root.appendingPathComponent("crdt_snapshot.bin")
        let walURL = root.appendingPathComponent("crdt_ops.wal")
        let snapshot = CRDTSnapshotStore(url: snapshotURL)
        let wal = CRDTOperationWAL(url: walURL)
        try await snapshot.write(Data("ok".utf8))
        let coordinator = CRDTRecoveryCoordinator(snapshot: snapshot, wal: wal)
        let valid = try await coordinator.recover { _ in Data("unused".utf8) }
        #expect(!valid.rebuiltFromWAL)

        try Data("corrupt".utf8).write(to: snapshotURL)
        try await wal.append(Data("op-1".utf8))
        let rebuilt = try await coordinator.recover { records in
            Data(records.flatMap(Array.init))
        }
        #expect(rebuilt.rebuiltFromWAL)
        #expect(rebuilt.payload == Data("op-1".utf8))
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    @Test func atoresIsolamTransicaoDoAgente() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("colmeia-actors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineActor(paths: ColmeiaPaths(root: root))
        try await engine.start()
        let workspaceID = ULID.generate()
        let agentID = ULID.generate()
        let supervisor = await engine.registerAgent(agentID, in: workspaceID)
        let event = try await supervisor.transition(to: .briefing)
        let room = await engine.workspace(workspaceID)
        try await room.receive(event)
        #expect((await room.transitionHistory()).count == 1)
        #expect((await supervisor.state()) == .briefing)
    }
}
