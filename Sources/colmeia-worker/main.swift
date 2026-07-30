import Foundation
import ColmeiaKit

/// Worker Remoto Headless (§4.1).
/// Executa tarefas remotas no Linux/macOS e reporta output em tempo real ao Hub.
struct WorkerConfig {
    var hubURL: String = "ws://127.0.0.1:9620"
    var roomID: ULID?
    var workerName: String = "worker-vps"
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
        print("Hub: \(config.hubURL)")

        let client = SocketClient()
        do {
            try client.connect(to: config.hubURL)
            let author = Author.agente(ULID.generate().string)
            let hello = try await client.hello(client: "colmeia-worker/\(config.workerName)", author: author)
            print("Conectado ao Hub! Versão do Engine: \(hello.engineVersion)")

            if let roomID = config.roomID {
                let joinResult = try await client.call(
                    .roomJoin,
                    params: RoomJoinParams(roomID: roomID),
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

                print("Worker em modo seguro (execução remota desativada até Marco 5 — Capability Grants). Escutando sala \(roomID.string)...")

                for await event in client.events {
                    if event.knownTopic == .sessionEventAppended,
                       let payload = try? event.decodeParams(SessionEventAppendedTopicPayload.self) {
                        let ev = payload.event
                        if (ev.kind == .directionProposed || ev.kind == .messageSent),
                           let cmd = ev.payload.direction ?? ev.payload.texto,
                           !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            print("[WORKER] Evento recebido de \(ev.author.rawValue): '\(cmd)'. Execução remota desativada (§4).")
                        }
                    }
                }
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

    private static func runCommand(_ command: String, roomID: ULID, sessionID: ULID, client: SocketClient, author: Author) async {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            // Notificar início de execução
            _ = try? await client.call(
                .sessionEventAppend,
                params: SessionEventAppendParams(
                    roomID: roomID,
                    sessionID: sessionID,
                    kind: .executionStarted,
                    payload: CollaborativeEventPayload(texto: "Iniciando comando: \(command)")
                ),
                expecting: SessionEventAppendResult.self
            )

            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let outputText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
            print("[COMANDO CONCLUÍDO] Exit: \(process.terminationStatus) | Output length: \(outputText.count)")

            // Retornar output ao Hub
            _ = try? await client.call(
                .sessionEventAppend,
                params: SessionEventAppendParams(
                    roomID: roomID,
                    sessionID: sessionID,
                    kind: .executionFinished,
                    payload: CollaborativeEventPayload(texto: outputText.isEmpty ? "(Sem saída)" : outputText)
                ),
                expecting: SessionEventAppendResult.self
            )
        } catch {
            print("[ERRO EXECUÇÃO] \(error)")
            _ = try? await client.call(
                .sessionEventAppend,
                params: SessionEventAppendParams(
                    roomID: roomID,
                    sessionID: sessionID,
                    kind: .executionFinished,
                    payload: CollaborativeEventPayload(texto: "Falha ao executar: \(error.localizedDescription)")
                ),
                expecting: SessionEventAppendResult.self
            )
        }
    }
}
