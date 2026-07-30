import Foundation
import ColmeiaKit

/// `colmeia list [--json]` — lista todos os nós do workspace com estado e papel.
enum ListCommand {
    static let usage = """
    uso: colmeia list [--json] [--type <terminal|nota|desenho|portal>]
    """

    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        var json = false
        var tipo: NodeTipo?
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--json": json = true
            case "--type":
                index += 1
                guard index < args.count, let t = NodeTipo(rawValue: args[index]) else {
                    printErr("--type inválido\n\(usage)"); return CLIExit.uso
                }
                tipo = t
            case let f where f.hasPrefix("--type="):
                guard let t = NodeTipo(rawValue: String(f.dropFirst("--type=".count))) else {
                    printErr("--type inválido\n\(usage)"); return CLIExit.uso
                }
                tipo = t
            default:
                printErr(usage); return CLIExit.uso
            }
            index += 1
        }
        do {
            let client = try await connectEngine(context)
            defer { client.close() }
            let identity = try context.requireAgentIdentity(subcomando: "list")
            let filterTipo = tipo
            let result: NodeListResult = try await racedCall(
                client: client, watchdogSeconds: 30,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
            ) {
                try await client.call(.nodeList, params: NodeListParams(
                    workspaceID: identity.workspaceID, floorID: nil, tipo: filterTipo
                ), expecting: NodeListResult.self)
            }
            if json {
                let data = try ColmeiaJSON.encoder().encode(result)
                print(String(decoding: data, as: UTF8.self))
            } else {
                for node in result {
                    let estado = node.estadoSessao ?? "-"
                    let papel = node.papel ?? "regular"
                    let adapter = node.adapter ?? "-"
                    print("\(node.id.string)\t\(node.tipo.rawValue)\t\(node.titulo)\t\(adapter)\t\(papel)\t\(estado)")
                }
            }
            return CLIExit.ok
        } catch let failure as CLIFailure {
            printErr(failure.message); return failure.code
        } catch {
            printErr("colmeia list: \(error)"); return CLIExit.contexto
        }
    }
}
