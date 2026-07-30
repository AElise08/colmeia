import Foundation
import Darwin
import Testing
import ColmeiaKit

// Aceitação de falhas em processos reais. Não usa Engine in-process: SIGKILL,
// restart, socket e CLI percorrem o mesmo caminho do app empacotado (§22/§25).
private func failureRoot() -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cfail-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func failurePackageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ColmeiaTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // package root
}

private func failureBinary(_ name: String) -> URL? {
    let path = failurePackageRoot().appendingPathComponent(".build/debug/\(name)")
    return FileManager.default.isExecutableFile(atPath: path.path) ? path : nil
}

private func spawnFailureEngine(_ binary: URL, root: URL) throws -> Process {
    let process = Process()
    process.executableURL = binary
    process.arguments = ["--root", root.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private func connectFailureClient(root: URL, timeout: TimeInterval = 5) async throws -> SocketClient {
    let socket = ColmeiaPaths(root: root).engineSocket.path
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let client = SocketClient()
        do {
            try client.connect(to: socket)
            return client
        } catch {
            client.close()
            if Date() >= deadline { throw error }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private func waitForFailureExit(_ process: Process, timeout: TimeInterval = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return true
}

private func waitForFailure(
    timeout: TimeInterval = 5,
    _ predicate: @escaping () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await predicate() { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw NSError(domain: "FailureRecoveryAcceptanceTests", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "condição não atingida em \(timeout)s"])
}

private func failureNode(
    _ name: String, cwd: String, command: String, adapter: String = "shell"
) -> TerminalNode {
    TerminalNode(
        id: ULID.generate(), posicao: Ponto(x: 0, y: 0), tamanho: Tamanho(w: 400, h: 280),
        criadoEm: Date(), nome: name, adapter: adapter, comandoOverride: command, cwd: cwd)
}

private func addFailureNodes(_ nodes: [TerminalNode], workspaceID: ULID, client: SocketClient) async throws {
    let ops = nodes.map {
        DocOp(opID: ULID.generate(), author: .humanoLocal, ts: Date(),
              payload: .nodeAdd(NodeAddOpPayload(node: .terminal($0))))
    }
    _ = try await client.call(.docApply, params: DocApplyParams(workspaceID: workspaceID, ops: ops))
}

private func runFailureCLI(
    binary: URL, args: [String], environment: [String: String], timeout: TimeInterval = 8
) async throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    let out = Pipe()
    let err = Pipe()
    process.executableURL = binary
    process.arguments = args
    process.environment = environment
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning {
        if Date() >= deadline {
            process.terminate()
            throw NSError(domain: "FailureRecoveryAcceptanceTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "CLI excedeu \(timeout)s"])
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    return (
        process.terminationStatus,
        String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
}

private func isWaiting(_ session: Session) -> Bool {
    session.estado == .esperandoHumano || session.estado == .ociosa
}

@Suite("Falhas e recuperação por processo real (§22/§25)", .serialized)
struct FailureRecoveryAcceptanceTests {
    @Test func sigkillDoEnginePreservaJournalEMarcaSessaoComoEngineCrash() async throws {
        let engineBinary = try #require(failureBinary("colmeia-engine"))
        let root = failureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldEngine = try spawnFailureEngine(engineBinary, root: root)
        defer { if oldEngine.isRunning { oldEngine.terminate() } }
        let client = try await connectFailureClient(root: root)
        _ = try await client.hello(client: "failure-crash")
        let workspace = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "crash", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self).workspace
        let node = failureNode(
            "ticker", cwd: root.path,
            command: "i=0; while :; do printf 'tick-%s\\n' \"$i\"; i=$((i+1)); sleep 0.05; done")
        try await addFailureNodes([node], workspaceID: workspace.id, client: client)
        let session = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: workspace.id, nodeID: node.id),
            expecting: SessionResult.self).session
        try await waitForFailure {
            let replay = try await client.call(
                .sessionReplay, params: SessionReplayParams(sessionID: session.id), expecting: SessionReplayResult.self)
            return replay.events.contains { event in
                if case .output = event.payload { return true }
                return false
            }
        }

        let killedAt = Date()
        _ = Darwin.kill(pid_t(oldEngine.processIdentifier), SIGKILL)
        #expect(await waitForFailureExit(oldEngine), "engine não saiu após SIGKILL")
        client.close()

        let newEngine = try spawnFailureEngine(engineBinary, root: root)
        defer { if newEngine.isRunning { newEngine.terminate() } }
        let recovered = try await connectFailureClient(root: root)
        defer { recovered.close() }
        _ = try await recovered.hello(client: "failure-recover")
        let sessions = try await recovered.call(
            .sessionList, params: SessionListParams(workspaceID: workspace.id), expecting: SessionListResult.self)
        #expect(sessions.first(where: { $0.id == session.id })?.estado == .morta)
        let replay = try await recovered.call(
            .sessionReplay, params: SessionReplayParams(sessionID: session.id), expecting: SessionReplayResult.self)
        #expect(!replay.events.isEmpty)
        #expect(replay.events.map(\.seq) == Array(1...replay.events.count).map(UInt64.init))
        let lastOutput = try #require(replay.events.last(where: { event in
            if case .output = event.payload { return true }
            return false
        }))
        #expect(killedAt.timeIntervalSince(lastOutput.ts) <= 1.0,
                "último output persistido excede a janela de perda de 1 s")
        #expect(replay.events.contains { event in
            guard case .state(let state) = event.payload else { return false }
            return state.para == .morta && state.motivo == "engine_crash"
        })
        // O shell pode sobreviver brevemente ao pai morto em alguns kernels.
        if let pid = session.pid { _ = Darwin.kill(pid_t(pid), SIGKILL) }
    }

    @Test func askBloqueanteRetornaRespostaETimeoutDaCLIUsaExitDois() async throws {
        let engineBinary = try #require(failureBinary("colmeia-engine"))
        let cliBinary = try #require(failureBinary("colmeia"))
        let root = failureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try spawnFailureEngine(engineBinary, root: root)
        defer { if engine.isRunning { engine.terminate() } }
        let client = try await connectFailureClient(root: root)
        defer { client.close() }
        _ = try await client.hello(client: "failure-ask")
        let workspace = try await client.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "ask", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self).workspace
        let sender = failureNode("A", cwd: root.path, command: "sleep 20")
        // Primeiro input responde e volta ao prompt; segundo input não produz
        // prompt, deixando o engine encerrar pelo timeout bloqueante.
        let destination = failureNode(
            "B", cwd: root.path,
            command: "printf '> '; IFS= read -r one; printf 'reply:%s\\n> ' \"$one\"; IFS= read -r two; sleep 4",
            adapter: "claude-code")
        try await addFailureNodes([sender, destination], workspaceID: workspace.id, client: client)
        _ = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: workspace.id, nodeID: sender.id),
            expecting: SessionResult.self)
        let destinationSession = try await client.call(
            .sessionStart, params: SessionStartParams(workspaceID: workspace.id, nodeID: destination.id),
            expecting: SessionResult.self).session
        try await waitForFailure(timeout: 4) {
            let list = try await client.call(
                .sessionList, params: SessionListParams(workspaceID: workspace.id), expecting: SessionListResult.self)
            return list.first(where: { $0.id == destinationSession.id }).map(isWaiting) ?? false
        }

        let response = try await client.call(
            .messageSend,
            params: MessageSendParams(
                workspaceID: workspace.id, deNode: sender.id, paraNome: "B",
                texto: "primeira", timeoutSeg: 4))
        #expect(response["message_id"]?.stringValue != nil)
        #expect(response["resposta"]?.stringValue?.contains("reply:primeira") == true)

        try await waitForFailure(timeout: 4) {
            let list = try await client.call(
                .sessionList, params: SessionListParams(workspaceID: workspace.id), expecting: SessionListResult.self)
            return list.first(where: { $0.id == destinationSession.id }).map(isWaiting) ?? false
        }
        var env = ProcessInfo.processInfo.environment
        env[ColmeiaEnv.socket] = ColmeiaPaths(root: root).engineSocket.path
        env[ColmeiaEnv.workspaceID] = workspace.id.string
        env[ColmeiaEnv.nodeID] = sender.id.string
        let timeout = try await runFailureCLI(
            binary: cliBinary,
            args: ["ask", "B", "segunda", "--timeout", "1"], environment: env)
        #expect(timeout.status == 2, "stdout=\(timeout.stdout) stderr=\(timeout.stderr)")
        #expect(timeout.stderr.contains("timeout"))
    }

    @Test func quintaDependenciaBloqueanteFalhaControladamente() async throws {
        let engineBinary = try #require(failureBinary("colmeia-engine"))
        let root = failureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try spawnFailureEngine(engineBinary, root: root)
        defer { if engine.isRunning { engine.terminate() } }
        let setup = try await connectFailureClient(root: root)
        defer { setup.close() }
        _ = try await setup.hello(client: "failure-depth")
        let workspace = try await setup.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "depth", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self).workspace
        let nodes = ["A", "B", "C", "D", "E", "F"].map {
            failureNode($0, cwd: root.path, command: "printf '> '; sleep 8", adapter: "claude-code")
        }
        try await addFailureNodes(nodes, workspaceID: workspace.id, client: setup)
        var sessions: [ULID: Session] = [:]
        for node in nodes.dropFirst() {
            let session = try await setup.call(
                .sessionStart, params: SessionStartParams(workspaceID: workspace.id, nodeID: node.id),
                expecting: SessionResult.self).session
            sessions[node.id] = session
        }
        try await waitForFailure(timeout: 4) {
            let list = try await setup.call(
                .sessionList, params: SessionListParams(workspaceID: workspace.id), expecting: SessionListResult.self)
            return sessions.values.allSatisfy { expected in
                list.first(where: { $0.id == expected.id }).map(isWaiting) ?? false
            }
        }

        var pending: [Task<JSONValue?, Never>] = []
        for index in 0..<4 {
            let requestClient = try await connectFailureClient(root: root)
            _ = try await requestClient.hello(client: "failure-depth-\(index)")
            let from = nodes[index]
            let to = nodes[index + 1]
            let text = "depth-\(index + 1)"
            let task = Task {
                defer { requestClient.close() }
                return try? await requestClient.call(
                    .messageSend,
                    params: MessageSendParams(
                        workspaceID: workspace.id, deNode: from.id, paraNome: to.nome,
                        texto: text, timeoutSeg: 2))
            }
            pending.append(task)
            // O journal do destino prova que o wait bloqueante foi registrado antes
            // de iniciar o elo seguinte — sem depender de uma pausa fixa.
            let targetSession = try #require(sessions[to.id])
            try await waitForFailure(timeout: 1) {
                let replay = try await setup.call(
                    .sessionReplay, params: SessionReplayParams(sessionID: targetSession.id), expecting: SessionReplayResult.self)
                return replay.events.contains { event in
                    guard case .message(let message) = event.payload else { return false }
                    return message.texto == text && message.direcao == .recebida
                }
            }
        }
        do {
            _ = try await setup.call(
                .messageSend,
                params: MessageSendParams(
                    workspaceID: workspace.id, deNode: nodes[4].id, paraNome: nodes[5].nome,
                    texto: "depth-5", timeoutSeg: 2))
            Issue.record("quinta dependência bloqueante deveria falhar")
        } catch let error as ProtocolError {
            #expect(error.known == .invalid_params)
            #expect(error.message.contains("profundidade"))
        }
        for task in pending { _ = await task.value }
    }
}
