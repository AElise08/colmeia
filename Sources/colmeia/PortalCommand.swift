import Foundation
import ColmeiaKit

/// `colmeia portal open <url> [--nome X] [--workspace <id>]` — [v1.5 antecipado]:
/// cria um nó portal (navegador embutido) no canvas via `portal.open`.
/// Dentro de sessão gerenciada o workspace vem de COLMEIA_WORKSPACE_ID (§13.1);
/// fora, `--workspace <id>` é obrigatório (exit 3 sem ele).
/// `fill` / `key` / `shot` são reservados (rodada 3) — exit 64.
enum PortalCommand {
    static let usage = """
    uso: colmeia portal open <url> [--nome <apelido>] [--workspace <workspace-id>]
         colmeia portal fill|key|shot — reservado (rodada 3)
    """

    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        guard let sub = args.first else {
            printErr(usage)
            return CLIExit.uso
        }
        switch sub {
        case "open":
            do {
                try await open(Array(args.dropFirst()), context: context)
                return CLIExit.ok
            } catch let failure as CLIFailure {
                printErr(failure.message)
                return failure.code
            } catch {
                printErr("colmeia portal open: \(error)")
                return CLIExit.contexto
            }
        case "fill", "key", "shot":
            printErr("colmeia portal \(sub): reservado (rodada 3)")
            return CLIExit.uso
        default:
            printErr("subcomando desconhecido: portal \(sub)\n\(usage)")
            return CLIExit.uso
        }
    }

    private static func open(_ args: [String], context: CLIContext) async throws {
        var url: String?
        var nome: String?
        var workspaceFlag: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--nome":
                index += 1
                guard index < args.count else {
                    throw CLIFailure(code: CLIExit.uso, message: "--nome exige um valor\n\(usage)")
                }
                nome = args[index]
            case let flag where flag.hasPrefix("--nome="):
                nome = String(flag.dropFirst("--nome=".count))
            case "--workspace":
                index += 1
                guard index < args.count else {
                    throw CLIFailure(code: CLIExit.uso, message: "--workspace exige um id\n\(usage)")
                }
                workspaceFlag = args[index]
            case let flag where flag.hasPrefix("--workspace="):
                workspaceFlag = String(flag.dropFirst("--workspace=".count))
            case let flag where flag.hasPrefix("--"):
                throw CLIFailure(code: CLIExit.uso, message: "flag desconhecida: \(flag)\n\(usage)")
            default:
                guard url == nil else {
                    throw CLIFailure(code: CLIExit.uso, message: "url em duplicidade: \(arg)\n\(usage)")
                }
                url = arg
            }
            index += 1
        }
        guard let url, !url.isEmpty else {
            throw CLIFailure(code: CLIExit.uso, message: usage)
        }

        // Precedência: --workspace > COLMEIA_WORKSPACE_ID (§13.1); sem nenhum, exit 3.
        let workspaceID: ULID
        if let flag = workspaceFlag {
            guard let id = ULID(flag) else {
                throw CLIFailure(code: CLIExit.uso, message: "workspace id inválido: \(flag)")
            }
            workspaceID = id
        } else if let id = context.workspaceID {
            workspaceID = id
        } else {
            throw CLIFailure(
                code: CLIExit.contexto,
                message: "fora de sessão gerenciada, colmeia portal open exige --workspace <id> (§13.1)")
        }

        let client = try await connectEngine(context)
        defer { client.close() }

        let result: PortalOpenResult
        do {
            result = try await racedCall(
                client: client,
                watchdogSeconds: 30,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
            ) {
                try await client.call(
                    .portalOpen,
                    params: PortalOpenParams(workspaceID: workspaceID, url: url, nome: nome),
                    expecting: PortalOpenResult.self
                )
            }
        } catch {
            throw mapError(error)
        }
        print(result.nodeID.string)
    }

    private static func mapError(_ error: Error) -> CLIFailure {
        if let failure = error as? CLIFailure { return failure }
        if let proto = error as? ProtocolError {
            switch proto.known {
            case .invalid_params:
                // URL rejeitada pelo engine (http/https apenas) = erro de uso.
                return CLIFailure(code: CLIExit.uso, message: "colmeia portal open: \(proto)")
            case .workspace_not_found:
                return CLIFailure(code: CLIExit.destinoInexistente, message: "colmeia portal open: \(proto)")
            default:
                return CLIFailure(code: CLIExit.contexto, message: "colmeia portal open: \(proto)")
            }
        }
        return CLIFailure(code: CLIExit.contexto, message: "colmeia portal open: \(error)")
    }
}
