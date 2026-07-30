import Foundation
import ColmeiaKit

/// `colmeia portal open <url> ...` — cria portal.
/// `colmeia portal command <node-id> <action> [args...]` — automação do portal.
enum PortalCommand {
    static let usage = """
    uso: colmeia portal open <url> [--nome <apelido>] [--workspace <workspace-id>] [--floor <floor-id>]
         colmeia portal command <node-id> navigate <url>
         colmeia portal command <node-id> shot [--selector <css>]
         colmeia portal command <node-id> snapshot
         colmeia portal command <node-id> click <selector>
         colmeia portal command <node-id> fill <selector> <value>
         colmeia portal command <node-id> key <keys>
         colmeia portal command <node-id> eval <code>
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
        case "command":
            do {
                try await command(Array(args.dropFirst()), context: context)
                return CLIExit.ok
            } catch let failure as CLIFailure {
                printErr(failure.message)
                return failure.code
            } catch {
                printErr("colmeia portal command: \(error)")
                return CLIExit.contexto
            }
        default:
            printErr("subcomando desconhecido: portal \(sub)\n\(usage)")
            return CLIExit.uso
        }
    }

    private static func open(_ args: [String], context: CLIContext) async throws {
        var url: String?
        var nome: String?
        var workspaceFlag: String?
        var floorFlag: String?
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
            case "--floor":
                index += 1
                guard index < args.count else {
                    throw CLIFailure(code: CLIExit.uso, message: "--floor exige um id\n\(usage)")
                }
                floorFlag = args[index]
            case let flag where flag.hasPrefix("--floor="):
                floorFlag = String(flag.dropFirst("--floor=".count))
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
        let floorID: ULID?
        if let floorFlag {
            guard let id = ULID(floorFlag) else {
                throw CLIFailure(code: CLIExit.uso, message: "floor id inválido: \(floorFlag)")
            }
            floorID = id
        } else {
            floorID = nil
        }

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
                message: "fora de sessão gerenciada, colmeia portal open exige --workspace <id>")
        }

        let client = try await connectEngine(context)
        defer { client.close() }

        let nomeFinal = nome
        let result: PortalOpenResult
        do {
            result = try await racedCall(
                client: client,
                watchdogSeconds: 30,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
            ) {
                try await client.call(
                    .portalOpen,
                    params: PortalOpenParams(workspaceID: workspaceID, url: url, nome: nomeFinal, floorID: floorID),
                    expecting: PortalOpenResult.self
                )
            }
        } catch {
            throw mapError(error)
        }
        print(result.nodeID.string)
    }

    private static func command(_ args: [String], context: CLIContext) async throws {
        guard args.count >= 2, let nodeID = ULID(args[0]) else {
            throw CLIFailure(code: CLIExit.uso, message: usage)
        }
        let action = args[1]
        let rest = Array(args.dropFirst(2))

        let workspaceID: ULID
        if let id = context.workspaceID {
            workspaceID = id
        } else {
            throw CLIFailure(
                code: CLIExit.contexto,
                message: "fora de sessão gerenciada, colmeia portal command exige COLMEIA_WORKSPACE_ID")
        }

        let client = try await connectEngine(context)
        defer { client.close() }

        let acao: PortalCommandAction
        var url: String?
        var selector: String?
        var value: String?
        var keys: String?
        var code: String?

        switch action {
        case "navigate":
            guard rest.count == 1 else { throw CLIFailure(code: CLIExit.uso, message: usage) }
            acao = .navigate
            url = rest[0]
        case "shot":
            acao = .shot
            var ri = 0
            while ri < rest.count {
                switch rest[ri] {
                case "--selector":
                    ri += 1; guard ri < rest.count else { throw CLIFailure(code: CLIExit.uso, message: usage) }
                    selector = rest[ri]
                case let f where f.hasPrefix("--selector="):
                    selector = String(f.dropFirst("--selector=".count))
                default:
                    throw CLIFailure(code: CLIExit.uso, message: usage)
                }
                ri += 1
            }
        case "snapshot":
            guard rest.isEmpty else { throw CLIFailure(code: CLIExit.uso, message: usage) }
            acao = .snapshot
        case "click":
            guard rest.count == 1 else { throw CLIFailure(code: CLIExit.uso, message: usage) }
            acao = .click
            selector = rest[0]
        case "fill":
            guard rest.count == 2 else { throw CLIFailure(code: CLIExit.uso, message: usage) }
            acao = .fill
            selector = rest[0]
            value = rest[1]
        case "key":
            guard rest.count == 1 else { throw CLIFailure(code: CLIExit.uso, message: usage) }
            acao = .key
            keys = rest[0]
        case "eval":
            guard rest.count == 1 else { throw CLIFailure(code: CLIExit.uso, message: usage) }
            acao = .eval
            code = rest[0]
        default:
            throw CLIFailure(code: CLIExit.uso, message: "ação desconhecida: \(action)\n\(usage)")
        }

        let result: PortalCommandResult
        let cmdParams = PortalCommandParams(
            workspaceID: workspaceID, nodeID: nodeID, acao: acao,
            url: url, selector: selector, value: value, keys: keys, code: code)
        do {
            result = try await racedCall(
                client: client,
                watchdogSeconds: 60,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 60s")
            ) {
                try await client.call(
                    .portalCommand,
                    params: cmdParams,
                    expecting: PortalCommandResult.self
                )
            }
        } catch {
            throw mapError(error)
        }
        print(result.resultado)
        if let b64 = result.dataB64 {
            print("data_b64: \(b64.prefix(80))... (\(b64.count) bytes)")
        }
    }

    private static func mapError(_ error: Error) -> CLIFailure {
        if let failure = error as? CLIFailure { return failure }
        if let proto = error as? ProtocolError {
            switch proto.known {
            case .invalid_params:
                return CLIFailure(code: CLIExit.uso, message: "colmeia portal: \(proto)")
            case .workspace_not_found, .node_not_found:
                return CLIFailure(code: CLIExit.destinoInexistente, message: "colmeia portal: \(proto)")
            default:
                return CLIFailure(code: CLIExit.contexto, message: "colmeia portal: \(proto)")
            }
        }
        return CLIFailure(code: CLIExit.contexto, message: "colmeia portal: \(error)")
    }
}
