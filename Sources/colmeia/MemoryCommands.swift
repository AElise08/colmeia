import Foundation
import ColmeiaKit

enum MemoryCommand {
    static let usage = "uso: colmeia memory show|propose <resumo>|history [--json]"

    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        do {
            guard let command = args.first else { throw failure() }
            let identity = try context.requireAgentIdentity(subcomando: "memory")
            let client = try await connectEngine(context)
            defer { client.close() }
            switch command {
            case "show":
                guard args.dropFirst().allSatisfy({ $0 == "--json" }) else { throw failure() }
                let result: MemoryGetResult = try await call(client) {
                    try await client.call(.memoryGet, params: MemoryGetParams(workspaceID: identity.workspaceID), expecting: MemoryGetResult.self)
                }
                if args.contains("--json") {
                    let data = try ColmeiaJSON.encoder().encode(result)
                    print(String(decoding: data, as: UTF8.self))
                } else {
                    print(result.memory.content.isEmpty ? "(memória vazia)" : result.memory.content)
                }
            case "propose":
                let content = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { throw failure() }
                let proposal: MemoryProposal = try await call(client) {
                    try await client.call(
                        .memoryPropose,
                        params: MemoryProposeParams(workspaceID: identity.workspaceID, content: content),
                        expecting: MemoryProposal.self)
                }
                print("proposta \(proposal.id.string) pendente de revisão humana")
            case "history":
                guard args.dropFirst().allSatisfy({ $0 == "--json" }) else { throw failure() }
                let result: MemoryHistoryResult = try await call(client) {
                    try await client.call(.memoryHistory, params: MemoryHistoryParams(workspaceID: identity.workspaceID), expecting: MemoryHistoryResult.self)
                }
                if args.contains("--json") {
                    let data = try ColmeiaJSON.encoder().encode(result)
                    print(String(decoding: data, as: UTF8.self))
                } else {
                    for entry in result {
                        print("\(ISO8601DateFormatter().string(from: entry.timestamp))\t\(entry.action.rawValue)\t\(entry.author.rawValue)\(entry.proposalID.map { "\t\($0.string)" } ?? "")")
                    }
                }
            default:
                throw failure()
            }
            return CLIExit.ok
        } catch let error as CLIFailure {
            printErr(error.message); return error.code
        } catch {
            printErr("colmeia memory: \(error)"); return CLIExit.contexto
        }
    }

    private static func call<T: Sendable>(_ client: SocketClient, _ action: @escaping @Sendable () async throws -> T) async throws -> T {
        try await racedCall(client: client, watchdogSeconds: 30,
                            expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s"), action)
    }
    private static func failure() -> CLIFailure { CLIFailure(code: CLIExit.uso, message: usage) }
}

