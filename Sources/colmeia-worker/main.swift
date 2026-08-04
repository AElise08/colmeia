import Foundation
import ColmeiaKit

/// Worker Remoto Headless (§4.1).
/// Executa tarefas remotas no Linux/macOS e reporta output em tempo real ao Hub.
struct WorkerConfig {
    var hubURL: String = "ws://127.0.0.1:9620"
    var roomID: ULID?
    var workerName: String = "worker-vps"
    var workerID: ULID = ULID.generate()
    var inviteToken: String?
    var maxDurationSeconds: Double = 300
    var maxOutputBytes: Int = 128 * 1024
}

func parseArgs() -> WorkerConfig {
    var config = WorkerConfig()
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--hub":
            if i + 1 < args.count {
                config.hubURL = args[i + 1]
                i += 1
            }
        case "--room":
            if i + 1 < args.count, let id = ULID(args[i + 1]) {
                config.roomID = id
                i += 1
            }
        case "--name":
            if i + 1 < args.count {
                config.workerName = args[i + 1]
                i += 1
            }
        case "--worker-id":
            if i + 1 < args.count, let id = ULID(args[i + 1]) {
                config.workerID = id
                i += 1
            }
        case "--invite":
            if i + 1 < args.count {
                config.inviteToken = args[i + 1]
                i += 1
            }
        case "--max-seconds":
            if i + 1 < args.count, let value = Double(args[i + 1]), value > 0 {
                config.maxDurationSeconds = min(value, 86_400)
                i += 1
            }
        case "--max-output-bytes":
            if i + 1 < args.count, let value = Int(args[i + 1]), value > 0 {
                config.maxOutputBytes = min(value, 4 * 1024 * 1024)
                i += 1
            }
        default:
            break
        }
        i += 1
    }
    return config
}

