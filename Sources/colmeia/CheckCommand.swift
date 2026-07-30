import Foundation
import ColmeiaKit

enum CheckCommand {
    static let usage = #"""
    uso: colmeia check "<nome-do-nó>" [--limit N] [--stream] [--json]
    """#

    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        var nodeName: String?
        var limit = 50
        var stream = false
        var json = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--limit":
                index += 1
                guard index < args.count, let v = Int(args[index]), v > 0, v <= 10000 else {
                    printErr("--limit exige inteiro 1-10000\n\(usage)"); return CLIExit.uso
                }
                limit = v
            case let f where f.hasPrefix("--limit="):
                guard let v = Int(String(f.dropFirst("--limit=".count))), v > 0, v <= 10000 else {
                    printErr("--limit exige inteiro 1-10000\n\(usage)"); return CLIExit.uso
                }
                limit = v
            case "--stream": stream = true
            case "--json": json = true
            case let f where f.hasPrefix("-"):
                printErr("flag desconhecida: \(f)\n\(usage)"); return CLIExit.uso
            default:
                guard nodeName == nil else {
                    printErr("nome do nó duplicado\n\(usage)"); return CLIExit.uso
                }
                nodeName = arg
            }
            index += 1
        }
        guard let nodeName else {
            printErr(usage); return CLIExit.uso
        }
        do {
            if stream {
                try await runStream(nodeName: nodeName, context: context, json: json)
            } else {
                try await runReplay(nodeName: nodeName, context: context, limit: limit, json: json)
            }
            return CLIExit.ok
        } catch let failure as CLIFailure {
            printErr(failure.message); return failure.code
        } catch {
            printErr("colmeia check: \(error)"); return CLIExit.contexto
        }
    }

    private static func lookupTargetAndSession(
        context: CLIContext, nodeName: String
    ) async throws -> (target: NodeSummary, session: Session) {
        let identity = try context.requireAgentIdentity(subcomando: "check")
        let client = try await connectEngine(context)
        defer { client.close() }

        let nodes: NodeListResult = try await racedCall(
            client: client, watchdogSeconds: 30,
            expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
        ) {
            try await client.call(.nodeList, params: NodeListParams(
                workspaceID: identity.workspaceID
            ), expecting: NodeListResult.self)
        }
        guard let target = nodes.first(where: { $0.titulo.lowercased() == nodeName.lowercased() }),
              target.tipo == .terminal else {
            throw CLIFailure(code: CLIExit.destinoInexistente,
                message: "nó terminal \"\(nodeName)\" não encontrado no workspace")
        }
        guard let estado = target.estadoSessao else {
            throw CLIFailure(code: CLIExit.destinoInexistente,
                message: "nó \"\(nodeName)\" não tem sessão vinculada")
        }
        guard estado != "encerrada", estado != "morta" else {
            throw CLIFailure(code: CLIExit.destinoInexistente,
                message: "nó \"\(nodeName)\" está com sessão encerrada")
        }
        let sessions: SessionListResult = try await racedCall(
            client: client, watchdogSeconds: 30,
            expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
        ) {
            try await client.call(.sessionList, params: SessionListParams(
                workspaceID: identity.workspaceID
            ), expecting: SessionListResult.self)
        }
        guard let session = sessions.first(where: { $0.nodeID == target.id }) else {
            throw CLIFailure(code: CLIExit.destinoInexistente,
                message: "nó \"\(target.titulo)\" não tem sessão ativa")
        }
        return (target, session)
    }

    private static func runReplay(nodeName: String, context: CLIContext, limit: Int, json: Bool) async throws {
        let (_, session) = try await lookupTargetAndSession(context: context, nodeName: nodeName)
        let client = try await connectEngine(context)
        defer { client.close() }
        let replay: SessionReplayResult = try await racedCall(
            client: client, watchdogSeconds: 30,
            expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
        ) {
            try await client.call(.sessionReplay, params: SessionReplayParams(
                sessionID: session.id, limit: limit
            ), expecting: SessionReplayResult.self)
        }
        if json {
            let data = try ColmeiaJSON.encoder().encode(replay)
            print(String(decoding: data, as: UTF8.self))
            return
        }
        for ev in replay.events {
            switch ev.payload {
            case .output(let o):
                if let d = Data(base64Encoded: o.dataB64),
                   let t = String(data: d, encoding: .utf8) {
                    print(t, terminator: "")
                }
            case .system(let s):
                print("\n[\(s.message)]\n", terminator: "")
            case .message(let m):
                print("\n[\(m.direcao.rawValue)] \(m.texto)\n", terminator: "")
            case .input, .state, .approval, .note, .resize:
                break
            }
        }
        if !json { print("") }
    }

    private static func runStream(nodeName: String, context: CLIContext, json: Bool) async throws {
        let (_, session) = try await lookupTargetAndSession(context: context, nodeName: nodeName)
        let client = try await connectEngine(context)
        defer { client.close() }
        let attach: SessionAttachResult = try await racedCall(
            client: client, watchdogSeconds: 30,
            expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
        ) {
            try await client.call(.sessionAttach, params: SessionAttachParams(
                sessionID: session.id
            ), expecting: SessionAttachResult.self)
        }
        for ev in attach.replay {
            if case .output(let o) = ev.payload,
               let d = Data(base64Encoded: o.dataB64),
               let t = String(data: d, encoding: .utf8) {
                print(t, terminator: "")
                fflush(stdout)
            }
        }
        for try await event in client.events {
            guard event.knownTopic == .sessionOutput else { continue }
            guard let payload = try? event.decodeParams(SessionOutputTopicPayload.self),
                  payload.sessionID == session.id else { continue }
            if let d = Data(base64Encoded: payload.dataB64),
               let t = String(data: d, encoding: .utf8) {
                if json {
                    if let line = try? ColmeiaJSON.encoder().encode(payload),
                       let s = String(data: line, encoding: .utf8) {
                        print(s)
                    }
                } else {
                    print(t, terminator: "")
                }
                fflush(stdout)
            }
        }
    }
}
