import Foundation
import ColmeiaKit

/// `colmeia note "<texto markdown>"` | `echo "…" | colmeia note -` (§13.3).
/// Apenda na nota conectada do terminal chamador; sem conexão, o engine cria a
/// NotaNode adjacente — decisão do engine, não da CLI.
enum NoteCommand {
    static let usage = #"uso: colmeia note "<texto markdown>"    |    colmeia note -   (lê stdin)"#

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
        // `--` opcional permite texto começando com hífen: colmeia note -- "--- separador".
        let positionals = args.first == "--" ? Array(args.dropFirst()) : args
        guard positionals.count == 1 else {
            throw CLIFailure(code: CLIExit.uso, message: usage)
        }

        // Contexto antes de ler stdin: fora de sessão gerenciada, `note -` falha
        // imediatamente em vez de bloquear esperando EOF.
        let identity = try context.requireAgentIdentity(subcomando: "note")

        let texto: String
        if positionals[0] == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let lido = String(data: data, encoding: .utf8) else {
                throw CLIFailure(code: CLIExit.uso, message: "stdin não é UTF-8 válido")
            }
            texto = lido
        } else {
            texto = positionals[0]
        }
        guard !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIFailure(code: CLIExit.uso, message: "texto vazio — nada para apendar\n\(usage)")
        }
        let client = try await connectEngine(context)
        defer { client.close() }

        let params = NoteAppendParams(
            workspaceID: identity.workspaceID,
            nodeIDOrigem: identity.nodeID,
            texto: texto
        )

        let result: NoteAppendResult
        do {
            result = try await racedCall(
                client: client,
                watchdogSeconds: 30,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
            ) {
                try await client.call(.noteAppend, params: params, expecting: NoteAppendResult.self)
            }
        } catch {
            throw mapError(error)
        }
        print(result.notaNodeID.string)
    }

    private static func mapError(_ error: Error) -> CLIFailure {
        if let failure = error as? CLIFailure { return failure }
        if let proto = error as? ProtocolError {
            // Nó/workspace de origem inexistente = contexto da sessão inválido.
            switch proto.known {
            case .node_not_found, .workspace_not_found:
                return CLIFailure(code: CLIExit.contexto, message: "colmeia note: \(proto)")
            default:
                return CLIFailure(code: CLIExit.destinoInexistente, message: "colmeia note: \(proto)")
            }
        }
        return CLIFailure(code: CLIExit.contexto, message: "colmeia note: \(error)")
    }
}