@main
struct WorkerMain {
    static func main() async {
        let config = parseArgs()
        print("=== Colmeia Worker Remoto Headless (v\(ColmeiaVersion.string)) ===")
        print("Nome do Worker: \(config.workerName)")
        print("ID do Worker: \(config.workerID.string)")
        print("Hub: \(config.hubURL)")

        let client = SocketClient()
        do {
            try client.connect(to: config.hubURL)
            let author = Author.agente(config.workerID.string)
            let token = ProcessInfo.processInfo.environment["COLMEIA_HUB_TOKEN"]
            let hello = try await client.hello(
                client: "colmeia-worker/\(config.workerName)", author: author, token: token)
            print("Conectado ao Hub! Versão do Engine: \(hello.engineVersion)")

            if let roomID = config.roomID {
                let joinResult = try await client.call(
                    .roomJoin,
                    params: RoomJoinParams(roomID: roomID, inviteToken: config.inviteToken),
                    expecting: RoomJoinResult.self
                )
                print("Entrou na sala: \(joinResult.room.name) (membros: \(joinResult.members.count))")

                // Task de Heartbeat
                Task {
                    while true {
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        _ = try? await client.call(
                            .presenceUpdate,
                            params: PresenceUpdateParams(roomID: roomID, viewport: nil, selectedNodeID: nil, viewingSessionID: nil)
                        )
                    }
                }

                let sandbox = try WorkerSandbox(workerID: config.workerID)
                print("Worker em modo seguro (cada comando exige grant execute exato). Escutando sala \(roomID.string)...")
                let jobPoller = Task {
                    while !Task.isCancelled {
                        await processQueuedJobs(
                            roomID: roomID, author: author, client: client, sandbox: sandbox,
                            maxDurationSeconds: config.maxDurationSeconds,
                            maxOutputBytes: config.maxOutputBytes)
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }

                for await event in client.events {
                    if event.knownTopic == .sessionEventAppended,
                       let payload = try? event.decodeParams(SessionEventAppendedTopicPayload.self) {
                        let ev = payload.event
                        if ev.kind == .directionProposed || ev.kind == .messageSent {
                            print("[WORKER] intenção recebida; aguardando execution_job tipado (mensagem nunca é comando).")
                        }
                    }
                }
                jobPoller.cancel()
            } else {
                print("Nenhuma --room informada. Worker em standby. Use --room <ID> para entrar numa sala.")
                while true {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        } catch {
            print("Erro no worker: \(error)")
            exit(1)
        }
    }

    private static func processQueuedJobs(
        roomID: ULID,
        author: Author,
        client: SocketClient,
        sandbox: WorkerSandbox,
        maxDurationSeconds: Double,
        maxOutputBytes: Int
    ) async {
        guard let jobs: ExecutionJobListResult = try? await client.call(
            .executionJobList,
            params: ExecutionJobListParams(
                roomID: roomID, subjectID: author.rawValue, state: .queued),
            expecting: ExecutionJobListResult.self) else { return }
        for job in jobs {
            guard let running: WorkerExecutionJob = try? await client.call(
                .executionJobTransition,
                params: ExecutionJobTransitionParams(
                    roomID: roomID, jobID: job.id, state: .running),
                expecting: ExecutionJobResult.self).job else { continue }
            let grants: GrantListResult = (try? await client.call(
                .grantList,
                params: GrantListParams(
                    roomID: roomID, subjectID: author.rawValue, activeOnly: true),
                expecting: GrantListResult.self)) ?? []
            guard WorkerCapabilityPolicy.allowsExecute(
                command: running.command, subjectID: author.rawValue, grants: grants) else {
                print("[WORKER] job \(running.id) bloqueado: grant execute exato ausente")
                _ = try? await client.call(
                    .executionJobTransition,
                    params: ExecutionJobTransitionParams(
                        roomID: roomID, jobID: running.id, state: .failed,
                        result: "capability execute ausente ou expirada"),
                    expecting: ExecutionJobResult.self)
                continue
            }
            let outcome = await runCommand(
                running.command, jobID: running.id, roomID: roomID,
                sessionID: running.sessionID, client: client, author: author,
                sandbox: sandbox, maxDurationSeconds: maxDurationSeconds,
                maxOutputBytes: maxOutputBytes)
            if outcome == .canceled { continue }
            _ = try? await client.call(
                .executionJobTransition,
                params: ExecutionJobTransitionParams(
                    roomID: roomID, jobID: running.id,
                    state: outcome == .completed ? .completed : .failed,
                    result: outcome == .completed ? "concluído" : "falhou"),
                expecting: ExecutionJobResult.self)
        }
    }

    private enum CommandOutcome: Equatable {
        case completed
        case failed
        case canceled
    }

    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()
        private var truncated = false

        init(limit: Int) { self.limit = max(1, limit) }

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            guard data.count < limit else { truncated = true; return }
            let remaining = limit - data.count
            data.append(chunk.prefix(remaining))
            if chunk.count > remaining { truncated = true }
        }

        func snapshot() -> (Data, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (data, truncated)
        }
    }

    private static func runCommand(
        _ command: String,
        jobID: ULID,
        roomID: ULID,
        sessionID: ULID,
        client: SocketClient,
        author: Author,
        sandbox: WorkerSandbox,
        maxDurationSeconds: Double,
        maxOutputBytes: Int
    ) async -> CommandOutcome {
        let process = Process()
        let pipe = Pipe()
        let output = OutputBuffer(limit: maxOutputBytes)
        let canceled = FlagBox()
        let timedOut = FlagBox()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = sandbox.directory
        // Não herdar token, cookie, PATH customizado ou marcadores do processo
        // pai. A autorização continua sendo o grant exato do comando.
        process.environment = [
            "HOME": sandbox.directory.path,
            "TMPDIR": sandbox.directory.path,
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C"
        ]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            _ = try? await client.call(
                .sessionEventAppend,
                params: SessionEventAppendParams(
                    roomID: roomID, sessionID: sessionID, kind: .executionStarted,
                    payload: CollaborativeEventPayload(texto: "Execução remota autorizada iniciada")
                ),
                expecting: SessionEventAppendResult.self
            )

            pipe.fileHandleForReading.readabilityHandler = { handle in
                while let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
                    output.append(chunk)
                    if output.snapshot().0.count >= maxOutputBytes { break }
                }
            }
            try process.run()

            let monitor = Task {
                while process.isRunning && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if let current: ExecutionJobResult = try? await client.call(
                        .executionJobGet,
                        params: ExecutionJobGetParams(roomID: roomID, jobID: jobID),
                        expecting: ExecutionJobResult.self),
                       current.job.state == .canceled {
                        canceled.set()
                        process.terminate()
                        break
                    }
                }
            }
            let timeout = Task {
                try? await Task.sleep(nanoseconds: UInt64(maxDurationSeconds * 1_000_000_000))
                guard !Task.isCancelled, process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }

            process.waitUntilExit()
            monitor.cancel()
            timeout.cancel()
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()

            let (data, wasTruncated) = output.snapshot()
            var outputText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
            if wasTruncated { outputText += "\n[saída truncada por limite do worker]" }
            if timedOut.get() { outputText += "\n[execução encerrada por timeout]" }
            if canceled.get() { outputText += "\n[execução cancelada]" }

            _ = try? await client.call(
                .sessionEventAppend,
                params: SessionEventAppendParams(
                    roomID: roomID, sessionID: sessionID, kind: .executionFinished,
                    payload: CollaborativeEventPayload(texto: outputText.isEmpty ? "(Sem saída)" : outputText)
                ),
                expecting: SessionEventAppendResult.self
            )
            if canceled.get() { return .canceled }
            return process.terminationStatus == 0 && !timedOut.get() ? .completed : .failed
        } catch {
            print("[ERRO EXECUÇÃO] \(error)")
            _ = try? await client.call(
                .sessionEventAppend,
                params: SessionEventAppendParams(
                    roomID: roomID, sessionID: sessionID, kind: .executionFinished,
                    payload: CollaborativeEventPayload(texto: "Falha ao executar: resultado sanitizado")
                ),
                expecting: SessionEventAppendResult.self
            )
            return .failed
        }
    }
}
