import Foundation
import ColmeiaKit

/// `colmeia connect <nome-origem> <nome-destino>` e `colmeia disconnect <nome-origem> <nome-destino>`.
enum ConnectCommand {
    static let usage = """
    uso: colmeia connect <nome-origem> <nome-destino>
         colmeia disconnect <nome-origem> <nome-destino>
    """

    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        guard args.count >= 2 else {
            printErr(usage); return CLIExit.uso
        }
        let sub = args[0]
        let origemNome = args[1]
        let destinoNome = args[2]
        let isConnect = sub == "connect"
        guard isConnect || sub == "disconnect" else {
            printErr(usage); return CLIExit.uso
        }
        do {
            let client = try await connectEngine(context)
            defer { client.close() }
            let identity = try context.requireAgentIdentity(subcomando: sub)
            let nodes: NodeListResult = try await racedCall(
                client: client, watchdogSeconds: 30,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
            ) {
                try await client.call(.nodeList, params: NodeListParams(
                    workspaceID: identity.workspaceID
                ), expecting: NodeListResult.self)
            }
            let origem = nodes.first { $0.titulo.lowercased() == origemNome.lowercased() }
            guard let origem else {
                printErr("nó origem \"\(origemNome)\" não encontrado"); return CLIExit.destinoInexistente
            }
            let destino = nodes.first { $0.titulo.lowercased() == destinoNome.lowercased() }
            guard let destino else {
                printErr("nó destino \"\(destinoNome)\" não encontrado"); return CLIExit.destinoInexistente
            }
            if isConnect {
                let _: JSONValue = try await racedCall(client: client, watchdogSeconds: 30,
                    expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")) {
                    try await client.call(.nodeConnect, params: NodeConnectParams(
                        workspaceID: identity.workspaceID, de: origem.id, para: destino.id))
                }
                print("\(origem.titulo) → \(destino.titulo) conectados")
            } else {
                let _: JSONValue = try await racedCall(client: client, watchdogSeconds: 30,
                    expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")) {
                    try await client.call(.nodeDisconnect, params: NodeDisconnectParams(
                        workspaceID: identity.workspaceID, de: origem.id, para: destino.id))
                }
                print("\(origem.titulo) -/-> \(destino.titulo) desconectados")
            }
            return CLIExit.ok
        } catch let failure as CLIFailure {
            printErr(failure.message); return failure.code
        } catch {
            printErr("colmeia \(sub): \(error)"); return CLIExit.contexto
        }
    }
}
