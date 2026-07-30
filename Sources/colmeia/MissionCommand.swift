import Foundation
import ColmeiaKit

/// CLI §4.1.5 — canal do agente para Missão/Frente/Decisão/Relação.
enum MissionCommand {
    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        do {
            guard let sub = args.first else {
                printErr(usage)
                return CLIExit.uso
            }
            let rest = Array(args.dropFirst())
            switch sub {
            case "create":
                return try await createMission(rest, context: context)
            case "list":
                return try await listMissions(rest, context: context)
            case "transition":
                return try await transitionMission(rest, context: context)
            case "frente", "workstream":
                return try await frente(rest, context: context)
            case "decision", "decisao":
                return try await decision(rest, context: context)
            case "briefing":
                return try await briefing(rest, context: context)
            case "help", "--help", "-h":
                print(usage)
                return CLIExit.ok
            default:
                printErr("subcomando desconhecido: \(sub)\n\n\(usage)")
                return CLIExit.uso
            }
        } catch let failure as CLIFailure {
            printErr(failure.message)
            return failure.code
        } catch {
            printErr("\(error)")
            return CLIExit.contexto
        }
    }

    private static let usage = """
    colmeia mission create --room <id> --title <t> --done <dod> [--context <c>] [--owner <id>]
    colmeia mission list --room <id> [--json]
    colmeia mission transition --room <id> --id <mission> --state <state> [--reason <r>]
    colmeia mission frente create --room <id> --mission <id> --title <t> --objective <o> --done <dod>
    colmeia mission frente list --room <id> [--mission <id>] [--json]
    colmeia mission decision create --room <id> --mission <id> --question <q> [--workstream <id>]
    colmeia mission decision decide --room <id> --id <decision> --text <t> [--rationale <r>]
    colmeia mission briefing --room <id> --workstream <id> --agent <nome> [--role <papel>]
    """

    private static func extractHub(from args: [String]) -> (hubURL: String?, hubToken: String?, remaining: [String]) {
        var hubURL: String?
        var hubToken: String?
        var remaining = [String]()
        var i = 0
        while i < args.count {
            if args[i] == "--hub", i + 1 < args.count {
                hubURL = args[i + 1]; i += 2
            } else if args[i].hasPrefix("--hub=") {
                hubURL = String(args[i].dropFirst(6)); i += 1
            } else if args[i] == "--hub-token", i + 1 < args.count {
                hubToken = args[i + 1]; i += 2
            } else if args[i].hasPrefix("--hub-token=") {
                hubToken = String(args[i].dropFirst(12)); i += 1
            } else {
                remaining.append(args[i]); i += 1
            }
        }
        return (hubURL, hubToken, remaining)
    }

    private static func createMission(_ args: [String], context: CLIContext) async throws -> Int32 {
        let (hubURL, hubToken, clean) = extractHub(from: args)
        let ctx = CLIContext(socketPath: hubURL ?? context.socketPath, hubToken: hubToken ?? context.hubToken)
        let flags = try parseFlags(clean, required: ["room", "title", "done"])
        let client = try await connectEngine(ctx)
        defer { client.close() }
        let result: MissionResult = try await client.call(
            .missionCreate,
            params: MissionCreateParams(
                roomID: try ulid(flags["room"]!, label: "room"),
                title: flags["title"]!,
                context: flags["context"],
                definitionOfDone: flags["done"]!,
                ownerID: flags["owner"]
            ),
            expecting: MissionResult.self
        )
        print(result.mission.id.string)
        return CLIExit.ok
    }

    private static func listMissions(_ args: [String], context: CLIContext) async throws -> Int32 {
        let (hubURL, hubToken, clean) = extractHub(from: args)
        let ctx = CLIContext(socketPath: hubURL ?? context.socketPath, hubToken: hubToken ?? context.hubToken)
        let flags = try parseFlags(clean, required: ["room"])
        let client = try await connectEngine(ctx)
        defer { client.close() }
        let list: MissionListResult = try await client.call(
            .missionList,
            params: MissionListParams(roomID: try ulid(flags["room"]!, label: "room")),
            expecting: MissionListResult.self
        )
        if flags["json"] != nil {
            print(String(decoding: try ColmeiaJSON.encoder().encode(list), as: UTF8.self))
        } else {
            for m in list {
                print("\(m.id.string)\t\(m.state.rawValue)\t\(m.title)")
            }
        }
        return CLIExit.ok
    }

    private static func transitionMission(_ args: [String], context: CLIContext) async throws -> Int32 {
        let (hubURL, hubToken, clean) = extractHub(from: args)
        let ctx = CLIContext(socketPath: hubURL ?? context.socketPath, hubToken: hubToken ?? context.hubToken)
        let flags = try parseFlags(clean, required: ["room", "id", "state"])
        guard let state = MissionState(rawValue: flags["state"]!) else {
            throw CLIFailure(code: CLIExit.uso, message: "state inválido: \(flags["state"]!)")
        }
        let client = try await connectEngine(ctx)
        defer { client.close() }
        let result: MissionResult = try await client.call(
            .missionTransition,
            params: MissionTransitionParams(
                roomID: try ulid(flags["room"]!, label: "room"),
                missionID: try ulid(flags["id"]!, label: "id"),
                state: state,
                reason: flags["reason"]
            ),
            expecting: MissionResult.self
        )
        print(result.mission.state.rawValue)
        return CLIExit.ok
    }

    private static func frente(_ args: [String], context: CLIContext) async throws -> Int32 {
        let (hubURL, hubToken, clean) = extractHub(from: args)
        let ctx = CLIContext(socketPath: hubURL ?? context.socketPath, hubToken: hubToken ?? context.hubToken)
        guard let sub = clean.first else {
            printErr(usage)
            return CLIExit.uso
        }
        let rest = Array(clean.dropFirst())
        switch sub {
        case "create":
            let flags = try parseFlags(rest, required: ["room", "mission", "title", "objective", "done"])
            let client = try await connectEngine(ctx)
            defer { client.close() }
            let result: WorkstreamResult = try await client.call(
                .workstreamCreate,
                params: WorkstreamCreateParams(
                    roomID: try ulid(flags["room"]!, label: "room"),
                    missionID: try ulid(flags["mission"]!, label: "mission"),
                    title: flags["title"]!,
                    objective: flags["objective"]!,
                    definitionOfDone: flags["done"]!
                ),
                expecting: WorkstreamResult.self
            )
            print(result.workstream.id.string)
            return CLIExit.ok
        case "list":
            let flags = try parseFlags(rest, required: ["room"])
            let client = try await connectEngine(ctx)
            defer { client.close() }
            let missionID: ULID? = try flags["mission"].map { try ulid($0, label: "mission") }
            let list: WorkstreamListResult = try await client.call(
                .workstreamList,
                params: WorkstreamListParams(
                    roomID: try ulid(flags["room"]!, label: "room"),
                    missionID: missionID
                ),
                expecting: WorkstreamListResult.self
            )
            if flags["json"] != nil {
                print(String(decoding: try ColmeiaJSON.encoder().encode(list), as: UTF8.self))
            } else {
                for w in list {
                    print("\(w.id.string)\t\(w.state.rawValue)\t\(w.title)")
                }
            }
            return CLIExit.ok
        default:
            printErr("frente: subcomando desconhecido: \(sub)")
            return CLIExit.uso
        }
    }

    private static func decision(_ args: [String], context: CLIContext) async throws -> Int32 {
        let (hubURL, hubToken, clean) = extractHub(from: args)
        let ctx = CLIContext(socketPath: hubURL ?? context.socketPath, hubToken: hubToken ?? context.hubToken)
        guard let sub = clean.first else {
            printErr(usage)
            return CLIExit.uso
        }
        let rest = Array(clean.dropFirst())
        switch sub {
        case "create":
            let flags = try parseFlags(rest, required: ["room", "mission", "question"])
            let client = try await connectEngine(ctx)
            defer { client.close() }
            let ws: ULID? = try flags["workstream"].map { try ulid($0, label: "workstream") }
            let result: DecisionResult = try await client.call(
                .decisionCreate,
                params: DecisionCreateParams(
                    roomID: try ulid(flags["room"]!, label: "room"),
                    missionID: try ulid(flags["mission"]!, label: "mission"),
                    workstreamID: ws,
                    question: flags["question"]!
                ),
                expecting: DecisionResult.self
            )
            print(result.decision.id.string)
            return CLIExit.ok
        case "decide":
            let flags = try parseFlags(rest, required: ["room", "id", "text"])
            let client = try await connectEngine(ctx)
            defer { client.close() }
            let result: DecisionResult = try await client.call(
                .decisionDecide,
                params: DecisionDecideParams(
                    roomID: try ulid(flags["room"]!, label: "room"),
                    decisionID: try ulid(flags["id"]!, label: "id"),
                    decision: flags["text"]!,
                    rationale: flags["rationale"]
                ),
                expecting: DecisionResult.self
            )
            print(result.decision.state.rawValue)
            return CLIExit.ok
        default:
            printErr("decision: subcomando desconhecido: \(sub)")
            return CLIExit.uso
        }
    }

    private static func briefing(_ args: [String], context: CLIContext) async throws -> Int32 {
        let (hubURL, hubToken, clean) = extractHub(from: args)
        let ctx = CLIContext(socketPath: hubURL ?? context.socketPath, hubToken: hubToken ?? context.hubToken)
        let flags = try parseFlags(clean, required: ["room", "workstream", "agent"])
        let client = try await connectEngine(ctx)
        defer { client.close() }
        let result: WorkstreamBriefingResult = try await client.call(
            .workstreamBriefing,
            params: WorkstreamBriefingParams(
                roomID: try ulid(flags["room"]!, label: "room"),
                workstreamID: try ulid(flags["workstream"]!, label: "workstream"),
                agentName: flags["agent"]!,
                agentRole: flags["role"]
            ),
            expecting: WorkstreamBriefingResult.self
        )
        print(result.briefing)
        return CLIExit.ok
    }

    private static func parseFlags(_ args: [String], required: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var i = 0
        while i < args.count {
            let token = args[i]
            if token == "--json" {
                result["json"] = "1"
                i += 1
                continue
            }
            guard token.hasPrefix("--") else {
                throw CLIFailure(code: CLIExit.uso, message: "flag inesperada: \(token)")
            }
            let key = String(token.dropFirst(2))
            i += 1
            guard i < args.count else {
                throw CLIFailure(code: CLIExit.uso, message: "faltou valor para --\(key)")
            }
            result[key] = args[i]
            i += 1
        }
        for key in required where result[key] == nil {
            throw CLIFailure(code: CLIExit.uso, message: "faltou --\(key)")
        }
        return result
    }

    private static func ulid(_ raw: String, label: String) throws -> ULID {
        guard let id = ULID(raw) else {
            throw CLIFailure(code: CLIExit.uso, message: "\(label) inválido: \(raw)")
        }
        return id
    }
}