enum DoneCommand {
    static let usage = "uso: colmeia done --status <completed|partial|blocked|failed> --summary <resumo> [--delegation <id>] [--evidence <tipo:referência>] [--test <id:passed|failed|skipped>]"

    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        do {
            let identity = try context.requireAgentIdentity(subcomando: "done")
            guard let sessionID = context.sessionID else {
                throw CLIFailure(code: CLIExit.contexto, message: "colmeia done exige COLMEIA_SESSION_ID válido")
            }
            var status: DeliveryEstado?
            var summary: String?
            var delegationID: ULID?
            var evidence: [DeliveryEvidence] = []
            var index = 0
            while index < args.count {
                let argument = args[index]
                switch argument {
                case "--delegation":
                    index += 1; guard index < args.count, let id = ULID(args[index]) else { throw failure() }; delegationID = id
                case "--status":
                    index += 1; guard index < args.count else { throw failure() }
                    status = args[index] == "completed" ? .accepted : DeliveryEstado(rawValue: args[index])
                    guard status != nil else { throw failure() }
                case "--summary":
                    index += 1; guard index < args.count else { throw failure() }; summary = args[index]
                case "--evidence":
                    index += 1; guard index < args.count else { throw failure() }
                    evidence.append(try parseEvidence(args[index], author: context.author))
                case "--test":
                    index += 1; guard index < args.count else { throw failure() }
                    evidence.append(try parseTest(args[index], author: context.author))
                default: throw failure()
                }
                index += 1
            }
            guard let status, let summary else { throw failure() }
            if let delegationID {
                let client = try await connectEngine(context); defer { client.close() }
                let result: DelegationResult = try await racedCall(client: client, watchdogSeconds: 30, expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")) {
                    try await client.call(.delegationDone, params: DelegationDoneParams(delegationID: delegationID, status: status == .accepted ? .completed : .failed, result: summary), expecting: DelegationResult.self)
                }
                print("delegação \(result.delegation.id.string) \(result.delegation.estado.rawValue)")
                return CLIExit.ok
            }
            let submission = DeliverySubmission(
                id: ULID.generate(), workspaceID: identity.workspaceID, sessionID: sessionID, nodeID: identity.nodeID,
                estado: status, resumo: summary, evidencias: evidence)
            let client = try await connectEngine(context)
            defer { client.close() }
            let result: DeliveryResult = try await racedCall(
                client: client, watchdogSeconds: 30,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
            ) {
                try await client.call(.deliverySubmit, params: DeliverySubmitParams(submission: submission), expecting: DeliveryResult.self)
            }
            print("entrega \(result.delivery.id.string) enviada para revisão humana")
            return CLIExit.ok
        } catch let error as CLIFailure {
            printErr(error.message); return error.code
        } catch {
            printErr("colmeia done: \(error)"); return CLIExit.contexto
        }
    }

    private static func parseEvidence(_ raw: String, author: Author) throws -> DeliveryEvidence {
        guard let separator = raw.firstIndex(of: ":"),
              let type = DeliveryEvidenceTipo(rawValue: String(raw[..<separator]))
        else { throw failure() }
        let reference = String(raw[raw.index(after: separator)...])
        return DeliveryEvidence(id: ULID.generate(), tipo: type, referencia: reference, autor: author, criadaEm: Date())
    }

    private static func parseTest(_ raw: String, author: Author) throws -> DeliveryEvidence {
        guard let separator = raw.lastIndex(of: ":"),
              let outcome = DeliveryTestResultado(rawValue: String(raw[raw.index(after: separator)...]))
        else { throw failure() }
        return DeliveryEvidence(
            id: ULID.generate(), tipo: .test, referencia: String(raw[..<separator]),
            resultadoTeste: outcome, autor: author, criadaEm: Date())
    }

    private static func failure() -> CLIFailure { CLIFailure(code: CLIExit.uso, message: usage) }
}

enum DeliveriesCommand {
    static let usage = "uso: colmeia deliveries [--pending|--accepted] [--json]"

    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        do {
            let identity = try context.requireAgentIdentity(subcomando: "deliveries")
            var estado: DeliveryEstado?
            var json = false
            for argument in args {
                switch argument {
                case "--pending": estado = .proposed
                case "--accepted": estado = .accepted
                case "--json": json = true
                default: throw failure()
                }
            }
            let client = try await connectEngine(context)
            defer { client.close() }
            let estadoFilter = estado
            let result: DeliveryListResult = try await racedCall(
                client: client, watchdogSeconds: 30,
                expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s")
            ) {
                try await client.call(
                    .deliveryList,
                    params: DeliveryListParams(workspaceID: identity.workspaceID, estado: estadoFilter),
                    expecting: DeliveryListResult.self
                )
            }
            if json {
                let data = try ColmeiaJSON.encoder().encode(result)
                print(String(decoding: data, as: UTF8.self))
            } else {
                for delivery in result {
                    print("\(delivery.id.string)\t\(delivery.estado.rawValue)\t\(delivery.resumo)")
                }
            }
            return CLIExit.ok
        } catch let error as CLIFailure {
            printErr(error.message); return error.code
        } catch {
            printErr("colmeia deliveries: \(error)"); return CLIExit.contexto
        }
    }
    private static func failure() -> CLIFailure { CLIFailure(code: CLIExit.uso, message: usage) }
}
