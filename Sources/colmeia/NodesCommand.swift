import Foundation
import ColmeiaKit

/// Consulta segura de metadados — conteúdo de notas exige `colmeia note get`.
enum NodesCommand {
    static let usage = """
    uso:
      colmeia nodes [--floor <floor-id>] [--type <terminal|nota|desenho|portal>] [--json]
      colmeia nodes create terminal [--name <nome>] [--adapter <adapter>] [--role <papel>] [--cwd <path>] [--command <cmd>] [--no-start] [--json]
      colmeia nodes dismiss <node-id>
    """

    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        if args.first == "dismiss" {
            return await dismiss(Array(args.dropFirst()), context: context)
        }
        if args.first == "create" {
            return await create(Array(args.dropFirst()), context: context)
        }
        if args.first == "help" || args.first == "--help" || args.first == "-h" {
            print(usage)
            return CLIExit.ok
        }
        do {
            let identity = try context.requireAgentIdentity(subcomando: "nodes")
            var floorID: ULID?
            var type: NodeTipo?
            var json = false
            var index = 0
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--floor":
                    index += 1
                    guard index < args.count, let id = ULID(args[index]) else { throw failure() }
                    floorID = id
                case let value where value.hasPrefix("--floor="):
                    guard let id = ULID(String(value.dropFirst("--floor=".count))) else { throw failure() }
                    floorID = id
                case "--type":
                    index += 1
                    guard index < args.count, let value = NodeTipo(rawValue: args[index]) else { throw failure() }
                    type = value
                case let value where value.hasPrefix("--type="):
                    guard let parsed = NodeTipo(rawValue: String(value.dropFirst("--type=".count))) else { throw failure() }
                    type = parsed
                case "--json": json = true
                default: throw failure()
                }
                index += 1
            }
            let client = try await connectEngine(context)
            defer { client.close() }
            let params = NodeListParams(workspaceID: identity.workspaceID, floorID: floorID, tipo: type)
            let result: NodeListResult = try await racedCall(
                client: client, watchdogSeconds: 30,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
            ) {
                try await client.call(.nodeList, params: params, expecting: NodeListResult.self)
            }
            if json {
                let data = try ColmeiaJSON.encoder().encode(result)
                print(String(decoding: data, as: UTF8.self))
            } else {
                for node in result {
                    print("\(node.id.string)\t\(node.tipo.rawValue)\t\(node.titulo)\(node.floorID.map { "\tfloor=\($0.string)" } ?? "")")
                }
            }
            return CLIExit.ok
        } catch let error as CLIFailure {
            printErr(error.message)
            return error.code
        } catch let error as ProtocolError {
            printErr("colmeia nodes: \(error)")
            return error.known == .invalid_params ? CLIExit.uso : CLIExit.destinoInexistente
        } catch {
            printErr("colmeia nodes: \(error)")
            return CLIExit.contexto
        }
    }

    private static func failure() -> CLIFailure { CLIFailure(code: CLIExit.uso, message: usage) }

    private struct CreatedTerminalOutput: Codable {
        var nodeID: ULID
        var nome: String
        var adapter: String
        var sessionID: ULID?

        enum CodingKeys: String, CodingKey {
            case nome, adapter
            case nodeID = "node_id"
            case sessionID = "session_id"
        }
    }

    /// `colmeia nodes dismiss <node-id>` — remove nó terminal (apenas Rainha).
    private static func dismiss(_ args: [String], context: CLIContext) async -> Int32 {
        do {
            let rest = Array(args.dropFirst())
            guard rest.count == 1, let nodeID = ULID(rest[0]) else {
                printErr("uso: colmeia nodes dismiss <node-id>\n\(usage)"); return CLIExit.uso
            }
            let identity = try context.requireAgentIdentity(subcomando: "nodes dismiss")
            let client = try await connectEngine(context)
            defer { client.close() }
            let _: JSONValue = try await racedCall(client: client, watchdogSeconds: 30,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")) {
                try await client.call(.nodeDismiss, params: NodeDismissParams(
                    workspaceID: identity.workspaceID, nodeID: nodeID))
            }
            print("nó \(nodeID) demovido")
            return CLIExit.ok
        } catch let error as CLIFailure { printErr(error.message); return error.code
        } catch { printErr("colmeia nodes dismiss: \(error)"); return CLIExit.contexto }
    }

    private static func create(_ args: [String], context: CLIContext) async -> Int32 {
        do {
            guard args.first == "terminal" else { throw failure() }
            let identity = try context.requireAgentIdentity(subcomando: "nodes create terminal")
            var nome: String?
            var adapter = "codex"
            var papel: String?
            var cwd = FileManager.default.currentDirectoryPath
            var comando: String?
            var start = true
            var json = false
            var index = 1
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--name":
                    index += 1
                    guard index < args.count else { throw failure() }
                    nome = args[index]
                case let value where value.hasPrefix("--name="):
                    nome = String(value.dropFirst("--name=".count))
                case "--adapter":
                    index += 1
                    guard index < args.count else { throw failure() }
                    adapter = args[index]
                case let value where value.hasPrefix("--adapter="):
                    adapter = String(value.dropFirst("--adapter=".count))
                case "--role":
                    index += 1
                    guard index < args.count else { throw failure() }
                    papel = args[index]
                case let value where value.hasPrefix("--role="):
                    papel = String(value.dropFirst("--role=".count))
                case "--cwd":
                    index += 1
                    guard index < args.count else { throw failure() }
                    cwd = args[index]
                case let value where value.hasPrefix("--cwd="):
                    cwd = String(value.dropFirst("--cwd=".count))
                case "--command":
                    index += 1
                    guard index < args.count else { throw failure() }
                    comando = args[index]
                case let value where value.hasPrefix("--command="):
                    comando = String(value.dropFirst("--command=".count))
                case "--no-start":
                    start = false
                case "--json":
                    json = true
                default:
                    throw failure()
                }
                index += 1
            }

            let client = try await connectEngine(context)
            defer { client.close() }

            let existing: NodeListResult = try await racedCall(
                client: client, watchdogSeconds: 30,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
            ) {
                try await client.call(
                    .nodeList,
                    params: NodeListParams(workspaceID: identity.workspaceID, tipo: .terminal),
                    expecting: NodeListResult.self)
            }
            let finalName = uniqueTerminalName(
                requested: nome,
                adapter: adapter,
                existing: existing.map(\.titulo))
            let offset = Double(existing.count % 12) * 36
            let node = TerminalNode(
                id: ULID.generate(),
                posicao: Ponto(x: 220 + offset, y: 180 + offset),
                tamanho: Tamanho(w: 640, h: 420),
                z: existing.count + 1,
                criadoEm: Date(),
                nome: finalName,
                papel: papel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? papel : nil,
                adapter: adapter,
                comandoOverride: comando?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? comando : nil,
                cwd: cwd,
                monitorarAtividade: true
            )
            let op = DocOp(
                opID: ULID.generate(),
                author: context.author,
                ts: Date(),
                payload: .nodeAdd(NodeAddOpPayload(node: .terminal(node)))
            )
            // The parent node is known to this managed CLI session. Persist the
            // conversation edge with the child creation, rather than depending
            // solely on the engine to infer it from the socket author.
            let connection = Connection(
                id: ULID.generate(), de: identity.nodeID, para: node.id,
                semantica: .conversa, estilo: .tracejada)
            let connectionOp = DocOp(
                opID: ULID.generate(), author: context.author, ts: Date(),
                payload: .connectionAdd(ConnectionAddOpPayload(connection: connection)))
            _ = try await racedCall(
                client: client, watchdogSeconds: 30,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu ao criar terminal em 30s")
            ) {
                try await client.call(
                    .docApply,
                    params: DocApplyParams(workspaceID: identity.workspaceID, ops: [op, connectionOp]),
                    expecting: DocApplyResult.self)
            }

            var sessionID: ULID?
            if start {
                let result: SessionResult = try await racedCall(
                    client: client, watchdogSeconds: 30,
                    expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu ao iniciar terminal em 30s")
                ) {
                    try await client.call(
                        .sessionStart,
                        params: SessionStartParams(workspaceID: identity.workspaceID, nodeID: node.id),
                        expecting: SessionResult.self)
                }
                sessionID = result.session.id
            }

            let output = CreatedTerminalOutput(
                nodeID: node.id, nome: node.nome, adapter: node.adapter, sessionID: sessionID)
            if json {
                let data = try ColmeiaJSON.encoder().encode(output)
                print(String(decoding: data, as: UTF8.self))
            } else {
                print("terminal criado: \(output.nome) (\(output.nodeID.string))")
                if let sessionID { print("sessão: \(sessionID.string)") }
            }
            return CLIExit.ok
        } catch let error as CLIFailure {
            printErr(error.message)
            return error.code
        } catch let error as ProtocolError {
            printErr("colmeia nodes create terminal: \(error)")
            return error.known == .invalid_params || error.known == .duplicate_node_name ? CLIExit.uso : CLIExit.destinoInexistente
        } catch {
            printErr("colmeia nodes create terminal: \(error)")
            return CLIExit.contexto
        }
    }

    private static func uniqueTerminalName(requested: String?, adapter: String, existing: [String]) -> String {
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base: String
        if !trimmed.isEmpty {
            base = trimmed
        } else {
            switch adapter {
            case "codex": base = "Codex"
            case "opencode": base = "OpenCode"
            case "claude-code": base = "Claude"
            case "gemini-cli": base = "Gemini"
            case "shell": base = "Shell"
            default: base = "Agente"
            }
        }
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }
}
