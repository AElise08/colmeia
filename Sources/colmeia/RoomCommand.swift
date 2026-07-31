import Foundation
import ColmeiaKit

enum RoomCommand {
    static let usage = """
    uso:
      colmeia room create <nome> [--json]
      colmeia room list [--json]
      colmeia room join <room-id> [--token <convite>] [--json]
      colmeia room leave <room-id>
      colmeia room delete <room-id>
      colmeia room members <room-id> [--json]
      colmeia room member remove <room-id> <member-id>
      colmeia room invite <room-id> <nome> [--role owner|editor|viewer]
      colmeia room snapshot <room-id> [--since <room-seq>] [--json]
      colmeia room event <room-id> <session-id> --kind <kind> --text <texto> [--json]
    """

    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        guard let sub = args.first else { printErr(usage); return CLIExit.uso }
        let tail = Array(args.dropFirst())
        switch sub {
        case "create": return await create(tail, context: context)
        case "list":   return await list(tail, context: context)
        case "join":   return await join(tail, context: context)
        case "leave":  return await leave(tail, context: context)
        case "delete": return await deleteRoom(tail, context: context)
        case "members": return await members(tail, context: context)
        case "member":  return await member(tail, context: context)
        case "invite":  return await invite(tail, context: context)
        case "snapshot": return await snapshot(tail, context: context)
        case "event":  return await event(tail, context: context)
        case "help", "--help", "-h": print(usage); return CLIExit.ok
        default: printErr("colmeia room: subcomando desconhecido: \(sub)\n\(usage)"); return CLIExit.uso
        }
    }

    private static func fail(_ msg: String = usage) -> CLIFailure { CLIFailure(code: CLIExit.uso, message: msg) }

    private static func extractHubURL(from args: [String]) -> (hubURL: String?, hubToken: String?, remaining: [String]) {
        var hubURL: String?
        var hubToken: String?
        var remaining: [String] = []
        var i = 0
        while i < args.count {
            if (args[i] == "--hub" || args[i] == "--socket"), i + 1 < args.count {
                hubURL = args[i + 1]
                i += 2
                continue
            } else if args[i].hasPrefix("--hub=") {
                hubURL = String(args[i].dropFirst("--hub=".count))
                i += 1
                continue
            } else if args[i].hasPrefix("--socket=") {
                hubURL = String(args[i].dropFirst("--socket=".count))
                i += 1
                continue
            } else if args[i] == "--hub-token", i + 1 < args.count {
                hubToken = args[i + 1]
                i += 2
                continue
            } else if args[i].hasPrefix("--hub-token=") {
                hubToken = String(args[i].dropFirst("--hub-token=".count))
                i += 1
                continue
            }
            remaining.append(args[i])
            i += 1
        }
        return (hubURL, hubToken, remaining)
    }

    private static func create(_ args: [String], context: CLIContext) async -> Int32 {
        do {
            let (hubURL, hubToken, cleanArgs) = extractHubURL(from: args)
            guard let nome = cleanArgs.first, !nome.hasPrefix("--") else { throw fail() }
            let json = cleanArgs.contains("--json")
            let client = try await connectEngine(CLIContext(socketPath: hubURL ?? context.socketPath, hubToken: hubToken ?? context.hubToken))
            defer { client.close() }
            let room: RoomResult = try await client.call(.roomCreate, params: RoomCreateParams(name: nome), expecting: RoomResult.self)
            if json {
                print(String(decoding: try ColmeiaJSON.encoder().encode(room.room), as: UTF8.self))
            } else {
                print("sala criada: \(room.room.name) (\(room.room.id.string))")
            }
            return CLIExit.ok
        } catch let e as CLIFailure { printErr(e.message); return e.code }
        catch { printErr("colmeia room create: \(error)"); return CLIExit.contexto }
    }

    private static func list(_ args: [String], context: CLIContext) async -> Int32 {
        do {
            let (hubURL, hubToken, cleanArgs) = extractHubURL(from: args)
            let json = cleanArgs.contains("--json")
            let client = try await connectEngine(CLIContext(socketPath: hubURL ?? context.socketPath, hubToken: hubToken ?? context.hubToken))
            defer { client.close() }
            let rooms: RoomListResult = try await client.call(.roomList, expecting: RoomListResult.self)
            if json {
                print(String(decoding: try ColmeiaJSON.encoder().encode(rooms), as: UTF8.self))
            } else {
                for room in rooms {
                    let state = room.state == .active ? "" : " [\(room.state.rawValue)]"
                    print("\(room.id.string)  \(room.name)\(state)")
                }
                if rooms.isEmpty { print("(nenhuma sala)") }
            }
            return CLIExit.ok
        } catch let e as CLIFailure { printErr(e.message); return e.code }
        catch { printErr("colmeia room list: \(error)"); return CLIExit.contexto }
    }

    private static func join(_ args: [String], context: CLIContext) async -> Int32 {
        do {
            let (hubURL, hubToken, cleanArgs) = extractHubURL(from: args)
            guard let idString = cleanArgs.first, let roomID = ULID(idString) else { throw fail() }
            let json = cleanArgs.contains("--json")
            let tokenIdx = cleanArgs.firstIndex(of: "--token")
            let inviteToken = tokenIdx.flatMap { i in i + 1 < cleanArgs.count ? cleanArgs[i + 1] : nil }
            let client = try await connectEngine(CLIContext(socketPath: hubURL ?? context.socketPath, hubToken: hubToken ?? context.hubToken))
            defer { client.close() }
            let result: RoomJoinResult = try await client.call(.roomJoin, params: RoomJoinParams(roomID: roomID, inviteToken: inviteToken), expecting: RoomJoinResult.self)
            if json {
                print(String(decoding: try ColmeiaJSON.encoder().encode(result), as: UTF8.self))
            } else {
                print("entrou na sala: \(result.room.name)")
                print("\(result.members.count) membro(s), \(result.agentSessions.count) sessão(ões)")
                for m in result.members { print("  \(m.displayName) [\(m.roles.map(\.rawValue).joined(separator: ","))]") }
            }
            return CLIExit.ok
        } catch let e as CLIFailure { printErr(e.message); return e.code }
        catch { printErr("colmeia room join: \(error)"); return CLIExit.contexto }
    }

    private static func leave(_ args: [String], context: CLIContext) async -> Int32 {
        do {
            guard let idString = args.first, let roomID = ULID(idString) else { throw fail() }
            let client = try await connectEngine(context)
            defer { client.close() }
            _ = try await client.call(.roomLeave, params: RoomLeaveParams(roomID: roomID))
            print("saiu da sala \(roomID.string)")
            return CLIExit.ok
        } catch let e as CLIFailure { printErr(e.message); return e.code }
        catch { printErr("colmeia room leave: \(error)"); return CLIExit.contexto }
    }

    private static func deleteRoom(_ args: [String], context: CLIContext) async -> Int32 {
        do {
            let (hubURL, hubToken, cleanArgs) = extractHubURL(from: args)
            guard let idString = cleanArgs.first, let roomID = ULID(idString) else { throw fail() }
            let client = try await connectEngine(CLIContext(
                socketPath: hubURL ?? context.socketPath,
                hubToken: hubToken ?? context.hubToken))
            defer { client.close() }
            _ = try await client.call(.roomDelete, params: RoomDeleteParams(roomID: roomID, confirmar: true))
            print("sala removida: \(roomID.string)")
            return CLIExit.ok
        } catch let e as CLIFailure { printErr(e.message); return e.code }
        catch { printErr("colmeia room delete: \(error)"); return CLIExit.contexto }
    }

    private static func member(_ args: [String], context: CLIContext) async -> Int32 {
        guard let sub = args.first else { printErr("colmeia room member: use remove <room-id> <member-id>"); return CLIExit.uso }
        let tail = Array(args.dropFirst())
        switch sub {
        case "remove": return await removeMember(tail, context: context)
        default: printErr("colmeia room member: subcomando desconhecido: \(sub)\nuso: member remove <room-id> <member-id>"); return CLIExit.uso
        }
    }

    private static func removeMember(_ args: [String], context: CLIContext) async -> Int32 {
        do {
            guard args.count >= 2, let roomID = ULID(args[0]) else { throw fail() }
            let memberID = args[1]
            let client = try await connectEngine(context)
            defer { client.close() }
            _ = try await client.call(.memberRemove, params: MemberRemoveParams(roomID: roomID, memberID: memberID))
            print("membro removido: \(memberID)")
            return CLIExit.ok
        } catch let e as CLIFailure { printErr(e.message); return e.code }
        catch { printErr("colmeia room member remove: \(error)"); return CLIExit.contexto }
    }

    private static func members(_ args: [String], context: CLIContext) async -> Int32 {
        do {
            let (hubURL, hubToken, cleanArgs) = extractHubURL(from: args)
            guard let idString = cleanArgs.first, let roomID = ULID(idString) else { throw fail() }
            let json = cleanArgs.contains("--json")
            let client = try await connectEngine(CLIContext(socketPath: hubURL ?? context.socketPath, hubToken: hubToken ?? context.hubToken))
            defer { client.close() }
            let members: MemberListResult = try await client.call(.memberList, params: MemberListParams(roomID: roomID), expecting: MemberListResult.self)
            if json {
                print(String(decoding: try ColmeiaJSON.encoder().encode(members), as: UTF8.self))
            } else {
                for m in members {
                    let s = m.status == .active ? "" : " [\(m.status.rawValue)]"
                    print("\(m.displayName)  \(m.roles.map(\.rawValue).joined(separator: ","))\(s)  (\(m.id))")
                }
                if members.isEmpty { print("(nenhum membro)") }
            }
            return CLIExit.ok
        } catch let e as CLIFailure { printErr(e.message); return e.code }
        catch { printErr("colmeia room members: \(error)"); return CLIExit.contexto }
    }

    private static func invite(_ args: [String], context: CLIContext) async -> Int32 {
        do {
            let (hubURL, hubToken, cleanArgs) = extractHubURL(from: args)
            guard let roomString = cleanArgs.first, let roomID = ULID(roomString) else { throw fail() }
            guard cleanArgs.count >= 2 else { throw fail() }
            let nome = cleanArgs[1]
            let role = cleanArgs.contains("--role") ? (cleanArgs.firstIndex(of: "--role").flatMap { i in i + 1 < cleanArgs.count ? cleanArgs[i + 1] : nil }) ?? "viewer" : "viewer"
            guard let memberRole = MemberRole(rawValue: role) else { throw fail("papel inválido: \(role)") }
            let client = try await connectEngine(CLIContext(socketPath: hubURL ?? context.socketPath, hubToken: hubToken ?? context.hubToken))
            defer { client.close() }
            let result: MemberInviteResult = try await client.call(
                .memberInvite,
                params: MemberInviteParams(roomID: roomID, displayName: nome, roles: [memberRole]),
                expecting: MemberInviteResult.self)
            print("\(result.member.displayName) convidado como \(result.member.roles.map(\.rawValue).joined(separator: ","))")
            print("token: \(result.inviteToken)")
            return CLIExit.ok
        } catch let e as CLIFailure { printErr(e.message); return e.code }
        catch { printErr("colmeia room invite: \(error)"); return CLIExit.contexto }
    }

    private static func snapshot(_ args: [String], context: CLIContext) async -> Int32 {
        do {
            guard let idString = args.first, let roomID = ULID(idString) else { throw fail() }
            var since: UInt64?
            var json = false
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--since":
                    i += 1; guard i < args.count, let v = UInt64(args[i]) else { throw fail() }
                    since = v
                case let v where v.hasPrefix("--since="): since = UInt64(String(v.dropFirst("--since=".count)))
                case "--json": json = true
                default: throw fail()
                }
                i += 1
            }
            let client = try await connectEngine(context)
            defer { client.close() }
            let snap: RoomSnapshotResult = try await client.call(.roomSnapshot, params: RoomSnapshotParams(roomID: roomID, sinceRoomSeq: since), expecting: RoomSnapshotResult.self)
            if json {
                print(String(decoding: try ColmeiaJSON.encoder().encode(snap), as: UTF8.self))
            } else {
                print("sala: \(snap.room.name)  seq=\(snap.roomSeq)")
                print("\nmembros (\(snap.members.count)):")
                for m in snap.members { print("  \(m.displayName) [\(m.roles.map(\.rawValue).joined(separator: ","))]") }
                print("\nsessões (\(snap.agentSessions.count)):")
                for s in snap.agentSessions { print("  \(s.id.string)  \(s.state.rawValue)  \(s.objective ?? "-")") }
                print("\neventos (\(snap.events.count)):")
                for e in snap.events {
                    let kind = e.kind.rawValue
                    let text = e.payload.texto ?? e.payload.direction ?? e.payload.summary ?? e.payload.decision ?? ""
                    print("  [\(e.logicalClock)] \(kind): \(text)")
                }
            }
            return CLIExit.ok
        } catch let e as CLIFailure { printErr(e.message); return e.code }
        catch { printErr("colmeia room snapshot: \(error)"); return CLIExit.contexto }
    }

    private static func event(_ args: [String], context: CLIContext) async -> Int32 {
        do {
            guard args.count >= 4,
                  let roomID = ULID(args[0]),
                  let sessionID = ULID(args[1]) else { throw fail() }

            var kind: CollaborativeEventKind = .messageSent
            var texto: String?
            var direction: String?
            var decision: String?
            var json = false
            var i = 2
            while i < args.count {
                switch args[i] {
                case "--kind": i += 1; guard i < args.count, let k = CollaborativeEventKind(rawValue: args[i]) else { throw fail() }; kind = k
                case let v where v.hasPrefix("--kind="): kind = CollaborativeEventKind(rawValue: String(v.dropFirst("--kind=".count))) ?? .messageSent
                case "--text": i += 1; guard i < args.count else { throw fail() }; texto = args[i]
                case let v where v.hasPrefix("--text="): texto = String(v.dropFirst("--text=".count))
                case "--direction": i += 1; guard i < args.count else { throw fail() }; direction = args[i]
                case let v where v.hasPrefix("--direction="): direction = String(v.dropFirst("--direction=".count))
                case "--decision": i += 1; guard i < args.count else { throw fail() }; decision = args[i]
                case let v where v.hasPrefix("--decision="): decision = String(v.dropFirst("--decision=".count))
                case "--json": json = true
                default: throw fail()
                }
                i += 1
            }

            let payload = CollaborativeEventPayload(texto: texto, direction: direction, decision: decision)
            let client = try await connectEngine(context)
            defer { client.close() }
            let result: SessionEventAppendResult = try await client.call(
                .sessionEventAppend,
                params: SessionEventAppendParams(roomID: roomID, sessionID: sessionID, kind: kind, payload: payload),
                expecting: SessionEventAppendResult.self)
            if json {
                print(String(decoding: try ColmeiaJSON.encoder().encode(result), as: UTF8.self))
            } else {
                print("evento [\(result.roomSeq)]: \(result.event.kind.rawValue)")
            }
            return CLIExit.ok
        } catch let e as CLIFailure { printErr(e.message); return e.code }
        catch { printErr("colmeia room event: \(error)"); return CLIExit.contexto }
    }
}
