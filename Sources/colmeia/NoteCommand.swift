import Foundation
import ColmeiaKit

/// Capacidades de nota para agentes. A forma curta preserva o append histórico.
enum NoteCommand {
    static let usage = """
    uso: colmeia note "<texto markdown>" | colmeia note -
         colmeia note create [<conteúdo>|-] [--floor <floor-id>]
         colmeia note connected [--json]
         colmeia note chain <terminal-node-id> [--max-depth N] [--json]
         colmeia note get <note-id>
         colmeia note set <note-id> <conteúdo>|-
         colmeia note check add <note-id> <texto>
         colmeia note check set <note-id> <item-id> <on|off>
         colmeia note asset add <note-id> --file <path> [--alt "<texto>"]
         colmeia note asset list <note-id>
         colmeia note asset rm <note-id> <asset-id>
    """

    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        do {
            try await execute(args, context: context)
            return CLIExit.ok
        } catch let failure as CLIFailure {
            printErr(failure.message)
            return failure.code
        } catch {
            printErr("colmeia note: \(error)")
            return CLIExit.contexto
        }
    }

    private static func execute(_ args: [String], context: CLIContext) async throws {
        let identity = try context.requireAgentIdentity(subcomando: "note")
        guard let command = args.first else { throw usageFailure() }
        let client = try await connectEngine(context)
        defer { client.close() }

        switch command {
        case "create":
            let (text, floorID) = try createArguments(Array(args.dropFirst()))
            let result: NoteRecord = try await call(client, .noteCreate, NoteCreateParams(
                workspaceID: identity.workspaceID, conteudo: text, floorID: floorID))
            print(result.nodeID.string)
        case "get":
            let rest = Array(args.dropFirst())
            guard rest.count == 1, let id = ULID(rest[0]) else { throw usageFailure() }
            let result: NoteRecord = try await call(client, .noteGet, NoteGetParams(
                workspaceID: identity.workspaceID, nodeID: id))
            print(result.conteudo, terminator: result.conteudo.hasSuffix("\n") ? "" : "\n")
        case "connected":
            let rest = Array(args.dropFirst())
            guard rest.isEmpty || rest == ["--json"] else { throw usageFailure() }
            let result: NoteConnectedResult = try await call(
                client, .noteConnected,
                NoteConnectedParams(workspaceID: identity.workspaceID, nodeID: identity.nodeID))
            if rest == ["--json"] {
                let data = try ColmeiaJSON.encoder().encode(result)
                print(String(decoding: data, as: UTF8.self))
            } else if result.isEmpty {
                print("(nenhuma nota conectada)")
            } else {
                for note in result {
                    print("## \(note.nodeID.string)")
                    print(note.conteudo, terminator: note.conteudo.hasSuffix("\n") ? "" : "\n")
                }
            }
        case "chain":
            let chainArgs = Array(args.dropFirst())
            var nodeID: ULID?
            var maxDepth = 10
            var json = false
            var ci = 0
            while ci < chainArgs.count {
                let a = chainArgs[ci]
                switch a {
                case "--max-depth":
                    ci += 1; guard ci < chainArgs.count, let v = Int(chainArgs[ci]), v > 0 else { throw usageFailure() }
                    maxDepth = v
                case let f where f.hasPrefix("--max-depth="):
                    guard let v = Int(String(f.dropFirst("--max-depth=".count))), v > 0 else { throw usageFailure() }
                    maxDepth = v
                case "--json": json = true
                default:
                    guard nodeID == nil, let id = ULID(a) else { throw usageFailure() }
                    nodeID = id
                }
                ci += 1
            }
            guard let chainNodeID = nodeID else { throw usageFailure() }
            let chainResult: NoteChainResult = try await call(client, .noteChain, NoteConnectedParams(
                workspaceID: identity.workspaceID, nodeID: chainNodeID, recursivo: true, maxProfundidade: maxDepth))
            if json {
                let data = try ColmeiaJSON.encoder().encode(chainResult)
                print(String(decoding: data, as: UTF8.self))
            } else if chainResult.isEmpty {
                print("(nenhuma nota na cadeia)")
            } else {
                for entry in chainResult {
                    let ciclo = entry.ciclo ? " 🔄" : ""
                    print("depth=\(entry.profundidade)\(ciclo) \(entry.note.nodeID.string)")
                    if !entry.note.conteudo.isEmpty {
                        let preview = entry.note.conteudo.split(separator: "\n").first?.prefix(200) ?? ""
                        print("  \(preview)")
                    }
                }
            }
        case "set":
            let rest = Array(args.dropFirst())
            guard rest.count == 2, let id = ULID(rest[0]) else { throw usageFailure() }
            let text = try readText(rest[1])
            let result: NoteRecord = try await call(client, .noteReplace, NoteReplaceParams(
                workspaceID: identity.workspaceID, nodeID: id, conteudo: text))
            print(result.nodeID.string)
        case "asset":
            try await assetCommand(Array(args.dropFirst()), identity: identity, client: client)
        case "check":
            try await checklist(Array(args.dropFirst()), identity: identity, client: client)
        default:
            // `--` permite texto começando por hífen e a forma velha continua idêntica.
            let positionals = command == "--" ? Array(args.dropFirst()) : args
            guard positionals.count == 1 else { throw usageFailure() }
            let text = try readText(positionals[0])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIFailure(code: CLIExit.uso, message: "texto vazio — nada para apendar\n\(usage)")
            }
            let result: NoteAppendResult = try await call(client, .noteAppend, NoteAppendParams(
                workspaceID: identity.workspaceID, nodeIDOrigem: identity.nodeID, texto: text))
            print(result.notaNodeID.string)
        }
    }

    private static func createArguments(_ args: [String]) throws -> (String, ULID?) {
        var content = ""
        var floorID: ULID?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--floor":
                index += 1
                guard index < args.count, let id = ULID(args[index]) else { throw usageFailure() }
                floorID = id
            case let flag where flag.hasPrefix("--floor="):
                guard let id = ULID(String(flag.dropFirst("--floor=".count))) else { throw usageFailure() }
                floorID = id
            case let flag where flag.hasPrefix("--"):
                throw usageFailure()
            default:
                guard content.isEmpty else { throw usageFailure() }
                content = try readText(args[index])
            }
            index += 1
        }
        return (content, floorID)
    }

    private static func checklist(
        _ args: [String], identity: (nodeID: ULID, workspaceID: ULID), client: SocketClient
    ) async throws {
        guard let action = args.first else { throw usageFailure() }
        switch action {
        case "add":
            guard args.count == 3, let noteID = ULID(args[1]) else { throw usageFailure() }
            let result: NoteRecord = try await call(client, .noteChecklistAdd, NoteChecklistAddParams(
                workspaceID: identity.workspaceID, nodeID: noteID, texto: args[2]))
            guard let item = result.checklist.last else {
                throw CLIFailure(code: CLIExit.contexto, message: "engine não retornou o item criado")
            }
            print(item.id.string)
        case "set":
            guard args.count == 4, let noteID = ULID(args[1]), let itemID = ULID(args[2]) else { throw usageFailure() }
            let value: Bool
            switch args[3].lowercased() {
            case "on", "true", "done": value = true
            case "off", "false", "todo": value = false
            default: throw usageFailure()
            }
            let result: NoteChecklistSetResult = try await call(client, .noteChecklistSet, NoteChecklistSetParams(
                workspaceID: identity.workspaceID, nodeID: noteID, itemID: itemID, marcada: value))
            print("\(result.note.nodeID.string) \(result.changed ? "updated" : "unchanged")")
        default:
            throw usageFailure()
        }
    }

    private static func assetCommand(
        _ args: [String], identity: (nodeID: ULID, workspaceID: ULID), client: SocketClient
    ) async throws {
        guard let action = args.first else { throw usageFailure() }
        switch action {
        case "add":
            var noteID: ULID?
            var filePath: String?
            var alt: String?
            var ai = 1
            while ai < args.count {
                let a = args[ai]
                switch a {
                case "--file":
                    ai += 1; guard ai < args.count else { throw usageFailure() }
                    filePath = args[ai]
                case let f where f.hasPrefix("--file="):
                    filePath = String(f.dropFirst("--file=".count))
                case "--alt":
                    ai += 1; guard ai < args.count else { throw usageFailure() }
                    alt = args[ai]
                case let f where f.hasPrefix("--alt="):
                    alt = String(f.dropFirst("--alt=".count))
                case let f where f.hasPrefix("-"):
                    throw usageFailure()
                default:
                    guard noteID == nil, let id = ULID(a) else { throw usageFailure() }
                    noteID = id
                }
                ai += 1
            }
            guard let noteID, let filePath else { throw usageFailure() }
            let url = URL(fileURLWithPath: filePath)
            let data = try Data(contentsOf: url)
            let mime: String
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "png": mime = "image/png"
            case "jpg", "jpeg": mime = "image/jpeg"
            case "gif": mime = "image/gif"
            case "webp": mime = "image/webp"
            case "svg": mime = "image/svg+xml"
            default: mime = "application/octet-stream"
            }
            let result: NoteAssetAddResult = try await call(client, .noteAssetAdd, NoteAssetAddParams(
                workspaceID: identity.workspaceID, nodeID: noteID, mime: mime,
                dataB64: data.base64EncodedString(), alt: alt, filename: url.lastPathComponent))
            print("\(result.asset.id.string)\t\(result.markdown)")
        case "list":
            guard args.count == 2, let noteID = ULID(args[1]) else { throw usageFailure() }
            let result: NoteAssetListResult = try await call(client, .noteAssetList, NoteAssetListParams(
                workspaceID: identity.workspaceID, nodeID: noteID))
            if result.isEmpty {
                print("(nenhum asset)")
            } else {
                for asset in result {
                    print("\(asset.id.string)\t\(asset.mime)\t\(formatBytes(asset.tamanho))\t\(asset.alt ?? asset.filename ?? "-")")
                }
            }
        case "rm":
            guard args.count == 3, let noteID = ULID(args[1]), let assetID = ULID(args[2]) else { throw usageFailure() }
            let _: EmptyResult = try await call(client, .noteAssetRm, NoteAssetRmParams(
                workspaceID: identity.workspaceID, nodeID: noteID, assetID: assetID))
            print("asset \(assetID) removido")
        default:
            throw usageFailure()
        }
    }

    private static func formatBytes(_ b: Int) -> String {
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
        return String(format: "%.1f MB", Double(b) / (1024 * 1024))
    }

    private static func readText(_ argument: String) throws -> String {
        guard argument == "-" else { return argument }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else {
            throw CLIFailure(code: CLIExit.uso, message: "stdin não é UTF-8 válido")
        }
        return content
    }

    private static func call<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ client: SocketClient, _ method: ColmeiaMethod, _ params: Params
    ) async throws -> Result {
        do {
            return try await racedCall(
                client: client, watchdogSeconds: 30,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
            ) {
                try await client.call(method, params: params, expecting: Result.self)
            }
        } catch {
            throw mapError(error)
        }
    }

    private static func usageFailure() -> CLIFailure {
        CLIFailure(code: CLIExit.uso, message: usage)
    }

    private static func mapError(_ error: Error) -> CLIFailure {
        if let failure = error as? CLIFailure { return failure }
        if let proto = error as? ProtocolError {
            switch proto.known {
            case .node_not_found, .workspace_not_found:
                return CLIFailure(code: CLIExit.contexto, message: "colmeia note: \(proto)")
            case .invalid_params:
                return CLIFailure(code: CLIExit.uso, message: "colmeia note: \(proto)")
            default:
                return CLIFailure(code: CLIExit.destinoInexistente, message: "colmeia note: \(proto)")
            }
        }
        return CLIFailure(code: CLIExit.contexto, message: "colmeia note: \(error)")
    }
}
