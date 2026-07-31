import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ColmeiaKit

/// Servidor NDJSON sobre TCP para o Hub colaborativo (Fase 1).
/// Substitui o Unix domain socket do engine local por transporte de rede.
public final class HubServer: @unchecked Sendable {
    public let paths: ColmeiaPaths
    public let version: String
    /// Token de autenticação opcional. Se definido, todo cliente deve enviá-lo no hello.
    public var hubToken: String?
    /// URL do Engine para proxy — Unix socket (path) ou tcp://host:port.
    public var engineURL: String?
    /// Limites defensivos por conexão. Podem ser reduzidos por hosts públicos.
    public var maxRequestsPerSecond = 120
    public var maxBytesPerSecond = 2 * 1024 * 1024
    public var maxRequestBytes = 1 * 1024 * 1024

    private let host: String
    private let port: UInt16
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "colmeia.hub.accept")
    private let stateQueue = DispatchQueue(label: "colmeia.hub.state")

    var roomStores: [ULID: RoomStore] = [:]
    var missionStores: [ULID: MissionStore] = [:]
    var workspaceStores: [ULID: WorkspaceStore] = [:]
    var sessionToWorkspace: [ULID: ULID] = [:] // sessionID → workspaceID
    var clients: [ObjectIdentifier: HubClient] = [:]
    private var shuttingDown = false
    private var tickTimer: DispatchSourceTimer?
    private let syncRequestLock = NSLock()
    private var pendingSessionStarts: [String: (SyncSessionStartResult) -> Void] = [:]

    var engineConn: EngineConnection?

    private(set) var log = HubLogger()

    public init(
        paths: ColmeiaPaths = ColmeiaPaths(),
        host: String = "0.0.0.0",
        port: UInt16 = 9620
    ) {
        self.paths = paths
        self.version = ColmeiaVersion.string
        self.host = host
        self.port = port
    }

    public func start() throws {
        try paths.ensureRootLayout()
        scanRooms()
        missionStores = Dictionary(uniqueKeysWithValues: roomStores.keys.map { roomID in
            (roomID, (try? MissionStore.load(from: paths, roomID: roomID)) ?? MissionStore(roomID: roomID))
        })
        workspaceStores = WorkspaceStore.loadAll(from: paths.workspacesDir)
        for (workspaceID, store) in workspaceStores {
            for sessionID in store.sessionStates.keys {
                sessionToWorkspace[sessionID] = workspaceID
            }
        }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        hints.ai_flags = AI_PASSIVE
        hints.ai_protocol = 0

        var result: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        let status = host.withCString { h in
            portString.withCString { p in
                getaddrinfo(h, p, &hints, &result)
            }
        }
        guard status == 0, let info = result else {
            throw HubError.io("getaddrinfo", Int32(status))
        }
        defer { freeaddrinfo(result) }

        var bound = false
        for addr in sequence(first: info, next: { $0.pointee.ai_next }) {
            let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            if fd < 0 { continue }

            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

            if bind(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0,
               listen(fd, 128) == 0 {
                listenFD = fd
                bound = true
                break
            }
            close(fd)
        }
        guard bound else {
            throw HubError.io("bind \(host):\(port)", errno)
        }

        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif

        if let engineURL {
            let conn = EngineConnection(url: engineURL, hub: self)
            engineConn = conn
            conn.start()
        }
        log.info("hub_listening", "Colmeia Hub \(version) — \(host):\(port)")

        acceptQueue.async { [weak self] in self?.acceptLoop() }
        startTick()
    }

    public func stop() {
        shuttingDown = true
        engineConn?.stop()
        tickTimer?.cancel()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        stateQueue.sync {
            for client in clients.values { client.close() }
            clients.removeAll()
        }
    }

    // MARK: - Engine Proxy

    private func callEngine(method: String, params: JSONValue?) throws -> JSONValue {
        let fd = try connectToEngineSocket()
        defer { close(fd) }

        let helloID = "px-h-\(ULID.generate().string)"
        let callID = "px-c-\(ULID.generate().string)"
        var lineBuffer = SocketFraming.LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        let helloReq = RequestMessage(id: helloID, method: "hello",
            params: try? JSONValue(encoding: HelloParams(
                protocolVersion: ColmeiaVersion.protocolVersion,
                client: "colmeia-hub",
                author: Author.humanoLocal)))
        try SocketFraming.writeLine(fd: fd, SocketFraming.encodeLine(Envelope.request(helloReq)))

        let helloResp = try readEngineResponse(fd: fd, expectedID: helloID, lineBuffer: &lineBuffer, chunk: &chunk)
        guard helloResp.ok else {
            throw helloResp.error ?? ProtocolError(name: .internal_error, message: "engine hello falhou")
        }

        let callReq = RequestMessage(id: callID, method: method, params: params)
        try SocketFraming.writeLine(fd: fd, SocketFraming.encodeLine(Envelope.request(callReq)))

        let resp = try readEngineResponse(fd: fd, expectedID: callID, lineBuffer: &lineBuffer, chunk: &chunk)
        if resp.ok {
            return resp.result ?? .object([:])
        }
        throw resp.error ?? ProtocolError(name: .internal_error, message: "erro do engine")
    }

    private func connectToEngineSocket() throws -> Int32 {
        let raw = engineURL ?? paths.engineSocket.path

        // TCP — se contém : ou prefixo explícito
        if raw.hasPrefix("tcp://") || raw.contains(":") {
            let clean: String
            if raw.hasPrefix("tcp://") {
                clean = String(raw.dropFirst(6))
            } else {
                clean = raw
            }
            let parts = clean.split(separator: ":")
            let host = parts.count > 0 ? String(parts[0]) : "127.0.0.1"
            let port = parts.count > 1 ? (UInt16(parts[1]) ?? 9620) : 9620

            var hints = addrinfo()
            hints.ai_family = AF_INET
            #if canImport(Darwin)
            hints.ai_socktype = SOCK_STREAM
            #else
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
            #endif

            var res: UnsafeMutablePointer<addrinfo>?
            let portStr = String(port)
            let status = host.withCString { h in
                portStr.withCString { p in
                    getaddrinfo(h, p, &hints, &res)
                }
            }
            guard status == 0, let info = res else {
                throw ProtocolError(name: .internal_error, message: "getaddrinfo(\(clean)) falhou")
            }
            defer { freeaddrinfo(res) }

            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else {
                throw ProtocolError(name: .internal_error, message: "socket() TCP falhou")
            }

            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif

            // connect não-bloqueante + poll com timeout 2s
            #if canImport(Darwin)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let connRes = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if connRes != 0 {
                let err = errno
                if err == EINPROGRESS {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let pollRes = Darwin.poll(&pfd, 1, 2000)
                    if pollRes <= 0 { Darwin.close(fd); throw ProtocolError(name: .internal_error, message: "engine connect(\(clean)) timeout") }
                    var soErr: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                    if soErr != 0 { Darwin.close(fd); throw ProtocolError(name: .internal_error, message: "connect(\(clean)) falhou: \(String(cString: strerror(soErr)))") }
                } else {
                    Darwin.close(fd); throw ProtocolError(name: .internal_error, message: "connect(\(clean)) falhou: \(String(cString: strerror(err)))")
                }
            }
            _ = fcntl(fd, F_SETFL, 0)
            #elseif canImport(Glibc)
            _ = Glibc.fcntl(fd, F_SETFL, O_NONBLOCK)
            let connRes = Glibc.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if connRes != 0 {
                let err = errno
                if err == EINPROGRESS {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let pollRes = Glibc.poll(&pfd, 1, 2000)
                    if pollRes <= 0 { Glibc.close(fd); throw ProtocolError(name: .internal_error, message: "engine connect(\(clean)) timeout") }
                    var soErr: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                    if soErr != 0 { Glibc.close(fd); throw ProtocolError(name: .internal_error, message: "connect(\(clean)) falhou: \(String(cString: strerror(soErr)))") }
                } else {
                    Glibc.close(fd); throw ProtocolError(name: .internal_error, message: "connect(\(clean)) falhou: \(String(cString: strerror(err)))")
                }
            }
            _ = Glibc.fcntl(fd, F_SETFL, 0)
            #endif

            return fd
        }

        // Unix socket (path)
        let path = raw
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw ProtocolError(name: .internal_error, message: "caminho do socket do engine muito longo")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in
                dst.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        #if canImport(Darwin)
        let sockType = SOCK_STREAM
        #else
        let sockType = Int32(SOCK_STREAM.rawValue)
        #endif

        let fd = socket(AF_UNIX, sockType, 0)
        guard fd >= 0 else {
            throw ProtocolError(name: .internal_error, message: "socket() para engine falhou")
        }

        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let rc = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                #if canImport(Darwin)
                return Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                #elseif canImport(Glibc)
                return Glibc.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }

        guard rc == 0 else {
            let code = errno
            close(fd)
            throw ProtocolError(name: .internal_error, message: "conexão ao engine local falhou: \(String(cString: strerror(code)))")
        }

        return fd
    }

    private func readEngineResponse(fd: Int32, expectedID: String, lineBuffer: inout SocketFraming.LineBuffer, chunk: inout [UInt8]) throws -> ResponseMessage {
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                for line in lineBuffer.append(Data(bytes: chunk, count: count)) {
                    guard let envelope = try? SocketFraming.decodeLine(Envelope.self, from: line) else { continue }
                    if case .response(let resp) = envelope, resp.id == expectedID {
                        return resp
                    }
                }
            } else if count == 0 {
                throw ProtocolError(name: .internal_error, message: "engine desconectou")
            } else if errno == EINTR {
                continue
            } else {
                throw ProtocolError(name: .internal_error, message: "erro de IO com engine")
            }
        }
    }

    // MARK: - Rooms

    private func scanRooms() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: paths.roomsDir, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries {
            guard let roomID = ULID(entry.lastPathComponent) else { continue }
            do {
                let store = try RoomStore.load(from: paths, roomID: roomID)
                guard store.getRoom().state == .active else { continue }
                roomStores[roomID] = store
            } catch {
                log.warn("room_unreadable", "sala ilegível em \(entry.lastPathComponent)")
            }
        }
    }

    private func persist(_ store: RoomStore) throws {
        try store.persist(to: paths)
    }

    // MARK: - Tick

    private func startTick() {
        let tick = DispatchSource.makeTimerSource(queue: stateQueue)
        tick.schedule(deadline: .now() + 1, repeating: 1)
        tick.setEventHandler { [weak self] in self?.tick() }
        tick.resume()
        tickTimer = tick
    }

    private func tick() {
        guard !shuttingDown else { return }
        let now = Date()
        for store in roomStores.values {
            let expired = store.expireLeases(now: now)
            for leaseID in expired {
                broadcast(.leaseRevoked, ws: nil, LeaseRevokedTopicPayload(leaseID: leaseID))
            }
            for memberID in store.expirePresence(now: now) {
                broadcastToRoom(.presenceChanged, roomID: store.roomID, PresenceChangedTopicPayload(
                    roomID: store.roomID, memberID: memberID, connected: false,
                    displayName: store.getMember(id: memberID)?.displayName, lastSeen: now))
            }
        }
    }

    // MARK: - IO

    private func acceptLoop() {
        while !shuttingDown {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            stateQueue.async { [weak self] in self?.addClient(fd: fd) }
        }
    }

    private func addClient(fd: Int32) {
        guard !shuttingDown else { close(fd); return }
        let client = HubClient(fd: fd, hub: self)
        clients[ObjectIdentifier(client)] = client
        client.startReading()
    }

    public func dropClient(_ client: HubClient, motivo: String) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        for roomID in client.joinedRoomIDs {
            let authorStillConnected = clients.values.contains {
                $0.helloDone && $0.author == client.author && $0.joinedRoomIDs.contains(roomID)
            }
            guard !authorStillConnected, let store = roomStores[roomID] else { continue }
            let presence = store.updatePresence(
                memberID: client.author.rawValue, connected: false,
                viewport: nil, cursor: nil, selectedNodeID: nil, viewingSessionID: nil)
            broadcastToRoom(.presenceChanged, roomID: roomID, PresenceChangedTopicPayload(
                roomID: roomID, memberID: presence.memberID, connected: false,
                displayName: store.getMember(id: presence.memberID)?.displayName,
                lastSeen: presence.lastSeen))
        }
        client.close()
        log.info("hub_disconnect", motivo)
    }

    // MARK: - Dispatch

    public func receive(line: Data, from client: HubClient) {
        guard client.rateLimiter.allow(bytes: line.count) else {
            log.warn("rate_limited", "cliente (client.clientName) excedeu o limite do Hub")
            if let envelope = try? SocketFraming.decodeLine(Envelope.self, from: line),
               case .request(let request) = envelope {
                client.respond(id: request.id, error: ProtocolError(
                    name: .invalid_params,
                    message: "limite de requisições ou tamanho excedido"))
            }
            return
        }
        guard let envelope = try? SocketFraming.decodeLine(Envelope.self, from: line) else {
            log.warn("malformed", "linha inválida")
            return
        }
        switch envelope {
        case .request(let request):
            if !client.helloDone, request.knownMethod != .hello {
                client.respond(id: request.id, error: ProtocolError(
                    name: .invalid_params,
                    message: "handshake `hello` obrigatório antes de \(request.method)"))
                return
            }
            do {
                try dispatch(request, from: client)
            } catch let error as ProtocolError {
                client.respond(id: request.id, error: error)
            } catch {
                client.respond(id: request.id, error: ProtocolError(name: .internal_error, message: "\(error)"))
            }
        case .event(let event):
            if event.topic == "sync.session.start.result",
               let result = try? event.decodeParams(SyncSessionStartResult.self) {
                syncRequestLock.lock()
                let callback = pendingSessionStarts.removeValue(forKey: result.requestID)
                syncRequestLock.unlock()
                callback?(result)
                return
            }
            if let topic = event.knownTopic {
                if case .object(let dict) = event.params {
                    if topic == .noteAppended {
                        if case .string(let nodeIDStr) = dict["node_id"],
                           let nodeID = ULID(nodeIDStr),
                           case .string(let conteudo) = dict["conteudo"] {
                            if let store = storeForNode(nodeID: nodeID) {
                                store.setNoteContent(nodeID: nodeID, content: conteudo)
                                store.save()
                            }
                        }
                    } else if topic == .sessionState {
                        if case .string(let sidStr) = dict["session_id"],
                           let sessionID = ULID(sidStr),
                           case .string(let estado) = dict["estado"] {
                            let wsID: ULID?
                            if case .string(let wsidStr) = dict["workspace_id"] { wsID = ULID(wsidStr)
                            } else if case .string(let nidStr) = dict["node_id"] ?? dict["no_id"],
                                      let nid = ULID(nidStr) { wsID = storeForNode(nodeID: nid)?.workspace.id
                            } else { wsID = sessionToWorkspace[sessionID] }
                            if let wsID, let store = workspaceStores[wsID] {
                                store.setSessionState(sessionID: sessionID, estado: estado, nodeID: nidFromDict(dict))
                                store.save()
                                sessionToWorkspace[sessionID] = wsID
                            }
                        }
                    } else if topic == .sessionOutput {
                        if case .string(let sidStr) = dict["session_id"],
                           let sessionID = ULID(sidStr),
                           case .string(let dataB64) = dict["data_b64"],
                           let data = Data(base64Encoded: dataB64) {
                            let text = String(decoding: data, as: UTF8.self)
                            let eventSeq: UInt64
                            if case .number(let rawSeq) = dict["seq"] { eventSeq = UInt64(rawSeq) }
                            else { eventSeq = 0 }
                            let wsID: ULID?
                            if case .string(let wsidStr) = dict["workspace_id"] { wsID = ULID(wsidStr)
                            } else { wsID = sessionToWorkspace[sessionID] }
                            if let wsID, let store = workspaceStores[wsID] {
                                store.appendSessionOutput(sessionID: sessionID, text: text, seq: eventSeq, dataB64: dataB64)
                                store.save()
                            }
                        }
                    } else if topic == .documentOp {
                        if case .string(let wsidStr) = dict["workspace_id"],
                           let wsid = ULID(wsidStr),
                           let store = workspaceStores[wsid],
                           let opValue = dict["op"] {
                            do {
                                let op = try opValue.decode(as: DocOp.self)
                                store.applyDocOp(op)
                                store.save()
                            } catch {
                                print("[Hub] document.op decode error: \(error)")
                            }
                        }
                    }
                }
                broadcast(topic, ws: nil, event.params)
            }
        case .response:
            break
        }
    }

    private func dispatch(_ request: RequestMessage, from client: HubClient) throws {
        if client.inviteRoomID != nil,
           request.knownMethod != .hello,
           request.knownMethod != .roomJoin {
            throw ProtocolError(name: .insufficient_permissions,
                message: "convite permite apenas entrar na sala indicada")
        }
        switch request.knownMethod {
        case .hello:
            let params = try request.decodeParams(HelloParams.self)
            var resolvedAuthor = params.author
            guard params.protocolVersion == ColmeiaVersion.protocolVersion else {
                throw ProtocolError(name: .protocol_version_mismatch,
                    message: "hub fala v\(ColmeiaVersion.protocolVersion)")
            }
            if let required = hubToken {
                if params.token == required {
                    // token do Hub — acesso completo
                } else if let token = params.token,
                          let invite = validateInvite(token: token) {
                    client.inviteRoomID = invite.roomID
                    client.inviteToken = token
                    if let memberID = invite.memberID, let author = Author(rawValue: memberID) {
                        resolvedAuthor = author
                    }
                } else {
                    throw ProtocolError(name: .invalid_params,
                        message: "token de autenticação inválido ou ausente")
                }
            } else if let token = params.token {
                if let invite = validateInvite(token: token) {
                    client.inviteRoomID = invite.roomID
                    client.inviteToken = token
                    if let memberID = invite.memberID, let author = Author(rawValue: memberID) {
                        resolvedAuthor = author
                    }
                }
            }
            client.author = resolvedAuthor
            client.clientName = params.client
            client.helloDone = true
            for topic in ColmeiaTopic.allCases {
                client.subscriptions[topic] = Set<ULID>()
            }
            respond(client, id: request.id, HelloResult(
                protocolVersion: ColmeiaVersion.protocolVersion,
                engineVersion: version,
                engineStartedEm: Date(),
                author: resolvedAuthor))
        case .roomCreate:
            let params = try request.decodeParams(RoomCreateParams.self)
            let now = Date()
            let room = Room(id: ULID.generate(), name: params.name,
                            policy: params.policy ?? RoomPolicy(),
                            workspaceID: params.workspaceID,
                            createdAt: now, updatedAt: now)
            let store = RoomStore(room: room)
            try store.addMember(id: client.author.rawValue,
                                displayName: client.clientName, roles: [.owner])
            roomStores[room.id] = store
            try persist(store)
            // Sincroniza sala com o Engine (best-effort) para que mission.* funcione
            if let conn = engineConn {
                var syncParams = params
                syncParams.id = room.id
                conn.call(method: "room.create", params: try? JSONValue(encoding: syncParams)) { _ in }
            }
            // A sala apenas referencia workspace_id — os dados do workspace
            // são gerenciados pelo sync tool via workspace.pushSnapshot ou
            // pela RPC workspace.create. room.create NUNCA cria workspace.
            respond(client, id: request.id, RoomResult(room: room))
        case .roomJoin:
            let params = try request.decodeParams(RoomJoinParams.self)
            if let invitedRoomID = client.inviteRoomID, invitedRoomID != params.roomID {
                throw ProtocolError(name: .insufficient_permissions,
                    message: "convite pertence a outra sala")
            }
            let store = try requireRoom(params.roomID)
            let memberID = client.author.rawValue
            let member: Member
            if let existing = store.getMember(id: memberID) {
                member = existing
            } else {
                var roles: Set<MemberRole> = [.editor]
                // Se veio de convite, resgata atomicamente (consumo único)
                if let invitedRoomID = client.inviteRoomID, invitedRoomID == params.roomID {
                    let invite = try store.redeemInvite(token: params.inviteToken ?? "", memberID: memberID)
                    roles = invite.roles
                } else if let inviteToken = params.inviteToken, !inviteToken.isEmpty {
                    let invite = try store.redeemInvite(token: inviteToken, memberID: memberID)
                    roles = invite.roles
                } else if store.getMembers(status: .active).isEmpty {
                    roles = [.owner]
                }
                let displayName = client.clientName.isEmpty ? memberID : client.clientName
                member = try store.addMember(id: memberID, displayName: displayName, roles: roles)
                try persist(store)
                broadcast(.memberJoined, ws: nil, MemberJoinedTopicPayload(
                    member: member, roomID: params.roomID, roomSeq: store.currentSeq()))
                broadcast(.roomUpdated, ws: nil, RoomUpdatedTopicPayload(room: store.getRoom()))
            }
            let snap = store.snapshot()
            client.joinedRoomIDs.insert(params.roomID)
            client.inviteRoomID = nil
            client.inviteToken = nil
            respond(client, id: request.id, RoomJoinResult(
                room: snap.room, members: snap.members,
                agentSessions: snap.agentSessions))
        case .roomSnapshot:
            let params = try request.decodeParams(RoomSnapshotParams.self)
            let store = try requireRoom(params.roomID)
            var snap = store.snapshot()
            if let since = params.sinceRoomSeq {
                snap.events = snap.events.filter { $0.logicalClock > since }
            }
            respond(client, id: request.id, snap)
        case .roomDelta:
            let params = try request.decodeParams(RoomDeltaParams.self)
            let store = try requireRoom(params.roomID)
            respond(client, id: request.id, store.buildDelta(sinceRoomSeq: params.sinceRoomSeq))
        case .roomList:
            let rooms = roomStores.values.map { $0.getRoom() }
                .sorted { $0.updatedAt > $1.updatedAt }
            respond(client, id: request.id, rooms)
        case .sessionEventAppend:
            let params = try request.decodeParams(SessionEventAppendParams.self)
            let store = try requireRoom(params.roomID)
            let (event, roomSeq, _) = try store.appendEvent(
                sessionID: params.sessionID, kind: params.kind,
                payload: params.payload, author: client.author,
                eventID: params.eventID)
            try persist(store)
            broadcast(.sessionEventAppended, ws: nil,
                SessionEventAppendedTopicPayload(event: event))
            broadcast(.eventAck, ws: nil,
                EventAckTopicPayload(eventID: event.id, roomSeq: roomSeq))
            respond(client, id: request.id,
                SessionEventAppendResult(event: event, roomSeq: roomSeq))
        case .agentSessionCreate:
            let params = try request.decodeParams(AgentSessionCreateParams.self)
            let store = try requireRoom(params.roomID)
            let session = store.createAgentSession(params)
            try persist(store)
            broadcast(.roomUpdated, ws: nil, RoomUpdatedTopicPayload(room: store.getRoom()))
            respond(client, id: request.id, AgentSessionResult(agentSession: session))
        case .agentSessionList:
            let params = try request.decodeParams(AgentSessionListParams.self)
            let store = try requireRoom(params.roomID)
            respond(client, id: request.id, store.getAgentSessions(state: params.state))
        case .agentSessionGet:
            let params = try request.decodeParams(AgentSessionGetParams.self)
            for store in roomStores.values {
                if let session = store.getAgentSession(id: params.agentSessionID) {
                    respond(client, id: request.id, AgentSessionResult(agentSession: session))
                    return
                }
            }
            throw ProtocolError(name: .agent_session_not_found,
                message: "sessão \(params.agentSessionID) não encontrada")
        case .presenceUpdate:
            let params = try request.decodeParams(PresenceUpdateParams.self)
            let store = try requireRoom(params.roomID)
            guard let member = store.getMember(id: client.author.rawValue), member.status == .active else {
                throw ProtocolError(name: .insufficient_permissions, message: "membro não está ativo nesta sala")
            }
            if let cursor = params.cursor {
                guard cursor.x.isFinite, cursor.y.isFinite,
                      abs(cursor.x) <= 1_000_000, abs(cursor.y) <= 1_000_000 else {
                    throw ProtocolError(name: .invalid_params, message: "cursor fora do canvas")
                }
            }
            let presence = store.updatePresence(
                memberID: client.author.rawValue,
                viewport: params.viewport,
                cursor: params.cursor,
                selectedNodeID: params.selectedNodeID,
                viewingSessionID: params.viewingSessionID)
            broadcastToRoom(.presenceChanged, roomID: params.roomID,
                PresenceChangedTopicPayload(
                    roomID: presence.roomID, memberID: presence.memberID,
                    viewport: presence.viewport, cursor: presence.cursor,
                    displayName: member.displayName,
                    selectedNodeID: presence.selectedNodeID,
                    viewingSessionID: presence.viewingSessionID,
                    lastSeen: presence.lastSeen))
            respond(client, id: request.id, EmptyResult())
        case .roomLeave:
            let params = try request.decodeParams(RoomLeaveParams.self)
            let store = try requireRoom(params.roomID)
            _ = try store.removeMember(id: client.author.rawValue)
            try persist(store)
            broadcast(.memberLeft, ws: nil, MemberLeftTopicPayload(roomID: params.roomID, memberID: client.author.rawValue))
            respond(client, id: request.id, EmptyResult())
        case .roomUpdate:
            let params = try request.decodeParams(RoomUpdateParams.self)
            let store = try requireRoom(params.roomID)
            let room = store.updateRoom(name: params.name, policy: params.policy)
            try persist(store)
            broadcast(.roomUpdated, ws: nil, RoomUpdatedTopicPayload(room: room))
            respond(client, id: request.id, RoomResult(room: room))
        case .roomDelete:
            let params = try request.decodeParams(RoomDeleteParams.self)
            guard params.confirmar else {
                throw ProtocolError(name: .confirmation_required, message: "room.delete exige confirmar: true")
            }
            let store = try requireRoom(params.roomID)
            _ = store.archiveRoom()
            try persist(store)
            roomStores.removeValue(forKey: params.roomID)
            respond(client, id: request.id, EmptyResult())
        case .memberInvite:
            let params = try request.decodeParams(MemberInviteParams.self)
            let store = try requireRoom(params.roomID)
            let invite = store.createInvite(
                displayName: params.displayName,
                roles: params.roles,
                ttlSeconds: params.ttlSeconds)
            try persist(store)
            let pendingMember = Member(
                id: "invite-\(invite.token.prefix(8))",
                displayName: params.displayName,
                roles: params.roles,
                status: .invited,
                joinedAt: Date())
            respond(client, id: request.id, MemberInviteResult(member: pendingMember, inviteToken: invite.token))
        case .memberInviteList:
            let params = try request.decodeParams(MemberInviteListParams.self)
            let store = try requireRoom(params.roomID)
            let invites = store.listInvites()
            respond(client, id: request.id, invites)
        case .memberInviteRevoke:
            let params = try request.decodeParams(MemberInviteRevokeParams.self)
            let store = try requireRoom(params.roomID)
            try store.revokeInvite(token: params.token)
            try persist(store)
            respond(client, id: request.id, EmptyResult())
        case .memberList:
            let params = try request.decodeParams(MemberListParams.self)
            let store = try requireRoom(params.roomID)
            respond(client, id: request.id, store.getMembers(status: params.status))
        case .memberUpdate:
            let params = try request.decodeParams(MemberUpdateParams.self)
            let store = try requireRoom(params.roomID)
            let caller = store.getMembers(status: .active).first { $0.id == client.author.rawValue }
            let isOwner = caller?.roles.contains(.owner) == true
            guard caller != nil,
                  (params.memberID == client.author.rawValue || isOwner),
                  (params.roles == nil || isOwner) else {
                throw ProtocolError(name: .insufficient_permissions, message: "sem permissão para alterar este membro")
            }
            let member = try store.updateMember(
                id: params.memberID, displayName: params.displayName, roles: params.roles)
            try persist(store)
            broadcast(.memberUpdated, ws: nil, MemberUpdatedTopicPayload(member: member))
            respond(client, id: request.id, MemberResult(member: member))
        case .memberRemove:
            let params = try request.decodeParams(MemberRemoveParams.self)
            let store = try requireRoom(params.roomID)
            let member = try store.removeMember(id: params.memberID)
            try persist(store)
            respond(client, id: request.id, MemberResult(member: member))
        case .agentSessionUpdate:
            let params = try request.decodeParams(AgentSessionUpdateParams.self)
            for store in roomStores.values {
                if store.getAgentSession(id: params.agentSessionID) != nil {
                    let session = try store.updateAgentSession(
                        id: params.agentSessionID, objective: params.objective,
                        state: params.state, conductorID: params.conductorID,
                        summary: params.summary)
                    try persist(store)
                    respond(client, id: request.id, AgentSessionResult(agentSession: session))
                    return
                }
            }
            throw ProtocolError(name: .agent_session_not_found,
                message: "sessão de agente \(params.agentSessionID) não encontrada")
        case .agentSessionHandoffRequest:
            let params = try request.decodeParams(AgentSessionHandoffRequestParams.self)
            for store in roomStores.values {
                if store.getAgentSession(id: params.agentSessionID) != nil {
                    let session = try store.requestHandoff(
                        sessionID: params.agentSessionID,
                        fromMemberID: client.author.rawValue,
                        toMemberID: params.toMemberID, scope: params.scope)
                    try persist(store)
                    broadcast(.handoffRequested, ws: nil,
                        HandoffRequestedTopicPayload(sessionID: params.agentSessionID, handoff: session.handoff!))
                    respond(client, id: request.id, AgentSessionResult(agentSession: session))
                    return
                }
            }
            throw ProtocolError(name: .agent_session_not_found,
                message: "sessão de agente \(params.agentSessionID) não encontrada")
        case .agentSessionHandoffAccept:
            let params = try request.decodeParams(AgentSessionHandoffAcceptParams.self)
            for store in roomStores.values {
                if store.getAgentSession(id: params.agentSessionID) != nil {
                    let session = try store.acceptHandoff(
                        sessionID: params.agentSessionID, by: client.author.rawValue)
                    try persist(store)
                    broadcast(.handoffAccepted, ws: nil,
                        HandoffAcceptedTopicPayload(sessionID: params.agentSessionID,
                            fromMemberID: session.handoff?.fromMemberID ?? "",
                            toMemberID: client.author.rawValue, scope: session.handoff?.scope ?? .conductor))
                    if session.conductorID == client.author.rawValue {
                        broadcast(.conductorChanged, ws: nil,
                            ConductorChangedTopicPayload(sessionID: params.agentSessionID,
                                previousConductorID: nil, newConductorID: client.author.rawValue))
                    }
                    respond(client, id: request.id, AgentSessionResult(agentSession: session))
                    return
                }
            }
            throw ProtocolError(name: .agent_session_not_found,
                message: "sessão de agente \(params.agentSessionID) não encontrada")
        case .agentSessionHandoffReject:
            let params = try request.decodeParams(AgentSessionHandoffAcceptParams.self)
            for store in roomStores.values {
                if store.getAgentSession(id: params.agentSessionID) != nil {
                    let session = try store.rejectHandoff(
                        sessionID: params.agentSessionID, by: client.author.rawValue)
                    try persist(store)
                    respond(client, id: request.id, AgentSessionResult(agentSession: session))
                    return
                }
            }
            throw ProtocolError(name: .agent_session_not_found,
                message: "sessão de agente \(params.agentSessionID) não encontrada")
        case .agentSessionTransition:
            let params = try request.decodeParams(AgentSessionTransitionParams.self)
            for store in roomStores.values {
                if store.getAgentSession(id: params.agentSessionID) != nil {
                    let session = try store.transitionSession(id: params.agentSessionID, to: params.state)
                    try persist(store)
                    respond(client, id: request.id, AgentSessionResult(agentSession: session))
                    return
                }
            }
            throw ProtocolError(name: .agent_session_not_found,
                message: "sessão de agente \(params.agentSessionID) não encontrada")
        case .agentSessionBriefing:
            let params = try request.decodeParams(AgentSessionBriefingParams.self)
            for store in roomStores.values {
                if let briefing = store.buildBriefing(for: params.agentSessionID, newMemberName: client.author.rawValue) {
                    respond(client, id: request.id, AgentSessionBriefingResult(briefing: briefing))
                    return
                }
            }
            throw ProtocolError(name: .agent_session_not_found,
                message: "sessão de agente \(params.agentSessionID) não encontrada")
        case .grantIssue:
            let params = try request.decodeParams(GrantIssueParams.self)
            let store = try requireRoom(params.roomID)
            let grant = store.issueGrant(
                subjectID: params.subjectID, resource: params.resource,
                actions: params.actions, issuedBy: client.author,
                expiresAt: params.expiresAt, contextHash: params.contextHash)
            try persist(store)
            respond(client, id: request.id, GrantResult(grant: grant))
        case .grantRevoke:
            let params = try request.decodeParams(GrantRevokeParams.self)
            for store in roomStores.values {
                if let grant = try? store.revokeGrant(id: params.grantID) {
                    try persist(store)
                    respond(client, id: request.id, GrantResult(grant: grant))
                    return
                }
            }
            throw ProtocolError(name: .grant_not_found,
                message: "grant \(params.grantID) não encontrado")
        case .grantList:
            let params = try request.decodeParams(GrantListParams.self)
            let store = try requireRoom(params.roomID)
            respond(client, id: request.id,
                store.getGrants(subjectID: params.subjectID, activeOnly: params.activeOnly ?? false))
        case .leaseAcquire:
            let params = try request.decodeParams(LeaseAcquireParams.self)
            let store = try requireRoom(params.roomID)
            guard store.getAgentSession(id: params.sessionID) != nil else {
                throw ProtocolError(name: .agent_session_not_found,
                    message: "sessão \(params.sessionID) não encontrada")
            }
            let lease = store.acquireLease(sessionID: params.sessionID, scope: params.scope, memberID: client.author.rawValue)
            broadcast(.leaseAcquired, ws: nil, LeaseAcquiredTopicPayload(lease: lease))
            respond(client, id: request.id, lease)
        case .leaseRelease:
            let params = try request.decodeParams(LeaseReleaseParams.self)
            _ = roomStores.values.first.map { $0.releaseLease(leaseID: params.leaseID) }
            broadcast(.leaseRevoked, ws: nil, LeaseRevokedTopicPayload(leaseID: params.leaseID))
            respond(client, id: request.id, EmptyResult())
        case .subscribe:
            for topic in ColmeiaTopic.allCases {
                client.subscriptions[topic] = Set<ULID>()
            }
            respond(client, id: request.id, EmptyResult())
        case .unsubscribe:
            for topic in ColmeiaTopic.allCases {
                client.subscriptions[topic] = Set<ULID>()
            }
            respond(client, id: request.id, EmptyResult())
        case .workspaceList:
            let summaries = workspaceStores.values.map { store in
                WorkspaceSummary(id: store.workspace.id, nome: store.workspace.nome,
                                 atualizadoEm: store.workspace.atualizadoEm)
            }
            respond(client, id: request.id, summaries)
        case .workspaceCreate:
            let params = try request.decodeParams(WorkspaceCreateParams.self)
            let now = Date()
            let ws = Workspace(
                id: params.id ?? ULID.generate(), nome: params.nome,
                caminhoRaiz: params.caminhoRaiz, criadoEm: now, atualizadoEm: now)
            let store = WorkspaceStore(workspace: ws, storageDir: paths.workspacesDir)
            store.save()
            workspaceStores[ws.id] = store
            respond(client, id: request.id, WorkspaceResult(workspace: ws))
        case .workspacePushSnapshot:
            let params = try request.decodeParams(PushSnapshotParams.self)
            let now = Date()
            let ws: Workspace
            if let existing = workspaceStores[params.workspaceID] {
                ws = existing.workspace
            } else {
                ws = Workspace(id: params.workspaceID, nome: params.nome,
                               criadoEm: now, atualizadoEm: now)
            }
            let store = WorkspaceStore(workspace: ws, storageDir: paths.workspacesDir)
            store.seq = params.seq
            store.nodes = params.nodes
            store.connections = params.connections
            if let existing = workspaceStores[params.workspaceID] {
                store.noteContents = existing.noteContents
                store.noteRevisions = existing.noteRevisions
                store.watchdogConfiguration = existing.watchdogConfiguration
                store.watchdogHistory = existing.watchdogHistory
            }
            if let configuration = params.watchdogConfiguration {
                store.watchdogConfiguration = configuration
            }
            if let history = params.watchdogHistory { store.watchdogHistory = history }
            if let nc = params.noteContents {
                for (key, value) in nc {
                    guard let nodeID = ULID(key), store.noteRevisions[nodeID] == nil else { continue }
                    store.noteContents[nodeID] = value
                }
            }
            if let ss = params.sessionStates {
                for entry in ss {
                    guard let sidStr = entry["session_id"], let sessionID = ULID(sidStr),
                          let estado = entry["estado"] else { continue }
                    let nodeID = entry["node_id"].flatMap { ULID($0) }
                    let updatedAt = entry["updated_at"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
                    let info = SessionStateInfo(
                        sessionID: sessionID, estado: estado,
                        nodeID: nodeID, updatedAt: updatedAt)
                    store.sessionStates[sessionID] = info
                    sessionToWorkspace[sessionID] = params.workspaceID
                }
            }
            if let so = params.sessionOutputs {
                for (sidStr, entries) in so {
                    guard let sessionID = ULID(sidStr) else { continue }
                    var buf: [SessionOutputEntry] = []
                    for (idx, e) in entries.enumerated() {
                        let text = e["text"] ?? ""
                        let seq = (e["seq"]).flatMap { UInt64($0) } ?? UInt64(idx + 1)
                        buf.append(SessionOutputEntry(
                            seq: seq, text: text, receivedAt: Date(),
                            dataB64: e["data_b64"], kind: e["kind"],
                            cols: e["cols"].flatMap(Int.init), rows: e["rows"].flatMap(Int.init)))
                    }
                    store.sessionOutputs[sessionID] = buf
                }
            }
            store.save()
            workspaceStores[params.workspaceID] = store
            respond(client, id: request.id, PushSnapshotResult(
                workspaceID: params.workspaceID, seq: store.seq))
        case .workspaceCatchUp:
            let params = try request.decodeParams(CatchUpParams.self)
            guard let store = workspaceStores[params.workspaceID] else {
                throw ProtocolError(name: .room_not_found,
                    message: "workspace \(params.workspaceID) não encontrado")
            }
            let fromSeq = params.fromSeq
            // Busca ops no ring buffer
            let missing = store.recentOps.filter { $0.seq > fromSeq }
            if missing.count > 0, missing.last?.seq == store.seq {
                // Conseguiu reconstruir toda a sequência — envia só as ops
                let ops = missing.compactMap { item -> JSONValue? in
                    guard let opJSON = try? JSONDecoder().decode(JSONValue.self, from: item.opData)
                    else { return nil }
                    return .object([
                        "workspace_id": .string(params.workspaceID.string),
                        "op": opJSON,
                        "seq": .number(Double(item.seq))
                    ])
                }
                respond(client, id: request.id, CatchUpResult(ops: ops))
            } else {
                // Gap ou buffer insuficiente — envia snapshot completo
                let snap = store.snapshot()
                respond(client, id: request.id, CatchUpResult(snapshot: snap))
            }
        case .workspaceOpen:
            let params = try request.decodeParams(WorkspaceOpenParams.self)
            guard let store = workspaceStores[params.id] else {
                throw ProtocolError(name: .room_not_found,
                    message: "workspace \(params.id) não encontrado")
            }
            respond(client, id: request.id, WorkspaceOpenResult(
                workspace: store.workspace, documentSnapshot: store.snapshot()))
        case .docApply:
            let params = try request.decodeParams(DocApplyParams.self)
            guard let store = workspaceStores[params.workspaceID] else {
                throw ProtocolError(name: .room_not_found,
                    message: "workspace \(params.workspaceID) não encontrado")
            }
            for proposal in params.ops {
                var applied = proposal
                applied.seq = store.seq + 1
                store.applyDocOp(applied)
                broadcast(.documentOp, ws: params.workspaceID, DocumentOpTopicPayload(
                    workspaceID: params.workspaceID,
                    op: applied,
                    seq: applied.seq ?? store.seq
                ))
            }
            store.save()
            respond(client, id: request.id, DocApplyResult(seqFinal: store.seq))
        case .noteGet:
            let params = try request.decodeParams(NoteGetParams.self)
            if let store = workspaceStores[params.workspaceID],
               let conteudo = store.noteContents[params.nodeID] {
                let cor = store.nodes.first { $0.id == params.nodeID }.flatMap {
                    if case .nota(let n) = $0 { return n.cor }
                    return nil
                } ?? "#8b5cf6"
                respond(client, id: request.id, NoteRecord(
                    nodeID: params.nodeID, conteudo: conteudo, cor: cor,
                    ultimaFonte: nil, floorID: nil, checklist: []))
            } else {
                guard let conn = engineConn else {
                    throw ProtocolError(name: .internal_error, message: "Engine indisponível para \(request.method)")
                }
                var result: JSONValue?
                let semaphore = DispatchSemaphore(value: 0)
                conn.call(method: request.method, params: request.params) { res in
                    if case .success(let v) = res { result = v }
                    semaphore.signal()
                }
                semaphore.wait()
                guard let result else {
                    throw ProtocolError(name: .internal_error, message: "Engine \(request.method) falhou")
                }
                respond(client, id: request.id, result)
            }
        case .noteReplace:
            let params = try request.decodeParams(NoteReplaceParams.self)
            guard params.conteudo.utf8.count <= 1_048_576, !params.conteudo.contains("\0") else {
                throw ProtocolError(name: .invalid_params, message: "conteúdo da nota inválido ou maior que 1 MiB")
            }
            guard let store = workspaceStores[params.workspaceID],
                  store.nodes.contains(where: { $0.id == params.nodeID }) else {
                throw ProtocolError(name: .room_not_found, message: "nota \(params.nodeID) não encontrada")
            }
            store.setNoteContent(nodeID: params.nodeID, content: params.conteudo)
            store.save()
            let cor = store.nodes.first { $0.id == params.nodeID }.flatMap {
                if case .nota(let n) = $0 { return n.cor }
                return nil
            } ?? "amarelo"
            broadcast(.noteAppended, ws: params.workspaceID, NoteAppendedTopicPayload(
                nodeID: params.nodeID,
                fonte: client.author,
                resumo: "nota substituída pela web",
                conteudo: params.conteudo
            ))
            respond(client, id: request.id, NoteRecord(
                nodeID: params.nodeID, conteudo: params.conteudo, cor: cor,
                ultimaFonte: client.author, floorID: nil, checklist: []))
        case .missionList:
            let params = try request.decodeParams(MissionListParams.self)
            let store = try requireMissionStore(params.roomID)
            respond(client, id: request.id, store.listMissions(state: params.state))
        case .missionCreate:
            let params = try request.decodeParams(MissionCreateParams.self)
            let store = try requireMissionStore(params.roomID)
            let mission = try store.createMission(
                title: params.title,
                context: params.context,
                definitionOfDone: params.definitionOfDone,
                ownerID: params.ownerID ?? client.author.rawValue
            )
            try store.persist(to: paths)
            respond(client, id: request.id, MissionResult(mission: mission))
        case .missionTransition:
            let params = try request.decodeParams(MissionTransitionParams.self)
            if params.state == .archived {
                let room = try requireRoom(params.roomID)
                guard room.getMembers(status: .active).contains(where: {
                    $0.id == client.author.rawValue && $0.roles.contains(.owner)
                }) else {
                    throw ProtocolError(name: .insufficient_permissions, message: "somente owner pode arquivar missão")
                }
            }
            let store = try requireMissionStore(params.roomID)
            let mission = try store.transitionMission(
                id: params.missionID,
                to: params.state,
                reason: params.reason
            )
            try store.persist(to: paths)
            respond(client, id: request.id, MissionResult(mission: mission))
        case .workstreamList:
            let params = try request.decodeParams(WorkstreamListParams.self)
            let store = try requireMissionStore(params.roomID)
            respond(client, id: request.id, store.listWorkstreams(
                missionID: params.missionID,
                state: params.state
            ))
        case .workstreamCreate:
            let params = try request.decodeParams(WorkstreamCreateParams.self)
            let store = try requireMissionStore(params.roomID)
            let workstream = try store.createWorkstream(
                missionID: params.missionID,
                title: params.title,
                objective: params.objective,
                definitionOfDone: params.definitionOfDone,
                assignee: params.assignee,
                dependsOn: params.dependsOn ?? []
            )
            try store.persist(to: paths)
            respond(client, id: request.id, WorkstreamResult(workstream: workstream))
        case .sessionStart:
            let params = try request.decodeParams(SessionStartParams.self)
            guard canEditWorkspace(client, workspaceID: params.workspaceID) else {
                throw ProtocolError(name: .insufficient_permissions, message: "sem permissão para relançar este terminal")
            }
            let relayID = ULID.generate().string
            let semaphore = DispatchSemaphore(value: 0)
            var relayResult: SyncSessionStartResult?
            syncRequestLock.lock()
            pendingSessionStarts[relayID] = { result in
                relayResult = result
                semaphore.signal()
            }
            syncRequestLock.unlock()
            guard relayToSync(topic: "sync.session.start", payload: SyncSessionStartRequest(
                requestID: relayID, start: params
            )) else {
                syncRequestLock.lock()
                pendingSessionStarts.removeValue(forKey: relayID)
                syncRequestLock.unlock()
                throw ProtocolError(name: .internal_error, message: "Mac offline; não foi possível relançar")
            }
            guard semaphore.wait(timeout: .now() + 12) == .success, let relayResult else {
                syncRequestLock.lock()
                pendingSessionStarts.removeValue(forKey: relayID)
                syncRequestLock.unlock()
                throw ProtocolError(name: .internal_error, message: "o Engine não respondeu ao relançamento")
            }
            if let error = relayResult.error { throw error }
            guard let session = relayResult.session else {
                throw ProtocolError(name: .internal_error, message: "resposta de relançamento sem sessão")
            }
            respond(client, id: request.id, SessionResult(session: session))
        case .sessionInput:
            let params = try request.decodeParams(SessionInputParams.self)
            guard canEditRoom(client) else {
                throw ProtocolError(name: .insufficient_permissions, message: "somente owner/editor pode interagir com terminal")
            }
            guard sessionToWorkspace[params.sessionID] != nil else {
                throw ProtocolError(name: .session_not_found, message: "sessão \(params.sessionID) não está sincronizada")
            }
            guard relayToSync(topic: "sync.session.input", payload: params) else {
                throw ProtocolError(name: .internal_error, message: "Mac offline; terminal disponível apenas para leitura")
            }
            respond(client, id: request.id, EmptyResult())
        case .sessionResize:
            let params = try request.decodeParams(SessionResizeParams.self)
            guard canEditRoom(client) else {
                throw ProtocolError(name: .insufficient_permissions, message: "somente owner/editor pode redimensionar terminal")
            }
            guard relayToSync(topic: "sync.session.resize", payload: params) else {
                throw ProtocolError(name: .internal_error, message: "Mac offline; terminal disponível apenas para leitura")
            }
            respond(client, id: request.id, EmptyResult())
        default:
            guard let conn = engineConn else {
                throw ProtocolError(name: .internal_error, message: "Engine indisponível para \(request.method)")
            }
            var result: JSONValue?
            let semaphore = DispatchSemaphore(value: 0)
            conn.call(method: request.method, params: request.params) { res in
                if case .success(let v) = res { result = v }
                semaphore.signal()
            }
            semaphore.wait()
            guard let result else {
                throw ProtocolError(name: .internal_error, message: "Engine \(request.method) falhou")
            }
            respond(client, id: request.id, result)
        }
    }

    // MARK: - Helpers

    private func requireMissionStore(_ roomID: ULID) throws -> MissionStore {
        _ = try requireRoom(roomID)
        if let store = missionStores[roomID] { return store }
        let store = (try? MissionStore.load(from: paths, roomID: roomID)) ?? MissionStore(roomID: roomID)
        missionStores[roomID] = store
        return store
    }

    private func canEditRoom(_ client: HubClient) -> Bool {
        roomStores.values.contains { store in
            store.getMembers(status: .active).contains { member in
                member.id == client.author.rawValue &&
                    (member.roles.contains(.owner) || member.roles.contains(.editor))
            }
        }
    }

    private func canEditWorkspace(_ client: HubClient, workspaceID: ULID) -> Bool {
        roomStores.values.contains { store in
            guard store.getRoom().workspaceID == workspaceID else { return false }
            return store.getMembers(status: .active).contains { member in
                member.id == client.author.rawValue &&
                    (member.roles.contains(.owner) || member.roles.contains(.editor))
            }
        }
    }

    private func relayToSync(topic: String, payload: some Encodable) -> Bool {
        guard let params = try? JSONValue(encoding: payload) else { return false }
        let targets = clients.values.filter { $0.helloDone && $0.clientName == "colmeia-sync" }
        let envelope = Envelope.event(EventMessage(topic: topic, params: params))
        targets.forEach { $0.send(envelope) }
        return !targets.isEmpty
    }

    /// Valida convite SEM consumir — o consumo é no room.join.
    private func validateInvite(token: String) -> (roomID: ULID, memberID: String?)? {
        for (roomID, store) in roomStores {
            guard let invite = store.getInvite(token: token) else {
                continue
            }
            if invite.isValid {
                return (roomID, nil)
            }
            if invite.used, let memberID = invite.usedByMemberID,
               store.getMember(id: memberID)?.status == .active {
                return (roomID, memberID)
            }
        }
        return nil
    }

    private func requireRoom(_ id: ULID) throws -> RoomStore {
        guard let store = roomStores[id] else {
            throw ProtocolError(name: .room_not_found, message: "sala \(id) não existe")
        }
        return store
    }

    private func respond(_ client: HubClient, id: String, _ value: some Encodable) {
        if let json = try? JSONValue(encoding: value) {
            client.respond(id: id, result: json)
        } else {
            client.respond(id: id, error: ProtocolError(name: .internal_error, message: "serialização falhou"))
        }
    }

    func broadcast(_ topic: ColmeiaTopic, ws: ULID?, _ payload: some Encodable) {
        guard let params = try? JSONValue(encoding: payload) else { return }
        let envelope = Envelope.event(EventMessage(topic: topic, params: params))
        for client in clients.values where client.helloDone {
            guard let entry = client.subscriptions[topic] else { continue }
            if !entry.isEmpty, let ws, !entry.contains(ws) { continue }
            client.send(envelope)
        }
    }

    func broadcastToRoom(_ topic: ColmeiaTopic, roomID: ULID, _ payload: some Encodable) {
        guard let params = try? JSONValue(encoding: payload) else { return }
        let envelope = Envelope.event(EventMessage(topic: topic, params: params))
        for client in clients.values where client.helloDone && client.joinedRoomIDs.contains(roomID) {
            guard client.subscriptions[topic] != nil else { continue }
            client.send(envelope)
        }
    }
}

// MARK: - Workspace Store

/// Armazenamento local de workspace no Hub (usado quando Engine não está disponível).
public final class WorkspaceStore: @unchecked Sendable {
    public var workspace: Workspace
    public var seq: UInt64 = 0
    public var nodes: [Node] = []
    public var connections: [Connection] = []
    public var noteContents: [ULID: String] = [:]
    public var sessionStates: [ULID: SessionStateInfo] = [:]
    public var sessionOutputs: [ULID: [SessionOutputEntry]] = [:]
    public var noteRevisions: [ULID: Int] = [:]
    public var watchdogConfiguration: WorkerWatchdogConfiguration?
    public var watchdogHistory: [WatchdogHistoryEntry] = []
    /// Ring buffer das últimas 200 ops, indexado por seq, para catch-up em reconexão.
    public var recentOps: [(seq: UInt64, opData: Data)] = []

    private let storageURL: URL

    public init(workspace: Workspace, storageDir: URL) {
        self.workspace = workspace
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        self.storageURL = storageDir.appendingPathComponent("\(workspace.id.string).json")
    }

    public func applyDocOp(_ op: DocOp) {
        // Empilha no ring buffer de catch-up
        if let opSeq = op.seq, let opData = try? ColmeiaJSON.encoder().encode(op) {
            recentOps.append((seq: opSeq, opData: opData))
            if recentOps.count > 200 { recentOps.removeFirst(recentOps.count - 200) }
        }
        switch op.payload {
        case .nodeAdd(let p):
            if nodes.contains(where: { $0.id == p.node.id }) { return }
            nodes.append(p.node)
        case .nodeDelete(let p):
            nodes.removeAll { $0.id == p.id }
            connections.removeAll { $0.de == p.id || $0.para == p.id }
        case .nodeMove(let p):
            guard let idx = nodes.firstIndex(where: { $0.id == p.id }) else { return }
            if case .terminal(var n) = nodes[idx] { n.posicao = p.posicao; nodes[idx] = .terminal(n) }
            else if case .nota(var n) = nodes[idx] { n.posicao = p.posicao; nodes[idx] = .nota(n) }
            else if case .desenho(var n) = nodes[idx] { n.posicao = p.posicao; nodes[idx] = .desenho(n) }
            else if case .portal(var n) = nodes[idx] { n.posicao = p.posicao; nodes[idx] = .portal(n) }
        case .nodeResize(let p):
            guard let idx = nodes.firstIndex(where: { $0.id == p.id }) else { return }
            if case .terminal(var n) = nodes[idx] { n.tamanho = p.tamanho; nodes[idx] = .terminal(n) }
            else if case .nota(var n) = nodes[idx] { n.tamanho = p.tamanho; nodes[idx] = .nota(n) }
            else if case .desenho(var n) = nodes[idx] { n.tamanho = p.tamanho; nodes[idx] = .desenho(n) }
            else if case .portal(var n) = nodes[idx] { n.tamanho = p.tamanho; nodes[idx] = .portal(n) }
        case .nodeUpdate(let p):
            guard let idx = nodes.firstIndex(where: { $0.id == p.id }) else { return }
            guard case .object(let camposObj) = p.campos else { return }
            let existingData = (try? ColmeiaJSON.encoder().encode(nodes[idx])) ?? Data()
            guard let existingJSON = try? JSONDecoder().decode(JSONValue.self, from: existingData),
                  case .object(var obj) = existingJSON else { return }
            for (k, v) in camposObj { obj[k] = v }
            guard let mergedData = try? ColmeiaJSON.encoder().encode(JSONValue.object(obj)),
                  let merged = try? ColmeiaJSON.decoder().decode(Node.self, from: mergedData) else { return }
            nodes[idx] = merged
        case .connectionAdd(let p):
            if connections.contains(where: { $0.id == p.connection.id }) { return }
            connections.append(p.connection)
        case .connectionDelete(let p):
            connections.removeAll { $0.id == p.id }
        case .tracoAdd(let p):
            guard let idx = nodes.firstIndex(where: { $0.id == p.nodeID }),
                  case .desenho(var dn) = nodes[idx] else { return }
            dn.tracos.append(p.traco)
            nodes[idx] = .desenho(dn)
        case .tracoDelete(let p):
            guard let idx = nodes.firstIndex(where: { $0.id == p.nodeID }),
                  case .desenho(var dn) = nodes[idx] else { return }
            dn.tracos.removeAll { $0.id == p.tracoID }
            nodes[idx] = .desenho(dn)
        case .viewportSet:
            break // viewport.set é throttled e não precisa persistir no Hub
        case .workspaceRename(let p):
            workspace.nome = p.nome
        }
        seq = op.seq ?? seq
    }

    public func snapshot() -> DocumentSnapshot {
        let nc: [String: String]? = noteContents.isEmpty ? nil :
            Dictionary(uniqueKeysWithValues: noteContents.map { ($0.key.string, $0.value) })
        let ss: [[String: String]]? = sessionStates.isEmpty ? nil :
            sessionStates.map { (sid, info) in
                ["session_id": sid.string, "estado": info.estado, "node_id": info.nodeID?.string ?? "",
                 "updated_at": ISO8601DateFormatter().string(from: info.updatedAt)]
            }
        let visibleNodeIDs = Set(nodes.map(\.id))
        let visibleSessions: Set<ULID> = Set(sessionStates.compactMap { entry in
            guard let nodeID = entry.value.nodeID, visibleNodeIDs.contains(nodeID) else { return nil }
            return entry.key
        })
        let so: [String: [[String: String]]]? = sessionOutputs.isEmpty ? nil :
            Dictionary(uniqueKeysWithValues: sessionOutputs.compactMap { (sid, entries) in
                guard visibleSessions.contains(sid) else { return nil }
                return (sid.string, entries.suffix(500).map { entry in
                    var value = ["text": entry.text, "seq": String(entry.seq)]
                    if let dataB64 = entry.dataB64 { value["data_b64"] = dataB64 }
                    if let kind = entry.kind { value["kind"] = kind }
                    if let cols = entry.cols { value["cols"] = String(cols) }
                    if let rows = entry.rows { value["rows"] = String(rows) }
                    return value
                })
            })
        return DocumentSnapshot(
            workspaceID: workspace.id, seq: seq,
            nodes: nodes, connections: connections,
            criadoEm: Date(),
            noteContents: nc, sessionStates: ss, sessionOutputs: so,
            watchdogConfiguration: watchdogConfiguration,
            watchdogHistory: watchdogHistory.isEmpty ? nil : watchdogHistory)
    }

    public func save() {
        let pnc: [String: String]? = noteContents.isEmpty ? nil :
            Dictionary(uniqueKeysWithValues: noteContents.map { ($0.key.string, $0.value) })
        let pss: [String: PersistedSessionState]? = sessionStates.isEmpty ? nil :
            Dictionary(uniqueKeysWithValues: sessionStates.map { ($0.key.string, $0.value.toPersisted()) })
        let pso: [String: [PersistedSessionOutputEntry]]? = sessionOutputs.isEmpty ? nil :
            Dictionary(uniqueKeysWithValues: sessionOutputs.map { ($0.key.string, $0.value.map { $0.toPersisted() }) })
        let pnr: [String: Int]? = noteRevisions.isEmpty ? nil :
            Dictionary(uniqueKeysWithValues: noteRevisions.map { ($0.key.string, $0.value) })
        let wrapper = PersistedWorkspace(
            workspace: workspace, seq: seq, nodes: nodes, connections: connections,
            noteContents: pnc, sessionStates: pss, sessionOutputs: pso, noteRevisions: pnr,
            watchdogConfiguration: watchdogConfiguration,
            watchdogHistory: watchdogHistory.isEmpty ? nil : watchdogHistory)
        do {
            let data = try JSONEncoder().encode(wrapper)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[WorkspaceStore] save error: \(error)")
        }
    }

    public func setNoteContent(nodeID: ULID, content: String) {
        noteContents[nodeID] = content
        noteRevisions[nodeID] = (noteRevisions[nodeID] ?? 0) + 1
    }

    public func setSessionState(sessionID: ULID, estado: String, nodeID: ULID?) {
        sessionStates[sessionID] = SessionStateInfo(
            sessionID: sessionID, estado: estado,
            nodeID: nodeID ?? sessionStates[sessionID]?.nodeID,
            updatedAt: Date())
    }

    public func appendSessionOutput(sessionID: ULID, text: String, seq: UInt64 = 0, dataB64: String? = nil) {
        var buf = sessionOutputs[sessionID] ?? []
        let nextSeq = seq > 0 ? seq : (buf.last?.seq ?? 0) + 1
        buf.append(SessionOutputEntry(seq: nextSeq, text: text, receivedAt: Date(), dataB64: dataB64, kind: "output"))
        if buf.count > 500 { buf.removeFirst(buf.count - 500) }
        sessionOutputs[sessionID] = buf
    }

    public func getSessionOutputText(sessionID: ULID, maxLines: Int = 200) -> String {
        guard let buf = sessionOutputs[sessionID] else { return "" }
        let lines = buf.suffix(maxLines)
        return lines.map { $0.text }.joined()
    }

    public static func loadAll(from storageDir: URL) -> [ULID: WorkspaceStore] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil)
        else { return [:] }
        var stores: [ULID: WorkspaceStore] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let persisted = try? JSONDecoder().decode(PersistedWorkspace.self, from: data)
            else { continue }
            let store = WorkspaceStore(workspace: persisted.workspace, storageDir: storageDir)
            store.seq = persisted.seq
            store.nodes = persisted.nodes
            store.connections = persisted.connections
            if let nc = persisted.noteContents {
                store.noteContents = Dictionary(uniqueKeysWithValues: nc.compactMap { (k, v) in
                    ULID(k).map { ($0, v) }
                })
            }
            if let ss = persisted.sessionStates {
                store.sessionStates = Dictionary(uniqueKeysWithValues: ss.compactMap { (k, v) in
                    ULID(k).flatMap { ulid in v.toSessionState().map { (ulid, $0) } }
                })
            }
            if let so = persisted.sessionOutputs {
                store.sessionOutputs = Dictionary(uniqueKeysWithValues: so.compactMap { (k, v) in
                    ULID(k).map { ($0, v.map { $0.toSessionOutputEntry() }) }
                })
            }
            if let nr = persisted.noteRevisions {
                store.noteRevisions = Dictionary(uniqueKeysWithValues: nr.compactMap { (k, v) in
                    ULID(k).map { ($0, v) }
                })
            }
            store.watchdogConfiguration = persisted.watchdogConfiguration
            store.watchdogHistory = persisted.watchdogHistory ?? []
            stores[persisted.workspace.id] = store
        }
        return stores
    }
}

public struct SessionStateInfo: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var estado: String
    public var nodeID: ULID?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", estado, nodeID = "node_id", updatedAt = "updated_at"
    }

    func toPersisted() -> PersistedSessionState {
        PersistedSessionState(sessionID: sessionID.string, estado: estado,
                              nodeID: nodeID?.string, updatedAt: updatedAt)
    }
}

public struct SessionOutputEntry: Codable, Equatable, Sendable {
    public var seq: UInt64
    public var text: String
    public var receivedAt: Date
    public var dataB64: String? = nil
    public var kind: String? = nil
    public var cols: Int? = nil
    public var rows: Int? = nil

    enum CodingKeys: String, CodingKey {
        case seq, text, kind, cols, rows, dataB64 = "data_b64", receivedAt = "received_at"
    }

    func toPersisted() -> PersistedSessionOutputEntry {
        PersistedSessionOutputEntry(seq: seq, text: text, receivedAt: receivedAt,
                                    dataB64: dataB64, kind: kind, cols: cols, rows: rows)
    }
}

private struct PersistedWorkspace: Codable {
    var workspace: Workspace
    var seq: UInt64
    var nodes: [Node]
    var connections: [Connection]
    var noteContents: [String: String]?
    var sessionStates: [String: PersistedSessionState]?
    var sessionOutputs: [String: [PersistedSessionOutputEntry]]?
    var noteRevisions: [String: Int]?
    var watchdogConfiguration: WorkerWatchdogConfiguration?
    var watchdogHistory: [WatchdogHistoryEntry]?

    enum CodingKeys: String, CodingKey {
        case workspace, seq, nodes, connections
        case noteContents = "note_contents"
        case sessionStates = "session_states"
        case sessionOutputs = "session_outputs"
        case noteRevisions = "note_revisions"
        case watchdogConfiguration = "watchdog_configuration"
        case watchdogHistory = "watchdog_history"
    }
}

struct PersistedSessionState: Codable {
    var sessionID: String
    var estado: String
    var nodeID: String?
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", estado, nodeID = "node_id", updatedAt = "updated_at"
    }

    func toSessionState() -> SessionStateInfo? {
        guard let sid = ULID(sessionID) else { return nil }
        let nid = nodeID.flatMap { ULID($0) }
        return SessionStateInfo(sessionID: sid, estado: estado, nodeID: nid, updatedAt: updatedAt)
    }
}

struct PersistedSessionOutputEntry: Codable {
    var seq: UInt64
    var text: String
    var receivedAt: Date
    var dataB64: String?
    var kind: String?
    var cols: Int?
    var rows: Int?

    enum CodingKeys: String, CodingKey {
        case seq, text, kind, cols, rows, dataB64 = "data_b64", receivedAt = "received_at"
    }

    init(seq: UInt64 = 0, text: String, receivedAt: Date,
         dataB64: String? = nil, kind: String? = nil, cols: Int? = nil, rows: Int? = nil) {
        self.seq = seq
        self.text = text
        self.receivedAt = receivedAt
        self.dataB64 = dataB64
        self.kind = kind
        self.cols = cols
        self.rows = rows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        self.text = try container.decode(String.self, forKey: .text)
        self.receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        self.dataB64 = try container.decodeIfPresent(String.self, forKey: .dataB64)
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind)
        self.cols = try container.decodeIfPresent(Int.self, forKey: .cols)
        self.rows = try container.decodeIfPresent(Int.self, forKey: .rows)
    }

    func toSessionOutputEntry() -> SessionOutputEntry {
        SessionOutputEntry(seq: seq, text: text, receivedAt: receivedAt,
                           dataB64: dataB64, kind: kind, cols: cols, rows: rows)
    }
}

// MARK: - Client

public final class HubClient {
    public let fd: Int32
    private weak var hub: HubServer?
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let writeLock = NSLock()
    private var writeClosed = false
    let rateLimiter: HubRateLimiter

    var helloDone = false
    var inviteRoomID: ULID?
    var inviteToken: String?
    var joinedRoomIDs: Set<ULID> = []
    var isWebSocket = false
    var author: Author = .humanoLocal
    var clientName = "?"
    var subscriptions: [ColmeiaTopic: Set<ULID>] = [:]

    init(fd: Int32, hub: HubServer) {
        self.fd = fd
        self.hub = hub
        self.readQueue = DispatchQueue(label: "colmeia.hub.client.read.\(fd)")
        self.writeQueue = DispatchQueue(label: "colmeia.hub.client.write.\(fd)")
        self.rateLimiter = HubRateLimiter(
            maxRequestsPerSecond: hub.maxRequestsPerSecond,
            maxBytesPerSecond: hub.maxBytesPerSecond,
            maxRequestBytes: hub.maxRequestBytes)
    }

    func startReading() {
        readQueue.async { [weak self] in self?.readLoop() }
    }

    private func readLoop() {
        let lineBuffer = SocketFraming.LineBuffer()
        let wsDecoder = WebSocketFraming.FrameDecoder()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                let data = Data(bytes: chunk, count: count)
                if !isWebSocket, let key = WebSocketFraming.parseHandshakeKey(from: data) {
                    isWebSocket = true
                    let acceptKey = WebSocketFraming.computeAcceptKey(for: key)
                    let handshakeResponse = WebSocketFraming.buildHandshakeResponse(acceptKey: acceptKey)
                    // Write raw — do NOT use writeLine which appends \n and corrupts the 101 response
                    handshakeResponse.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset < buffer.count {
                            let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                            if written > 0 { offset += written }
                            else if written < 0 && errno == EINTR { continue }
                            else { break }
                        }
                    }
                    continue
                }

                if !isWebSocket, let text = String(data: data, encoding: .utf8), (text.hasPrefix("GET ") || text.hasPrefix("HEAD ")), !text.lowercased().contains("upgrade: websocket") {
                    let versionStr = hub?.version ?? "0.3.0"
                    let wantsHTML = text.contains("text/html")

                    if wantsHTML || text.contains("/join/") {
                        let html = """
                        <!DOCTYPE html>
                        <html lang="pt-BR">
                        <head>
                            <meta charset="UTF-8">
                            <meta name="viewport" content="width=device-width, initial-scale=1.0">
                             <title>Colmeia — Canvas de Agentes</title>
                             <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
                             <link href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.css" rel="stylesheet">
                             <script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.js"></script>
                            <style>
                                * { box-sizing: border-box; margin: 0; padding: 0; }
                                body { background: #131416; color: #e5e7eb; font-family: -apple-system, BlinkMacSystemFont, 'Inter', system-ui, sans-serif; height: 100vh; overflow: hidden; display: flex; flex-direction: column; }
                                
                                /* --- Topbar (idêntica ao App macOS) --- */
                                .topbar { height: 48px; background: #202020; border-bottom: 1px solid rgba(255,255,255,.06); display: flex; align-items: center; padding: 0 14px; gap: 10px; flex-shrink: 0; z-index: 100; }
                                .topbar .logo { display: flex; align-items: center; gap: 8px; font-weight: 700; font-size: 15px; color: #f1f5f9; }
                                .topbar .logo svg { width: 20px; height: 20px; }
                                .topbar .badge-status { display: flex; align-items: center; gap: 6px; min-width: 220px; background: rgba(255,255,255,.045); border: 1px solid rgba(255,255,255,.08); border-radius: 8px; padding: 6px 10px; font-size: 12px; color: #a1a1aa; }
                                .status-dot-small { width: 8px; height: 8px; border-radius: 50%; background: #10b981; box-shadow: 0 0 6px #10b981; }
                                .topbar-right { margin-left: auto; display: flex; align-items: center; gap: 8px; }
                                .topbar-btn { background: rgba(255,255,255,.045); border: 1px solid rgba(255,255,255,.08); border-radius: 8px; height: 30px; padding: 0 10px; display: flex; align-items: center; justify-content: center; color: #d4d4d8; cursor: pointer; font-size: 12px; font-weight: 500; gap: 6px; transition: all .15s; }
                                .topbar-btn:hover { background: #2a2d35; color: #f1f5f9; border-color: #475569; }
                                .topbar-btn.active { color:#93c5fd; border-color:rgba(59,130,246,.55); background:rgba(59,130,246,.16); }
                                .connection-hint { margin-left:auto; color:#93c5fd; font-size:11px; display:none; }
                                .connection-capsule { display: none; align-items: center; gap: 6px; border-radius: 20px; padding: 3px 12px; font-size: 11px; font-weight: 600; color: white; margin-left: auto; }
                                .member-pills { display: flex; gap: -4px; }
                                .member-pill { width: 28px; height: 28px; border-radius: 50%; background: rgba(148, 163, 184, 0.1); border: 2px solid #16181d; display: flex; align-items: center; justify-content: center; font-size: 10px; font-weight: 700; color: white; margin-left: -6px; cursor: pointer; position: relative; }
                                .role-badge { position: absolute; top: -2px; left: -2px; background: #3b82f6; font-size: 6px; padding: 1px 3px; border-radius: 4px; }
                                .member-pill:first-child { margin-left: 0; }
                                .member-pill.online::after { content: ''; position: absolute; bottom: -1px; right: -1px; width: 6px; height: 6px; background: #10b981; border-radius: 50%; border: 1.5px solid #16181d; }
                                .member-pill.offline::after { content: ''; position: absolute; bottom: -1px; right: -1px; width: 6px; height: 6px; background: gray; border-radius: 50%; border: 1.5px solid #16181d; }

                                .floorbar, .modebar { height: 32px; flex-shrink: 0; display: flex; align-items: center; gap: 8px; padding: 0 10px; background: rgba(31,31,31,.96); border-bottom: 1px solid rgba(255,255,255,.055); color: #a1a1aa; font-size: 11px; }
                                .floorbar { height: 28px; }
                                .floor-name { color: #e4e4e7; font-weight: 600; }
                                .mode-btn { border: 0; border-radius: 6px; padding: 4px 10px; background: rgba(255,255,255,.045); color: #a1a1aa; font: inherit; }
                                .mode-btn.active { color: #60a5fa; background: rgba(59,130,246,.13); }

                                /* --- Canvas infinito & Backdrops --- */
                                .canvas-wrap { flex: 1; position: relative; overflow: hidden; cursor: grab; }
                                .canvas-wrap:active { cursor: grabbing; }
                                .canvas { position: absolute; top: 0; left: 0; width: 6000px; height: 4000px; background-color: #131416; background-image: radial-gradient(ellipse at 10% 100%, rgba(38,73,108,.09), transparent 35%), radial-gradient(ellipse at 80% 5%, rgba(92,54,28,.045), transparent 30%), linear-gradient(rgba(255,255,255,0.06) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.06) 1px, transparent 1px); background-size: auto, auto, 100px 100px, 100px 100px; transform-origin: 0 0; }
                                 .connections-layer { position: absolute; top: 0; left: 0; width: 100%; height: 100%; pointer-events: none; }
                                 .presence-layer { position:absolute; inset:0; z-index:90; pointer-events:none; overflow:hidden; }
                                 .remote-cursor { position:absolute; transform:translate(-2px,-2px); color:var(--cursor-color); filter:drop-shadow(0 2px 2px rgba(0,0,0,.45)); }
                                 .remote-cursor svg { width:20px; height:20px; display:block; fill:currentColor; stroke:#fff; stroke-width:1.2; }
                                 .remote-cursor-label { margin-left:13px; margin-top:-3px; display:inline-block; padding:3px 7px; border-radius:10px; background:var(--cursor-color); color:white; font:700 10px system-ui; white-space:nowrap; }
                                 .viewer-pills { display:inline-flex; gap:2px; margin-left:4px; }
                                 .viewer-pill { width:16px; height:16px; border-radius:50%; display:inline-flex; align-items:center; justify-content:center; font:700 8px system-ui; color:white; border:1px solid rgba(255,255,255,.35); }

                                /* --- Cards de Nós (Nós do App macOS) --- */
                                .node { position: absolute; border-radius: 10px; overflow: hidden; box-shadow: 0 5px 18px rgba(0,0,0,.22); border: 1px solid rgba(255,255,255,0.15); transition: border-color .15s, box-shadow .15s; cursor: move; user-select: none; display: flex; flex-direction: column; }
                                .node:hover { box-shadow: 0 8px 24px rgba(0,0,0,.32); }
                                .node.selected { border: 2px solid #38bdf8; border-radius: 10px; box-shadow: 0 0 0 2px rgba(56,189,248,0.4); }
                                .node-head { min-height: 26px; padding: 5px 8px; display: flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 600; border-bottom: 1px solid rgba(255,255,255,.07); background: rgba(255,255,255,.035); flex-shrink: 0; }
                                .node-label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
                                .node-state { margin-left: auto; color: #8b8b92; font-size: 9px; font-weight: 400; display: flex; align-items: center; gap: 5px; }

                                /* Terminal */
                                .node-terminal { background: #14161b; border-radius: 10px; font-family: 'SFMono-Regular', Menlo, Monaco, Consolas, monospace; color: #dcdfe4; }
                                .node-terminal.border-red { border-color: #ef4444; }
                                .node-terminal.border-orange { border-color: #f59e0b; }
                                 .node-terminal .terminal-screen { min-height: 0; flex: 1; overflow: auto; background: #14161b; padding: 8px 7px; font-family: 'SFMono-Regular', Menlo, Monaco, Consolas, monospace; font-size: 13px; line-height: 1.35; color: #dcdfe4; user-select: text; cursor: text; }
                                 .node-terminal .xterm-host { padding:4px 3px 2px 7px; overflow:hidden; }
                                 .node-terminal .xterm-host .xterm { height:100%; }
                                 .node-terminal .xterm-host .xterm-viewport { scrollbar-width:thin; }
                                 .terminal-fallback-badge { color:#f59e0b; font-size:9px; }
                                .node-terminal .term-body { white-space: pre-wrap; word-break: break-word; }
                                .node-terminal .term-output { white-space: pre-wrap; word-break: break-word; color: #dcdfe4; }
                                .terminal-command { display:flex; align-items:center; gap:5px; margin-top:4px; color:#aeb8c4; }
                                .terminal-command input { min-width:0; flex:1; border:0; outline:0; background:transparent; color:#dcdfe4; font:inherit; caret-color:#aeb8c4; }
                                .node-terminal .status-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
                                .node-terminal .status-dot.pulsing { background: #22c55e; animation: pulse-green .9s ease-in-out infinite alternate; }
                                @keyframes pulse-green { from { opacity: 1; } to { opacity: .35; } }
                                .node-terminal .node-tag { font-size: 10px; padding: 2px 6px; border-radius: 12px; font-weight: 600; background: rgba(59,130,246,0.25); color: #60a5fa; }
                                .node-terminal .term-footer { min-height: 23px; padding: 4px 8px; border-top: 1px solid rgba(255,255,255,.07); display: flex; align-items:center; justify-content: space-between; gap:8px; font-size: 9px; color: #8b8b92; background:rgba(255,255,255,.025); flex-shrink:0; }
                                .relaunch-terminal { border:0; border-radius:5px; padding:2px 7px; background:rgba(255,255,255,.09); color:#d4d4d8; font:600 9px system-ui; cursor:pointer; }
                                .node-terminal .fallback-card { display: none; padding: 20px; text-align: center; color: #94a3b8; }
                                .scale-small .node-terminal .node-head, .scale-small .node-terminal .terminal-screen, .scale-small .node-terminal .term-footer { display: none; }
                                .scale-small .node-terminal .fallback-card { display: block; }
                                
                                .term-body .prompt { color: #aeb8c4; font-weight: 500; }
                                .term-body .cmd { color: #f1f5f9; }
                                .term-body .out { color: #94a3b8; }
                                .term-body .err { color: #f87171; }

                                /* Tarefa / Checklist */
                                .node-task { background: #16181d; }
                                .node-task .task-body { padding: 12px; }
                                .task-item { display: flex; align-items: flex-start; gap: 8px; padding: 4px 0; font-size: 12px; color: #cbd5e1; cursor: pointer; }
                                .task-item .check { width: 16px; height: 16px; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; flex-shrink: 0; margin-top: 1px; display: flex; align-items: center; justify-content: center; font-size: 14px; }
                                .task-item.done span { text-decoration: line-through; opacity: 0.5; }

                                /* Nota */
                                .node-note { --paper:#ffeb99; --ink:#3d3825; border-radius: 8px; background: rgba(255,235,153,.9); border: 1px solid rgba(0,0,0,.12); color:var(--ink); }
                                .node-note[data-theme="rosa"] { --paper:#ffc7d9; --ink:#3d3034; background:rgba(255,199,217,.9); }
                                .node-note[data-theme="verde"] { --paper:#c7f0bf; --ink:#303a2e; background:rgba(199,240,191,.9); }
                                .node-note[data-theme="azul"] { --paper:#bddeff; --ink:#2d353d; background:rgba(189,222,255,.9); }
                                .node-note[data-theme="roxo"] { --paper:#deccff; --ink:#35313d; background:rgba(222,204,255,.9); }
                                .node-note .node-head { min-height:25px; border-bottom:none; background:rgba(0,0,0,.06); color:var(--ink); padding:5px 8px; }
                                .node-note .node-label { color:var(--ink); font-size:10px; flex:1; }
                                .note-swatches { margin-left:auto; display:flex; gap:3px; }
                                .note-swatch { width:11px; height:11px; border-radius:50%; border:1px solid rgba(0,0,0,.18); cursor:pointer; opacity:.72; }
                                .note-swatch.selected { opacity:1; box-shadow:0 0 0 1px rgba(0,0,0,.48); }
                                .node-note .note-body { min-height:0; flex:1; overflow:auto; padding:8px; font-size:12px; color:var(--ink); line-height:1.3; user-select:text; cursor:text; }
                                .node-note .note-footer { min-height:19px; flex-shrink:0; padding:3px 8px; background:rgba(0,0,0,.035); color:color-mix(in srgb, var(--ink) 58%, transparent); font-size:8px; display:flex; justify-content:space-between; }
                                .node-note .note-body .carregando { color:rgba(0,0,0,.45); font-style:italic; font-size:11px; }
                                .note-editor { width:100%; height:100%; resize:none; border:0; outline:0; background:transparent; color:var(--ink); font:12px/1.35 'SFMono-Regular',Menlo,monospace; user-select:text; }
                                .note-body.editing { display:flex; flex-direction:column; gap:6px; }
                                .note-editor-actions { display:flex; justify-content:flex-end; gap:5px; flex-shrink:0; }
                                .note-editor-actions button { border:1px solid rgba(0,0,0,.16); border-radius:5px; padding:3px 8px; background:rgba(255,255,255,.28); color:var(--ink); font:600 10px system-ui; cursor:pointer; }
                                .note-editor-actions .save { background:rgba(59,130,246,.2); }
                                .note-content h1,.note-content h2,.note-content h3 { line-height:1.15; }
                                .note-content pre { padding:5px; border-radius:4px; background:rgba(255,255,255,.28); overflow:auto; font:11px 'SFMono-Regular',Menlo,monospace; }

                                /* Desenho */
                                .node-desenho { background: #16181d; }
                                .desenho-canvas { width: 100%; max-height: 200px; background: #0d0f13; border-radius: 0 0 10px 10px; display: block; }

                                /* Portal */
                                .node-portal { background: linear-gradient(135deg, #1e1b4b 0%, #1e2028 100%); border-color: #6366f1; }
                                 .node-portal .portal-body { padding: 14px; font-size: 12px; color: #c7d2fe; display: flex; align-items: flex-start; gap: 10px; }
                                 .node-portal .portal-icon { font-size: 22px; line-height: 1; }
                                 .node-portal .portal-meta { min-width: 0; flex: 1; display:flex; flex-direction:column; gap:7px; }
                                 .node-portal .portal-title { color:#eef2ff; font-weight:700; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
                                 .node-portal .portal-url { color:#a5b4fc; font:10px 'SFMono-Regular',Menlo,monospace; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
                                 .node-portal .portal-open { align-self:flex-start; padding:4px 9px; border:1px solid rgba(129,140,248,.55); border-radius:6px; background:rgba(99,102,241,.2); color:#e0e7ff; text-decoration:none; font:600 10px system-ui; }
                                 .node-portal .portal-open:hover { background:rgba(99,102,241,.38); color:white; }
                                 .node-portal .portal-invalid { color:#fca5a5; font-size:10px; }

                                /* --- Connection Lines (Bezier SVG) --- */
                                .conn-halo { stroke-width: 6; fill: none; opacity: 0.14; stroke-linecap:round; }
                                .conn-line { stroke-width: 2; fill: none; opacity: 0.78; stroke-linecap:round; }
                                .conn-line.selected { stroke-width:3; opacity:1; }
                                .conn-hit { fill:none; stroke:transparent; stroke-width:18; pointer-events:stroke; cursor:pointer; }
                                .delete-connection { color:#fca5a5; border-color:rgba(239,68,68,.35); display:none; }
                                @keyframes dash-halo { to { stroke-dashoffset: -100; } }
                                @keyframes dash { to { stroke-dashoffset: -100; } }
                                .conn-arrow { fill: #38bdf8; }

                                /* --- Toolbar flutuante inferior --- */
                                .toolbar { position: fixed; bottom: 14px; left: 50%; transform: translateX(-50%); background: rgba(31,31,31,.86); backdrop-filter: blur(18px); border: 1px solid rgba(255,255,255,.08); border-radius: 18px; padding: 6px 10px; display: flex; gap: 6px; z-index: 100; box-shadow: 0 8px 28px rgba(0,0,0,.28); }
                                .tool-btn { width:28px; height:28px; padding:0; border-radius:6px; border:none; background:transparent; color:#d4d4d8; cursor:pointer; display:flex; align-items:center; justify-content:center; font-size:16px; transition:all .15s; }
                                .tool-btn:hover { background: #2a2d35; color: #f1f5f9; }
                                .tool-btn.active { background: rgba(59,130,246,.25); color:#93c5fd; }
                                .tool-sep { width: 1px; background: #2a2d35; margin: 4px 2px; }

                                /* --- Minimap --- */
                                .minimap { position: fixed; bottom: 10px; right: 10px; width: 180px; height: 120px; background: rgba(31,31,31,.82); backdrop-filter: blur(16px); border: 0.8px solid rgba(255,255,255,0.42); border-radius: 10px; overflow: hidden; z-index: 100; box-shadow: 0 5px 12px rgba(0,0,0,.1); opacity:.94; }
                                .minimap-header { padding: 4px 8px; font-size: 8px; font-weight: 700; color: #8b8b92; letter-spacing: 0.5px; }
                                .minimap-canvas { width: 100%; height: calc(100% - 22px); position: relative; }
                                .minimap-node { position: absolute; background: #3b82f6; border-radius: 2px; opacity: 0.8; }
                                .minimap-viewport { position: absolute; border: 1.2px solid #3b82f6; border-radius: 2px; background: rgba(59,130,246,0.12); }

                                @media (max-width: 720px) {
                                    .topbar { padding:0 8px; }
                                    .topbar .logo span, .badge-status, #memberPills { display:none; }
                                    .topbar-right { gap:4px; }
                                    .topbar-btn { padding:0 8px; }
                                    .action-label { display:none; }
                                    .modebar { overflow-x:auto; }
                                    .minimap { width:130px; height:90px; }
                                    .toolbar { bottom:10px; }
                                }

                                
                                /* --- Status Overlays --- */
                                .status-overlay { position: fixed; top: 60px; left: 50%; transform: translateX(-50%); z-index: 105; backdrop-filter: blur(8px); display: none; }
                                .error-banner { background: rgba(239, 68, 68, 0.15); max-width: 420px; border-radius: 8px; padding: 12px 16px; border: 1px solid rgba(239, 68, 68, 0.3); color: #f87171; font-size: 13px; text-align: center; }
                                .engine-warning { background: rgba(245, 158, 11, 0.15); border: 0.4px solid rgba(245, 158, 11, 0.4); max-width: 420px; border-radius: 8px; padding: 12px 16px; color: #fbbf24; font-size: 13px; text-align: center; }
                                .reconnection { background: rgba(59, 130, 246, 0.2); border: 1px solid rgba(59, 130, 246, 0.4); border-radius: 20px; padding: 6px 16px; color: #60a5fa; font-size: 12px; font-weight: 500; }

                                /* --- Chat Drawer lateral --- */
                                .chat-panel { position: fixed; top: 42px; right: 0; width: 340px; height: calc(100vh - 42px); background: #16181d; border-left: 1px solid #2a2d35; display: flex; flex-direction: column; z-index: 99; transform: translateX(100%); transition: transform .25s ease; }
                                .chat-panel.open { transform: translateX(0); }
                                .chat-head { padding: 14px 16px; border-bottom: 1px solid #2a2d35; font-size: 14px; font-weight: 600; display: flex; align-items: center; justify-content: space-between; }
                                .chat-msgs { flex: 1; padding: 14px; overflow-y: auto; display: flex; flex-direction: column; gap: 10px; }
                                .msg { max-width: 85%; padding: 9px 13px; border-radius: 14px; font-size: 12px; line-height: 1.4; word-break: break-word; }
                                .msg.me { align-self: flex-end; background: #3b82f6; color: white; border-bottom-right-radius: 2px; }
                                .msg.me .msg-meta { font-size: 9px; color: rgba(255,255,255,0.7); display: flex; justify-content: flex-end; align-items: center; gap: 4px; margin-top: 4px; }
                                .msg.other { align-self: flex-start; background: #1e2028; border: 1px solid #2a2d35; border-bottom-left-radius: 2px; }
                                .msg.other .msg-meta { font-size: 9px; color: #64748b; display: flex; justify-content: flex-end; align-items: center; gap: 4px; margin-top: 4px; }
                                .msg .author { font-size: 10px; font-weight: 700; color: #60a5fa; margin-bottom: 2px; }
                                .chat-composer { padding: 12px; border-top: 1px solid #2a2d35; display: flex; gap: 8px; }
                                .chat-composer input { flex: 1; background: #1e2028; border: 1px solid #2a2d35; border-radius: 20px; padding: 8px 14px; color: white; font-size: 12px; outline: none; }
                                .chat-composer input:focus { border-color: #3b82f6; }
                                .chat-composer button { background: #3b82f6; color: white; border: none; border-radius: 50%; width: 32px; height: 32px; cursor: pointer; font-size: 14px; display: flex; align-items: center; justify-content: center; }
                                .watchdog-panel { position:fixed; top:50px; right:10px; z-index:120; width:310px; padding:14px; border:1px solid #3b3f48; border-radius:12px; background:rgba(22,24,29,.97); box-shadow:0 16px 40px rgba(0,0,0,.4); display:none; }
                                .watchdog-panel.open { display:block; }
                                .watchdog-grid { display:grid; grid-template-columns:1fr 1fr; gap:8px; margin-top:10px; }
                                .watchdog-stat { padding:8px; border-radius:8px; background:#1e2028; color:#94a3b8; font-size:10px; }
                                .watchdog-stat strong { display:block; margin-top:3px; color:#f1f5f9; font-size:13px; }
                                .watchdog-alert { margin-top:8px; padding:8px; border-left:3px solid #f59e0b; background:rgba(245,158,11,.08); color:#fcd34d; font-size:11px; line-height:1.4; }

                                /* --- State Machine Overlay (loading/error) --- */
                                .state-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.8); backdrop-filter: blur(12px); display: flex; align-items: center; justify-content: center; z-index: 300; }
                                .state-card { background: #16181d; border: 1px solid #2a2d35; border-radius: 20px; padding: 40px; width: 420px; text-align: center; box-shadow: 0 24px 60px rgba(0,0,0,0.9); }
                                .state-card h2 { font-size: 18px; font-weight: 700; margin-bottom: 8px; color: #f1f5f9; }
                                .state-card p { font-size: 13px; color: #94a3b8; margin-bottom: 8px; line-height: 1.5; }
                                .state-card .error-detail { font-size: 12px; color: #f87171; margin-bottom: 20px; padding: 8px 12px; background: rgba(239,68,68,0.1); border-radius: 8px; display: none; }
                                .state-card .btn-group { display: flex; gap: 10px; margin-top: 16px; justify-content: center; }
                                .state-card .btn-primary { background: #3b82f6; color: white; border: none; border-radius: 10px; padding: 10px 24px; font-size: 13px; font-weight: 600; cursor: pointer; transition: background .15s; }
                                .state-card .btn-primary:hover { background: #2563eb; }
                                .state-card .btn-secondary { background: #1e2028; color: #94a3b8; border: 1px solid #2a2d35; border-radius: 10px; padding: 10px 24px; font-size: 13px; font-weight: 500; cursor: pointer; transition: all .15s; text-decoration: none; display: inline-flex; align-items: center; gap: 6px; }
                                .state-card .btn-secondary:hover { background: #2a2d35; color: #f1f5f9; border-color: #475569; }
                                .spinner { width: 36px; height: 36px; border: 3px solid #2a2d35; border-top-color: #3b82f6; border-radius: 50%; animation: spin 0.8s linear infinite; margin: 0 auto 20px auto; }
                                @keyframes spin { to { transform: rotate(360deg); } }
                            </style>
                        </head>
                        <body>
                            <!-- Topbar -->
                            <div class="topbar">
                                <div class="logo">
                                    <svg viewBox="0 0 24 24" fill="none"><path d="M12 2L2 7l10 5 10-5-10-5z" fill="#f59e0b"/><path d="M2 17l10 5 10-5" stroke="#f59e0b" stroke-width="2" fill="none"/><path d="M2 12l10 5 10-5" stroke="#f59e0b" stroke-width="2" fill="none" opacity="0.5"/></svg>
                                    <span>Colmeia</span>
                                </div>
                                <div class="badge-status">
                                    <div class="status-dot-small"></div>
                                    <span id="roomTitle">Carregando sala...</span>
                                    <span id="workspaceBadge" style="margin-left:8px;font-size:11px;color:#64748b;display:none"></span>
                                </div>
                                <div class="connection-capsule" id="connectionCapsule">🔄 Sincronizando...</div>
                                <div class="topbar-right">
                                    <button class="topbar-btn" onclick="addNode('terminal')" title="Novo Terminal"><span>⌨︎</span><span class="action-label">Terminal</span></button>
                                    <button class="topbar-btn" onclick="addNode('note')" title="Nova Nota"><span>▤</span><span class="action-label">Nota</span></button>
                                    <button class="topbar-btn" onclick="addNode('portal')" title="Novo navegador"><span>◉</span><span class="action-label">Navegador</span></button>
                                    <button class="topbar-btn" id="connectButton" onclick="toggleConnectionMode()" title="Conectar dois cartões"><span>↗</span><span class="action-label">Conectar</span></button>
                                    <button class="topbar-btn delete-connection" id="deleteConnectionButton" onclick="deleteSelectedConnection()" title="Excluir conexão selecionada"><span>×</span><span class="action-label">Excluir conexão</span></button>
                                    <div class="member-pills" id="memberPills"></div>
                                    <button class="topbar-btn" id="userNameButton" onclick="editUserName()" title="Alterar seu nome"><span>◉</span><span class="action-label">Meu nome</span></button>
                                    <button class="topbar-btn" id="watchdogButton" onclick="toggleWatchdog()" title="Estado do watchdog">⚙ Watchdog</button>
                                    <button class="topbar-btn" onclick="toggleChat()">💬 Chat</button>
                                    <button class="topbar-btn" id="appLink" onclick="openInApp()" title="Abrir esta sala no app do Mac">⌘ Abrir no Mac</button>
                                </div>
                            </div>

                            <div class="watchdog-panel" id="watchdogPanel">
                                <div class="chat-head" style="padding:0 0 10px"><span>⚙ Watchdog</span><button class="topbar-btn" onclick="toggleWatchdog()" style="height:24px;padding:0 6px">✕</button></div>
                                <div id="watchdogContent" style="color:#94a3b8;font-size:12px">Aguardando dados do Engine...</div>
                            </div>
                            <div class="floorbar" title="Piso atual"><span>▱</span><span class="floor-name">térreo</span><span style="font-family:monospace">térreo</span></div>
                            <div class="modebar">
                                <button class="mode-btn active" data-mode="livre" onclick="setCanvasMode('livre')">▦ &nbsp;Visão livre</button>
                                <button class="mode-btn" data-mode="missao" onclick="setCanvasMode('missao')">⚑ &nbsp;Visão da Missão</button>
                                <button class="mode-btn" data-mode="equipe" onclick="setCanvasMode('equipe')">♟ &nbsp;Equipe</button>
                                <button class="mode-btn" data-mode="atencao" onclick="setCanvasMode('atencao')">⚠ &nbsp;Atenção</button>
                                <button class="mode-btn" data-mode="execucao" onclick="setCanvasMode('execucao')">▣ &nbsp;Execução</button>
                                <span class="connection-hint" id="connectionHint"></span>
                            </div>
                            
                            <!-- Status Overlays -->
                            <div class="status-overlay error-banner" id="errorBanner">Erro de conexão</div>
                            <div class="status-overlay engine-warning" id="engineWarning">Aviso de versão</div>
                            <div class="status-overlay reconnection" id="reconnectionBanner">🔄 Sincronizando...</div>

                            <!-- Canvas Wrap -->
                             <div class="canvas-wrap" id="canvasWrap">
                                <div class="canvas" id="canvas">
                                    <svg class="connections-layer" id="connLayer" width="6000" height="4000"></svg>
                                    <div id="nodesContainer"></div>
                                 </div>
                                 <div class="presence-layer" id="presenceLayer"></div>
                             </div>

                             <!-- Toolbar Inferior -->
                             <div class="toolbar">
                                  <button class="tool-btn active" id="selectToolButton" onclick="clearCanvasSelection()" title="Selecionar ou limpar seleção"><span class="tool-glyph">↖</span><span class="tool-label">Selecionar</span></button>
                                  <button class="tool-btn" onclick="addNode('terminal')" title="Novo terminal"><span class="tool-glyph">⌨</span><span class="tool-label">Terminal</span></button>
                                  <button class="tool-btn" onclick="addNode('note')" title="Nova nota"><span class="tool-glyph">▤</span><span class="tool-label">Nota</span></button>
                                  <button class="tool-btn" onclick="addNode('portal')" title="Novo navegador"><span class="tool-glyph">◉</span><span class="tool-label">Navegador</span></button>
                                  <button class="tool-btn" id="connectToolButton" onclick="toggleConnectionMode()" title="Conectar cartões"><span class="tool-glyph">↗</span><span class="tool-label">Conectar</span></button>
                                  <div class="tool-sep"></div>
                                  <button class="tool-btn" onclick="toggleSearch()" title="Buscar no workspace (⌘K)"><span class="tool-glyph">⌕</span><span class="tool-label">Buscar</span></button>
                                  <button class="tool-btn danger" id="deleteSelectedButton" onclick="deleteSelected()" disabled title="Excluir seleção (Delete)"><span class="tool-glyph">⌫</span><span class="tool-label">Excluir</span></button>
                                  <button class="tool-btn" onclick="hasFittedCanvas=false;fitCanvasToNodes()" title="Enquadrar canvas"><span class="tool-glyph">⌗</span><span class="tool-label">Enquadrar</span></button>
                              </div>
                              <div class="search-panel" id="searchPanel">
                                  <input class="search-input" id="searchInput" type="search" autocomplete="off" placeholder="Buscar cartões, notas e portais...">
                                  <div class="search-results" id="searchResults"></div>
                              </div>

                            <!-- Minimap -->
                            <div class="minimap">
                                <div class="minimap-header">⌘ MAPA</div>
                                <div class="minimap-canvas" id="minimapCanvas">
                                    <div class="minimap-viewport" id="minimapViewport"></div>
                                </div>
                            </div>

                            <!-- Chat Panel Drawer -->
                            <div class="chat-panel" id="chatPanel">
                                <div class="chat-head">
                                    <span>💬 Chat da Sala</span>
                                    <button class="topbar-btn" onclick="toggleChat()" style="height:24px;padding:0 6px">✕</button>
                                </div>
                                <div class="chat-msgs" id="chatMessages">
                                    <div style="text-align:center;color:#64748b;font-size:12px;margin-top:20px">Conectando à sala...</div>
                                </div>
                                <form class="chat-composer" id="chatForm">
                                    <input type="text" id="msgInput" placeholder="Enviar mensagem..." autocomplete="off">
                                    <button type="submit">➔</button>
                                </form>
                            </div>

                            <!-- State Machine Overlay (loading → authenticating → joining → snapshot → ready / error) -->
                            <div class="state-overlay" id="stateOverlay" style="display:flex">
                                <div class="state-card">
                                    <div class="spinner" id="stateSpinner"></div>
                                    <h2>Colmeia</h2>
                                    <p id="stateMessage">Carregando sala...</p>
                                    <div class="error-detail" id="stateErrorDetail"></div>
                                    <div class="btn-group">
                                        <button class="btn-primary" id="stateRetryBtn" style="display:none">Tentar novamente</button>
                                        <a class="btn-secondary" id="stateAppBtn" style="display:none" href="#">📱 Abrir no App</a>
                                    </div>
                                </div>
                            </div>

                            <script id="watchdog">
                                (function(){ var w=document.createElement('div'); w.id='watchdog';
                                window.bootReady=false;
                                setTimeout(function(){
                                    if(window.bootReady) return;
                                    var o=document.getElementById('stateOverlay'), s=document.getElementById('stateSpinner'), m=document.getElementById('stateMessage'), e=document.getElementById('stateErrorDetail'), r=document.getElementById('stateRetryBtn'), a=document.getElementById('stateAppBtn');
                                    if(o) o.style.display='flex';
                                    if(s) s.style.display='none';
                                    if(m){ m.textContent='Erro de inicializacao'; m.style.color='#f87171'; }
                                    if(e){ e.textContent='A pagina encontrou um erro interno. Tente novamente.'; e.style.display='block'; }
                                    if(r){ r.style.display='inline-block'; r.onclick=function(){ location.reload(); }; }
                                    if(a) a.style.display='inline-block';
                                }, 10000); })();
                            </script>
                            <script>
                                /* --- Pan & Zoom --- */
                                const wrap = document.getElementById('canvasWrap');
                                const canvas = document.getElementById('canvas');
                                let panX = 0, panY = 0, scale = 1, isPanning = false, startX, startY;
                                let hasFittedCanvas = false;

                                 function applyTransform() {
                                     canvas.style.transform = `translate(${panX}px,${panY}px) scale(${scale})`;
                                    if(scale < 0.4) { document.body.classList.add('scale-small'); } else { document.body.classList.remove('scale-small'); }
                                     updateMinimap();
                                     renderRemotePresences();
                                     schedulePresence();
                                }
                                wrap.addEventListener('mousedown', e => {
                                    if(e.target === wrap || e.target === canvas || e.target.tagName === 'svg') {
                                        isPanning = true; startX = e.clientX - panX; startY = e.clientY - panY;
                                    }
                                });
                                 window.addEventListener('mousemove', e => {
                                     if(isPanning) { panX = e.clientX - startX; panY = e.clientY - startY; applyTransform(); }
                                     const rect = wrap.getBoundingClientRect();
                                     if (e.clientX >= rect.left && e.clientX <= rect.right && e.clientY >= rect.top && e.clientY <= rect.bottom) {
                                         localCursor = {x:(e.clientX - rect.left - panX) / scale, y:(e.clientY - rect.top - panY) / scale};
                                         schedulePresence();
                                     }
                                });
                                window.addEventListener('mouseup', () => isPanning = false);
                                wrap.addEventListener('wheel', e => {
                                    const nativeScroll = e.target.closest('.terminal-screen,.note-body,.chat-msgs,textarea,[data-native-scroll]');
                                    if (nativeScroll && !e.metaKey && !e.ctrlKey && !e.altKey) return;
                                    e.preventDefault();
                                    if (e.metaKey || e.ctrlKey) {
                                        const ns = Math.max(0.1, Math.min(4, scale * Math.pow(2, -e.deltaY / 250)));
                                        const rect = wrap.getBoundingClientRect();
                                        const mx = e.clientX - rect.left, my = e.clientY - rect.top;
                                        panX = mx - (mx - panX) * (ns / scale);
                                        panY = my - (my - panY) * (ns / scale);
                                        scale = ns;
                                    } else {
                                        panX -= e.deltaX;
                                        panY -= e.deltaY;
                                    }
                                    applyTransform();
                                }, { passive: false });

                                function zoomIn() { scale = Math.min(4, scale * 1.2); applyTransform(); }
                                function zoomOut() { scale = Math.max(0.1, scale * 0.8); applyTransform(); }
                                function resetZoom() { scale = 1; applyTransform(); }

                                function fitCanvasToNodes() {
                                    const nodes = renderedNodes.length ? renderedNodes : activeNodes;
                                    if (!nodes.length) return;
                                    const rect = wrap.getBoundingClientRect();
                                    const minX = Math.min(...nodes.map(nodeX));
                                    const minY = Math.min(...nodes.map(nodeY));
                                    const maxX = Math.max(...nodes.map(n => nodeX(n) + nodeW(n)));
                                    const maxY = Math.max(...nodes.map(n => nodeY(n) + nodeH(n)));
                                    const padding = rect.width < 720 ? 28 : 80;
                                    scale = Math.max(0.1, Math.min(1, Math.min((rect.width - padding * 2) / Math.max(1, maxX - minX), (rect.height - padding * 2) / Math.max(1, maxY - minY))));
                                    panX = (rect.width - (maxX - minX) * scale) / 2 - minX * scale;
                                    panY = (rect.height - (maxY - minY) * scale) / 2 - minY * scale;
                                    hasFittedCanvas = true;
                                    applyTransform();
                                }

                                /* --- Nós e Conexões do Canvas (carregados do workspace real) --- */
                                let activeNodes = [];
                                let activeConns = [];
                                let workspaceID = null;
                                let workspaceSeq = null;
                                let connectionStatus = 'disconnected'; // 'syncing' | 'live' | 'disconnected'
                                let reconnectAttempt = 0;
                                let noteContentsMap = {};
                                let sessionStatesMap = {};
                                let sessionStatesByNode = {};
                                let currentSessionByNode = {};
                                let sessionOutputsMap = {};
                                let canvasMode = 'livre';
                                let renderedNodes = [];
                                let connectionMode = false;
                                let connectionFrom = null;
                                let selectedConnectionID = null;
                                let roomAgentSessions = [];
                                let roomEvents = [];
                                let memberNames = {};
                                 let watchdogConfiguration = null;
                                 let watchdogAlerts = [];
                                 const remotePresences = new Map();
                                 let localCursor = null;
                                 let presenceTimer = null;
                                 let presenceInFlight = false;
                                 const terminalControllers = new Map();
                                 const xtermAvailable = typeof Terminal === 'function';
                                const browserAuthorKey = 'colmeia.browser.author.' + location.pathname;
                                let browserAuthor;
                                try { browserAuthor = localStorage.getItem(browserAuthorKey); } catch {}
                                 if (!browserAuthor) {
                                    browserAuthor = 'humano:web-' + Math.random().toString(36).slice(2, 10);
                                    try { localStorage.setItem(browserAuthorKey, browserAuthor); } catch {}
                                }

                                function newULID() {
                                    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
                                    let time = Date.now();
                                    let value = '';
                                    for (let i = 0; i < 10; i++) {
                                        value = alphabet[time % 32] + value;
                                        time = Math.floor(time / 32);
                                    }
                                    const random = new Uint8Array(16);
                                    crypto.getRandomValues(random);
                                    for (const byte of random) value += alphabet[byte & 31];
                                    return value;
                                }

                                function indexSessionStates(states) {
                                    sessionStatesMap = {};
                                    sessionStatesByNode = {};
                                    currentSessionByNode = {};
                                    (states || []).forEach(s => {
                                        sessionStatesMap[s.session_id] = s;
                                        if (s.node_id) {
                                            if (!sessionStatesByNode[s.node_id]) sessionStatesByNode[s.node_id] = [];
                                            sessionStatesByNode[s.node_id].push(s);
                                            if (!['encerrada','morta'].includes(s.estado)) currentSessionByNode[s.node_id] = s.session_id;
                                        }
                                    });
                                }

                                 function terminalSessionID(node) {
                                    if (currentSessionByNode[node.id]) return currentSessionByNode[node.id];
                                    if (node.session_id) return node.session_id;
                                    const candidates = sessionStatesByNode[node.id] || [];
                                     candidates.sort((a,b) => Date.parse(b.updated_at || 0) - Date.parse(a.updated_at || 0));
                                     return candidates.length ? candidates[0].session_id : null;
                                 }

                                 function memberCursorColor(memberID) {
                                     let value = 0;
                                     for (const char of memberID) value = (value * 31 + char.charCodeAt(0)) % 360;
                                     return `hsl(${value} 72% 55%)`;
                                 }

                                 function renderRemotePresences() {
                                     const layer = document.getElementById('presenceLayer');
                                     if (!layer) return;
                                     layer.innerHTML = '';
                                     for (const presence of remotePresences.values()) {
                                         if (!presence.connected || !presence.cursor || presence.member_id === browserAuthor) continue;
                                         const cursor = document.createElement('div');
                                         cursor.className = 'remote-cursor';
                                         cursor.style.left = (panX + presence.cursor.x * scale) + 'px';
                                         cursor.style.top = (panY + presence.cursor.y * scale) + 'px';
                                         cursor.style.setProperty('--cursor-color', memberCursorColor(presence.member_id));
                                         const name = presence.display_name || memberNames[presence.member_id] || presence.member_id;
                                         cursor.innerHTML = `<svg viewBox="0 0 24 24"><path d="M4 2l15 11-7 1-4 7z"/></svg><span class="remote-cursor-label">${esc(name)}</span>`;
                                         layer.appendChild(cursor);
                                     }
                                 }

                                 function selectedNodeID() {
                                     return activeNodes.find(n => n.selected)?.id || null;
                                 }

                                 function selectNodeForPresence(nodeID) {
                                     activeNodes.forEach(n => n.selected = n.id === nodeID);
                                     document.querySelectorAll('.node').forEach(card => {
                                         card.classList.toggle('selected', card.id === nodeID);
                                     });
                                     schedulePresence(true);
                                 }

                                 function schedulePresence(immediate = false) {
                                     clearTimeout(presenceTimer);
                                     presenceTimer = setTimeout(sendPresence, immediate ? 0 : 70);
                                 }

                                 async function sendPresence() {
                                     if (state !== 'ready' || !INVITE_ROOM || presenceInFlight) return;
                                     presenceInFlight = true;
                                     try {
                                         await rpc('presence.update', {
                                             room_id:INVITE_ROOM,
                                             viewport:{x:-panX/scale, y:-panY/scale, zoom:scale},
                                             cursor:localCursor,
                                             selected_node_id:selectedNodeID()
                                         });
                                     } catch {} finally { presenceInFlight = false; }
                                 }

                                 function sessionIsLive(state) {
                                     return !!state && !['encerrada','morta'].includes(state);
                                 }

                                 function bytesToBase64(bytes) {
                                     let binary = '';
                                     for (let i = 0; i < bytes.length; i += 0x8000) {
                                         binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
                                     }
                                     return btoa(binary);
                                 }

                                 function base64ToBytes(value) {
                                     const binary = atob(value || '');
                                     const bytes = new Uint8Array(binary.length);
                                     for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                                     return bytes;
                                 }

                                 function queueTerminalInput(controller, data) {
                                     if (!controller.sessionID || controller.disposed || controller.term.options.disableStdin) return;
                                     const sessionID = controller.sessionID;
                                     const payload = bytesToBase64(new TextEncoder().encode(data));
                                     controller.inputChain = controller.inputChain.then(async () => {
                                         if (controller.disposed || controller.sessionID !== sessionID) return;
                                         await rpc('session.input', { session_id:sessionID, data_b64:payload });
                                     }).catch(error => {
                                         console.error('terminal input failed', error);
                                         controller.term.options.disableStdin = true;
                                         alert('Entrada do terminal indisponível: ' + friendlyError(error.message));
                                     });
                                 }

                                 function resizeWebTerminal(controller) {
                                     if (!controller || controller.disposed || !controller.host.isConnected) return;
                                     const width = controller.host.clientWidth - 10;
                                     const height = controller.host.clientHeight - 6;
                                     if (width <= 0 || height <= 0) return;
                                     const cols = Math.max(20, Math.min(240, Math.floor(width / 7.85)));
                                     const rows = Math.max(4, Math.min(100, Math.floor(height / 17.2)));
                                     if (controller.term.cols !== cols || controller.term.rows !== rows) controller.term.resize(cols, rows);
                                     if (controller.sessionID && sessionIsLive(controller.state) &&
                                         (controller.lastCols !== cols || controller.lastRows !== rows)) {
                                         controller.lastCols = cols; controller.lastRows = rows;
                                         clearTimeout(controller.resizeTimer);
                                         controller.resizeTimer = setTimeout(() => {
                                             rpc('session.resize', {session_id:controller.sessionID, cols, rows}).catch(() => {});
                                         }, 120);
                                     }
                                 }

                                 function disposeTerminalController(controller) {
                                     if (!controller || controller.disposed) return;
                                     controller.disposed = true;
                                     clearTimeout(controller.resizeTimer);
                                     controller.observer?.disconnect();
                                     controller.inputDisposable?.dispose();
                                     controller.term?.dispose();
                                 }

                                 function mountWebTerminal(node, sessionID, state, placeholder) {
                                     if (!xtermAvailable || !sessionID) return null;
                                     let controller = terminalControllers.get(node.id);
                                     if (controller && controller.sessionID !== sessionID) {
                                         disposeTerminalController(controller);
                                         terminalControllers.delete(node.id);
                                         controller = null;
                                     }
                                     if (controller) {
                                         placeholder.replaceWith(controller.host);
                                         controller.state = state;
                                         controller.term.options.disableStdin = !sessionIsLive(state);
                                         requestAnimationFrame(() => resizeWebTerminal(controller));
                                         return controller;
                                     }
                                     const host = placeholder;
                                     host.classList.add('xterm-host');
                                     const term = new Terminal({
                                         cursorBlink:true, convertEol:false, scrollback:5000,
                                         fontFamily:'SFMono-Regular, Menlo, Monaco, Consolas, monospace',
                                         fontSize:13, lineHeight:1.18,
                                         theme:{background:'#14161b', foreground:'#dcdfe4', cursor:'#f1f5f9', selectionBackground:'#334155'}
                                     });
                                     controller = {nodeID:node.id, sessionID, state, host, term, disposed:false,
                                         inputChain:Promise.resolve(), lastCols:0, lastRows:0, lastSeq:0, resizeTimer:null};
                                     terminalControllers.set(node.id, controller);
                                     term.open(host);
                                     term.options.disableStdin = !sessionIsLive(state);
                                     const entries = (sessionOutputsMap[sessionID] || []).slice().sort((a,b) => Number(a.seq || 0) - Number(b.seq || 0));
                                     entries.forEach(entry => {
                                         if (entry.kind === 'resize' && entry.cols && entry.rows) {
                                             term.resize(Number(entry.cols), Number(entry.rows));
                                         } else if (entry.data_b64) term.write(base64ToBytes(entry.data_b64));
                                         else if (entry.text) term.write(entry.text);
                                         controller.lastSeq = Math.max(controller.lastSeq, Number(entry.seq || 0));
                                     });
                                     controller.inputDisposable = term.onData(data => queueTerminalInput(controller, data));
                                     host.addEventListener('mousedown', e => {
                                         e.stopPropagation();
                                         selectNodeForPresence(node.id);
                                         term.focus();
                                     });
                                     host.addEventListener('wheel', e => e.stopPropagation(), {passive:true});
                                     controller.observer = new ResizeObserver(() => resizeWebTerminal(controller));
                                     controller.observer.observe(host);
                                     requestAnimationFrame(() => { resizeWebTerminal(controller); if (sessionIsLive(state)) term.focus(); });
                                     return controller;
                                 }

                                function nodesForMode(nodes) {
                                    if (canvasMode === 'equipe') {
                                         return nodes.filter(n => ['terminal', 'nota', 'portal'].includes(nodeTipo(n)));
                                    }
                                    if (canvasMode === 'atencao') return nodes.filter(n => {
                                        if (nodeTipo(n) !== 'terminal') return false;
                                        const states = sessionStatesByNode[n.id] || [sessionStatesMap[n.session_id] || {}];
                                        return states.some(s => ['aprovacao_pendente','aprovacaoPendente','esperando_humano','esperandoHumano'].includes(s.estado));
                                    });
                                    return nodes;
                                }

                                function setCanvasMode(mode) {
                                    canvasMode = mode;
                                    document.querySelectorAll('.mode-btn').forEach(b => b.classList.toggle('active', b.dataset.mode === mode));
                                    hasFittedCanvas = false;
                                    renderAllNodes(activeNodes);
                                }

                                function updateConnectionHint(text) {
                                    const hint = document.getElementById('connectionHint');
                                    hint.textContent = text || '';
                                    hint.style.display = text ? 'inline' : 'none';
                                    document.getElementById('connectButton').classList.toggle('active', connectionMode);
                                }

                                function toggleConnectionMode() {
                                    connectionMode = !connectionMode;
                                    connectionFrom = null;
                                    activeNodes.forEach(n => n.selected = false);
                                    updateConnectionHint(connectionMode ? 'Selecione o cartão de origem' : '');
                                    renderAllNodes(activeNodes);
                                }

                                function selectConnection(connectionID) {
                                    selectedConnectionID = selectedConnectionID === connectionID ? null : connectionID;
                                    document.getElementById('deleteConnectionButton').style.display = selectedConnectionID ? 'inline-flex' : 'none';
                                    renderConnections(canvasMode === 'atencao' ? [] : activeConns, renderedNodes);
                                }

                                async function deleteSelectedConnection() {
                                    if (!selectedConnectionID) return;
                                    const connectionID = selectedConnectionID;
                                    const removed = activeConns.find(c => c.id === connectionID);
                                    selectedConnectionID = null;
                                    document.getElementById('deleteConnectionButton').style.display = 'none';
                                    activeConns = activeConns.filter(c => c.id !== connectionID);
                                    renderAllNodes(activeNodes);
                                    try {
                                        await applyDocumentOp('connection.delete', { id:connectionID });
                                    } catch (error) {
                                        if (removed) activeConns.push(removed);
                                        renderAllNodes(activeNodes);
                                        alert('Não foi possível excluir a conexão: ' + friendlyError(error.message));
                                    }
                                }

                                async function selectConnectionNode(node) {
                                    if (!connectionFrom) {
                                        connectionFrom = node.id;
                                        activeNodes.forEach(n => n.selected = n.id === node.id);
                                        updateConnectionHint('Agora selecione o cartão de destino');
                                        renderAllNodes(activeNodes);
                                        return;
                                    }
                                    if (connectionFrom === node.id) {
                                        connectionFrom = null;
                                        activeNodes.forEach(n => n.selected = false);
                                        updateConnectionHint('Selecione o cartão de origem');
                                        renderAllNodes(activeNodes);
                                        return;
                                    }
                                    const sourceID = connectionFrom;
                                    const connection = {
                                        id:newULID(), de:sourceID, para:node.id,
                                        semantica:nodeTipo(node) === 'nota' ? 'escrita-de-nota' : 'conversa',
                                        estilo:nodeTipo(node) === 'nota' ? 'solida' : 'tracejada'
                                    };
                                    connectionMode = false;
                                    connectionFrom = null;
                                    activeNodes.forEach(n => n.selected = false);
                                    updateConnectionHint('');
                                    activeConns.push(connection);
                                    renderAllNodes(activeNodes);
                                    try {
                                        await applyDocumentOp('connection.add', { connection });
                                    } catch (error) {
                                        activeConns = activeConns.filter(c => c.id !== connection.id);
                                        renderAllNodes(activeNodes);
                                        alert('Não foi possível criar a conexão: ' + friendlyError(error.message));
                                    }
                                }

                                async function relaunchTerminal(nodeID) {
                                    const node = activeNodes.find(n => n.id === nodeID);
                                    if (!node || node.launching) return;
                                    node.launching = true;
                                    renderAllNodes(activeNodes);
                                    try {
                                        const result = await rpc('session.start', { workspace_id:workspaceID, node_id:nodeID, cols:80, rows:24 });
                                        if (result.session) {
                                            const session = result.session;
                                            currentSessionByNode[nodeID] = session.id;
                                            const stateRecord = {session_id:session.id, node_id:nodeID, estado:session.estado || 'iniciando'};
                                            sessionStatesMap[session.id] = stateRecord;
                                            sessionStatesByNode[nodeID] = (sessionStatesByNode[nodeID] || []).concat([stateRecord]);
                                        }
                                        node.launching = false;
                                        renderAllNodes(activeNodes);
                                        setTimeout(requestSnapshot, 1800);
                                        setTimeout(requestSnapshot, 4200);
                                    } catch (error) {
                                        node.launching = false;
                                        renderAllNodes(activeNodes);
                                        alert('Não foi possível relançar: ' + friendlyError(error.message));
                                    }
                                }

                                async function applyDocumentOp(tipo, payload) {
                                    if (!workspaceID) throw new Error('workspace indisponível');
                                    const op = {
                                        op_id: newULID(),
                                        author: browserAuthor,
                                        ts: new Date().toISOString(),
                                        tipo,
                                        payload
                                    };
                                    const result = await rpc('doc.apply', {
                                        workspace_id: workspaceID,
                                        ops: [op]
                                    });
                                    if (result && result.seq_final) workspaceSeq = result.seq_final;
                                }

                                function setConnectionStatus(status) {
                                    connectionStatus = status;
                                    const c = document.getElementById('connectionCapsule');
                                    if (!c) return;
                                    if (status === 'live') {
                                        c.style.display = 'none';
                                    } else {
                                        c.style.display = 'inline-flex';
                                        c.style.background = status === 'syncing' ? '#f59e0b' : '#ef4444';
                                        c.textContent = status === 'syncing' ? '🔄 Sincronizando...' : '🔴 Desconectado';
                                    }
                                }

                                async function requestSnapshot() {
                                    setConnectionStatus('syncing');
                                    try {
                                        const result = await rpc('workspace.open', { id: workspaceID });
                                        const snap = result.document_snapshot;
                                        if (snap) {
                                            activeNodes = snap.nodes || [];
                                            activeConns = snap.connections || [];
                                            workspaceSeq = snap.seq || 0;
                                            noteContentsMap = snap.note_contents || {};
                                            const ssList = snap.session_states || [];
                                             indexSessionStates(ssList);
                                             sessionOutputsMap = snap.session_outputs || {};
                                             watchdogConfiguration = snap.watchdog_configuration || null;
                                             watchdogAlerts = snap.watchdog_history || [];
                                             renderWatchdog();
                                             renderAllNodes(activeNodes);
                                        }
                                        setConnectionStatus('live');
                                    } catch (err) {
                                        console.warn('requestSnapshot error:', err);
                                        setConnectionStatus('disconnected');
                                    }
                                }

                                function nodeX(n) { return n.posicao ? n.posicao.x : (n.x || 0); }
                                function nodeY(n) { return n.posicao ? n.posicao.y : (n.y || 0); }
                                function nodeW(n) { if(n.tamanho) return n.tamanho.w; if(n.w) return n.w; return n.tipo === 'terminal' ? 640 : (n.tipo === 'nota' ? 320 : 280); }
                                function nodeH(n) { if(n.tamanho) return n.tamanho.h; if(n.h) return n.h; return n.tipo === 'terminal' ? 420 : (n.tipo === 'nota' ? 240 : 200); }
                                 function nodeLabel(n) { return n.nome || n.label || n.titulo || n.id || 'Nó'; }
                                 function nodeTipo(n) { return n.tipo || 'terminal'; }
                                 function safePortalURL(raw) {
                                     try {
                                         const value = new URL(String(raw || ''));
                                         if (!['http:', 'https:'].includes(value.protocol) || !value.hostname || value.username || value.password) return null;
                                         return value.href;
                                     } catch { return null; }
                                 }
                                 function attrEsc(s) {
                                     return esc(s).replace(/"/g, '&quot;').replace(/'/g, '&#39;');
                                 }

                                function renderAllNodes(nodes) {
                                    const c = document.getElementById('nodesContainer');
                                    c.innerHTML = '';
                                    renderedNodes = nodesForMode(nodes);
                                    if(scale < 0.4) { document.body.classList.add('scale-small'); } else { document.body.classList.remove('scale-small'); }
                                     
                                    renderedNodes.forEach(n => {
                                        const tipo = nodeTipo(n);
                                        const el = document.createElement('div');
                                        el.className = 'node node-' + (tipo === 'nota' ? 'note' : tipo) + (n.selected ? ' selected' : '');
                                        const x = nodeX(n), y = nodeY(n), w = nodeW(n), h = nodeH(n);
                                        el.style.cssText = `left:${x}px;top:${y}px;width:${w}px;height:${h}px`;
                                        el.id = n.id;
                                        if (tipo === 'nota') {
                                            const themes = {pink:'rosa', green:'verde', blue:'azul', purple:'roxo', yellow:'amarelo'};
                                            el.dataset.theme = themes[n.cor] || n.cor || 'amarelo';
                                        }

                                        const sid = tipo === 'terminal' ? terminalSessionID(n) : null;
                                        const sInfo = sid ? (sessionStatesMap[sid] || {}) : {};
                                        const sEstado = sInfo.estado || (sid ? 'viva' : 'morta');
                                        const stateLabels = {rodando:'rodando', iniciando:'iniciando', esperandoHumano:'aguardando', aprovacaoPendente:'aprovação', ociosa:'ociosa', encerrada:'encerrada', morta:'morta', viva:'viva'};
                                        const stateColors = {rodando:'#22c55e', iniciando:'#14b8a6', esperandoHumano:'#f59e0b', aprovacaoPendente:'#ef4444', ociosa:'#8b8b92', encerrada:'#73737b', morta:'#73737b', viva:'#eab308'};
                                         
                                        let head = `<div class="node-head">`;
                                        if (tipo === 'terminal') {
                                            head += `<span style="color:#8b8b92;font-size:9px">⌨</span>`;
                                        }
                                        head += `<span class="node-label">${esc(tipo === 'nota' ? (n.arquivo || 'nota').split('/').pop() : nodeLabel(n))}</span>`;
                                        if (tipo === 'terminal') {
                                            if (n.papel) head += `<span class="node-tag">${esc(n.papel)}</span>`;
                                            const viewers = remoteViewersForNode(n.id);
                                            if (viewers.length) {
                                                head += `<span class="viewer-pills" title="${esc(viewers.map(v => v.name).join(', '))} usando">`;
                                                viewers.slice(0,3).forEach(v => {
                                                    head += `<span class="viewer-pill" style="background:${memberCursorColor(v.id)}" title="${esc(v.name)}">${esc((v.name||'?').slice(0,1).toUpperCase())}</span>`;
                                                });
                                                head += `</span>`;
                                            }
                                            head += `<span class="node-state"><span class="status-dot ${sEstado === 'rodando' ? 'pulsing' : ''}" style="background:${stateColors[sEstado] || '#73737b'}"></span>${esc(stateLabels[sEstado] || sEstado)}</span>`;
                                        } else if (tipo === 'nota') {
                                            const currentTheme = el.dataset.theme;
                                            head += `<span class="note-swatches"><i class="note-swatch ${currentTheme === 'amarelo' ? 'selected' : ''}" data-theme="amarelo" title="Amarelo" style="background:#ffeb99"></i><i class="note-swatch ${currentTheme === 'rosa' ? 'selected' : ''}" data-theme="rosa" title="Rosa" style="background:#ffc7d9"></i><i class="note-swatch ${currentTheme === 'verde' ? 'selected' : ''}" data-theme="verde" title="Verde" style="background:#c7f0bf"></i><i class="note-swatch ${currentTheme === 'azul' ? 'selected' : ''}" data-theme="azul" title="Azul" style="background:#bddeff"></i><i class="note-swatch ${currentTheme === 'roxo' ? 'selected' : ''}" data-theme="roxo" title="Roxo" style="background:#deccff"></i></span>`;
                                        }
                                        head += `</div>`;
                                        
                                        let body = '';
                                        if (tipo === 'terminal') {
                                            const outputKey = sid || '';
                                            const outputEntries = sessionOutputsMap[outputKey] || [];
                                            const outputText = outputEntries.map(e => e.text).join('');
                                            const cwdShow = n.cwd || '~';
                                            if (xtermAvailable && sid) {
                                                body = `<div class="terminal-screen xterm-host" data-native-scroll></div>`;
                                            } else {
                                                body = `<div class="terminal-screen" data-native-scroll><div class="term-body"><span class="out">${esc(cwdShow)} % </span></div><div class="term-output">`;
                                                if (outputText) body += esc(cleanTerminalOutput(outputText)).replace(/\\n/g, '<br>');
                                                body += '</div>';
                                                if (sid && !['encerrada','morta'].includes(sEstado)) {
                                                    body += `<label class="terminal-command"><span>%</span><input autocomplete="off" spellcheck="false" aria-label="Entrada do terminal"></label>`;
                                                }
                                                body += '</div>';
                                            }
                                            const relaunch = ['encerrada','morta'].includes(sEstado) ? `<button class="relaunch-terminal" onclick="event.stopPropagation();relaunchTerminal('${n.id}')">${n.launching ? 'Relançando…' : 'Relançar'}</button>` : '';
                                            const fallback = !xtermAvailable ? '<span class="terminal-fallback-badge">modo simplificado</span>' : '';
                                            body += `<div class="term-footer"><span>${esc(cwdShow)}</span><span>${fallback} ${relaunch} &nbsp;${esc(n.adapter || 'shell')} &nbsp;⌘</span></div>`;
                                            body += `<div class="fallback-card"><strong>${esc(n.nome || 'Terminal')}</strong><br><span style="color:${stateColors[sEstado] || '#73737b'}">● ${esc(stateLabels[sEstado] || sEstado)}</span></div>`;
                                        } else if (tipo === 'nota') {
                                            const ultimaFonte = n.ultima_fonte ? esc(n.ultima_fonte) : 'sem alterações';
                                            body = `<div class="note-body"><div class="note-content">`;
                                            const hasContent = Object.prototype.hasOwnProperty.call(noteContentsMap, n.id);
                                            const nc = noteContentsMap[n.id] || '';
                                            if (hasContent) {
                                                body += renderMarkdown(nc);
                                            } else {
                                                body += '<div class="carregando">carregando conteúdo...</div>';
                                            }
                                            body += `</div></div><div class="note-footer"><span>${ultimaFonte}</span><span>duplo clique para editar</span></div>`;
                                        } else if (tipo === 'desenho') {
                                            const tracos = n.tracos || [];
                                            const dw = nodeW(n), dh = nodeH(n);
                                            body = '<div style="padding:4px;background:#0d0f13;border-radius:0 0 10px 10px;overflow:hidden">';
                                            body += '<svg class="desenho-canvas" viewBox="0 0 ' + dw + ' ' + dh + '" style="width:100%;height:' + Math.max(100, dh * 0.4) + 'px;display:block">';
                                            tracos.forEach(t => {
                                                const pts = t.pontos || [];
                                                if (t.tipo === 'livre' || t.tipo === 'seta') {
                                                    if (pts.length < 2) return;
                                                    const d = pts.map((p, i) => (i === 0 ? 'M' : 'L') + ' ' + p.x + ' ' + p.y).join(' ');
                                                    body += '<path d="' + d + '" stroke="' + (t.cor || '#38bdf8') + '" stroke-width="' + (t.espessura || 2) + '" fill="none" stroke-linecap="round" stroke-linejoin="round"/>';
                                                } else if (t.tipo === 'retangulo' && pts.length >= 2) {
                                                    const x = Math.min(pts[0].x, pts[1].x), y = Math.min(pts[0].y, pts[1].y);
                                                    const rw = Math.abs(pts[1].x - pts[0].x), rh = Math.abs(pts[1].y - pts[0].y);
                                                    body += '<rect x="' + x + '" y="' + y + '" width="' + rw + '" height="' + rh + '" stroke="' + (t.cor || '#38bdf8') + '" stroke-width="' + (t.espessura || 2) + '" fill="none"/>';
                                                } else if (t.tipo === 'elipse' && pts.length >= 2) {
                                                    const cx = (pts[0].x + pts[1].x)/2, cy = (pts[0].y + pts[1].y)/2;
                                                    const rx = Math.abs(pts[1].x - pts[0].x)/2, ry = Math.abs(pts[1].y - pts[0].y)/2;
                                                    body += '<ellipse cx="' + cx + '" cy="' + cy + '" rx="' + rx + '" ry="' + ry + '" stroke="' + (t.cor || '#38bdf8') + '" stroke-width="' + (t.espessura || 2) + '" fill="none"/>';
                                                } else if (t.tipo === 'texto') {
                                                    const p = pts[0] || {x:10, y:20};
                                                    body += '<text x="' + p.x + '" y="' + p.y + '" fill="' + (t.cor || '#38bdf8') + '" font-size="' + (t.espessura * 6 || 14) + '" font-family="system-ui">' + esc(t.texto || '') + '</text>';
                                                }
                                            });
                                            body += '</svg></div>';
                                         } else if (tipo === 'portal') {
                                             const portalURL = safePortalURL(n.url);
                                             const portalTitle = n.titulo || 'Navegador';
                                             body = `<div class="portal-body"><span class="portal-icon">◉</span><div class="portal-meta"><strong class="portal-title">${esc(portalTitle)}</strong><span class="portal-url">${esc(n.url || 'sem URL')}</span>`;
                                             if (portalURL) {
                                                 body += `<a class="portal-open" href="${attrEsc(portalURL)}" target="_blank" rel="noopener noreferrer" referrerpolicy="no-referrer">Abrir ↗</a>`;
                                             } else {
                                                 body += '<span class="portal-invalid">URL não disponível para abertura remota</span>';
                                             }
                                             body += '</div></div>';
                                         }
                                        el.innerHTML = head + body;
                                        const terminalInput = el.querySelector('.terminal-command input');
                                        if (terminalInput) {
                                            terminalInput.addEventListener('keydown', async e => {
                                                if (e.key !== 'Enter' || !terminalInput.value) return;
                                                e.preventDefault();
                                                const command = terminalInput.value;
                                                terminalInput.disabled = true;
                                                try {
                                                    const bytes = new TextEncoder().encode(command + String.fromCharCode(10));
                                                    let binary = ''; bytes.forEach(b => binary += String.fromCharCode(b));
                                                    await rpc('session.input', { session_id: sid, data_b64: btoa(binary) });
                                                    terminalInput.value = '';
                                                } catch (error) {
                                                    alert('Terminal somente leitura: ' + friendlyError(error.message));
                                                } finally {
                                                    terminalInput.disabled = false;
                                                    terminalInput.focus();
                                                }
                                            });
                                        }
                                        if (tipo === 'nota') {
                                            el.querySelectorAll('.note-swatch').forEach(swatch => {
                                                swatch.addEventListener('click', async e => {
                                                    e.stopPropagation();
                                                    const oldColor = n.cor;
                                                    n.cor = swatch.dataset.theme;
                                                    renderAllNodes(activeNodes);
                                                    try {
                                                        await applyDocumentOp('node.update', { id:n.id, campos:{ cor:n.cor } });
                                                    } catch (error) {
                                                        n.cor = oldColor;
                                                        renderAllNodes(activeNodes);
                                                        alert('Não foi possível mudar a cor: ' + friendlyError(error.message));
                                                    }
                                                });
                                            });
                                            el.querySelector('.note-body').addEventListener('dblclick', e => {
                                                if (e.target.closest('.note-checkbox')) return;
                                                e.stopPropagation();
                                                beginNoteEdit(n, el);
                                            });
                                        }

                                        let dx, dy, dragging = false;
                                        el.addEventListener('mousedown', e => {
                                            if(e.target.closest('.term-body,.xterm-host,.xterm,.note-body,.portal-body,.note-swatch')) return;
                                            if (connectionMode) {
                                                e.preventDefault();
                                                e.stopPropagation();
                                                selectConnectionNode(n);
                                                return;
                                            }
                                             nodes.forEach(no => no.selected = false);
                                             n.selected = true;
                                             schedulePresence(true);
                                            renderAllNodes(nodes);
                                            const nEl = document.getElementById(n.id);
                                            if(nEl) {
                                                dragging = true;
                                                dx = e.clientX / scale - nodeX(n);
                                                dy = e.clientY / scale - nodeY(n);
                                                const moveHandler = e => {
                                                    if(!dragging) return;
                                                    if(n.posicao) { n.posicao.x = e.clientX / scale - dx; n.posicao.y = e.clientY / scale - dy; }
                                                    else { n.x = e.clientX / scale - dx; n.y = e.clientY / scale - dy; }
                                                    nEl.style.left = nodeX(n) + 'px'; nEl.style.top = nodeY(n) + 'px';
                                                    renderConnections(canvasMode === 'atencao' ? [] : activeConns, renderedNodes);
                                                    updateMinimap();
                                                };
                                                const upHandler = async () => {
                                                    dragging = false;
                                                    window.removeEventListener('mousemove', moveHandler);
                                                    window.removeEventListener('mouseup', upHandler);
                                                    try {
                                                        await applyDocumentOp('node.move', {
                                                            id: n.id,
                                                            posicao: { x: nodeX(n), y: nodeY(n) }
                                                        });
                                                    } catch (error) {
                                                        console.error('node.move failed', error);
                                                        requestSnapshot();
                                                    }
                                                };
                                                window.addEventListener('mousemove', moveHandler);
                                                window.addEventListener('mouseup', upHandler);
                                            }
                                            e.stopPropagation();
                                        });
                                        c.appendChild(el);
                                        if (tipo === 'terminal' && sid && xtermAvailable) {
                                            mountWebTerminal(n, sid, sEstado, el.querySelector('.terminal-screen'));
                                        }
                                    });
                                    const terminalNodeIDs = new Set(nodes.filter(n => nodeTipo(n) === 'terminal').map(n => n.id));
                                    for (const [nodeID, controller] of terminalControllers) {
                                        if (!terminalNodeIDs.has(nodeID)) {
                                            disposeTerminalController(controller);
                                            terminalControllers.delete(nodeID);
                                        }
                                    }
                                    renderConnections(canvasMode === 'atencao' ? [] : activeConns, renderedNodes);
                                    updateMinimap();
                                    if (!hasFittedCanvas && renderedNodes.length) requestAnimationFrame(fitCanvasToNodes);
                                }
                                function esc(s) { return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

                                function cleanTerminalOutput(input) {
                                    const text = String(input || '');
                                    let out = '';
                                    for (let i = 0; i < text.length; i++) {
                                        const code = text.charCodeAt(i);
                                        if (code === 0xfffd) continue;
                                        if (code === 27) {
                                            const next = text[i + 1];
                                            if (next === '[') {
                                                i += 2;
                                                while (i < text.length && !(text.charCodeAt(i) >= 64 && text.charCodeAt(i) <= 126)) i++;
                                            } else if (next === ']') {
                                                i += 2;
                                                while (i < text.length && text.charCodeAt(i) !== 7) i++;
                                            } else {
                                                i++;
                                            }
                                            continue;
                                        }
                                        if (text[i] === '[' && (text[i + 1] === '?' || /[0-9KHJm]/.test(text[i + 1] || ''))) {
                                            let j = i + 1;
                                            while (j < text.length && !(text.charCodeAt(j) >= 64 && text.charCodeAt(j) <= 126)) j++;
                                            if (j < text.length) { i = j; continue; }
                                        }
                                        if (code === 13) continue;
                                        if (code === 8) { out = out.slice(0, -1); continue; }
                                        if (code < 32 && code !== 10 && code !== 9) continue;
                                        out += text[i];
                                    }
                                    return out;
                                }

                                function renderConnections(conns, nodes) {
                                    const svg = document.getElementById('connLayer');
                                    svg.innerHTML = `<defs>
                                        <marker id="arrowhead" markerWidth="10" markerHeight="10" refX="8" refY="5" orient="auto">
                                            <path d="M 0 1 L 8 5 L 0 9" fill="none" stroke="context-stroke" stroke-width="2"/>
                                        </marker>
                                    </defs>`;
                                    function borderPoint(node, target) {
                                        const cx = nodeX(node) + nodeW(node) / 2, cy = nodeY(node) + nodeH(node) / 2;
                                        const dx = target.x - cx, dy = target.y - cy;
                                        const tx = dx ? (nodeW(node) / 2) / Math.abs(dx) : Infinity;
                                        const ty = dy ? (nodeH(node) / 2) / Math.abs(dy) : Infinity;
                                        const t = Math.min(tx, ty);
                                        return {x:cx + dx * t, y:cy + dy * t};
                                    }
                                    conns.forEach(c => {
                                        const fromN = nodes.find(n => n.id === (c.de || c.from));
                                        const toN = nodes.find(n => n.id === (c.para || c.to));
                                        if(!fromN || !toN) return;
                                        const fromCenter = {x:nodeX(fromN)+nodeW(fromN)/2, y:nodeY(fromN)+nodeH(fromN)/2};
                                        const toCenter = {x:nodeX(toN)+nodeW(toN)/2, y:nodeY(toN)+nodeH(toN)/2};
                                        const p1 = borderPoint(fromN, toCenter), p2 = borderPoint(toN, fromCenter);
                                        const vx = p2.x-p1.x, vy = p2.y-p1.y, dist = Math.max(1, Math.hypot(vx,vy));
                                        const sag = Math.min(22, dist*.07), nx = -vy/dist, ny = vx/dist;
                                        const c1 = {x:p1.x+vx*.34+nx*sag, y:p1.y+vy*.34+ny*sag};
                                        const c2 = {x:p1.x+vx*.68+nx*sag, y:p1.y+vy*.68+ny*sag};
                                        const dPath = `M ${p1.x} ${p1.y} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${p2.x} ${p2.y}`;
                                        const estilo = c.estilo || 'solida';
                                        const cor = c.semantica ? (c.semantica === 'conversa' ? '#3b82f6' : c.semantica === 'escrita-de-nota' ? '#f97316' : '#8b8b92') : (c.color || '#3b82f6');
                                        const dash = estilo === 'tracejada' ? '6 5' : '';
                                         
                                        const halo = document.createElementNS('http://www.w3.org/2000/svg', 'path');
                                        halo.setAttribute('d', dPath);
                                        halo.setAttribute('class', 'conn-halo');
                                        halo.setAttribute('stroke', cor);
                                        if (dash) halo.setAttribute('stroke-dasharray', dash);
                                        svg.appendChild(halo);
                                        
                                        const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
                                        path.setAttribute('d', dPath);
                                        path.setAttribute('class', 'conn-line' + (c.id === selectedConnectionID ? ' selected' : ''));
                                        path.setAttribute('stroke', cor);
                                        path.setAttribute('fill', 'none');
                                        path.setAttribute('stroke-width', '2');
                                        path.setAttribute('marker-end', 'url(#arrowhead)');
                                        if (dash) path.setAttribute('stroke-dasharray', dash);
                                        svg.appendChild(path);

                                        const hit = document.createElementNS('http://www.w3.org/2000/svg', 'path');
                                        hit.setAttribute('d', dPath);
                                        hit.setAttribute('class', 'conn-hit');
                                        hit.addEventListener('click', e => { e.stopPropagation(); selectConnection(c.id); });
                                        svg.appendChild(hit);
                                    });
                                }

                                function updateMinimap() {
                                    const mc = document.getElementById('minimapCanvas');
                                    const vp = document.getElementById('minimapViewport');
                                    const mmW = mc.clientWidth || 180, mmH = mc.clientHeight || 98;
                                    const rect = wrap.getBoundingClientRect();
                                    const viewX = -panX/scale, viewY = -panY/scale, viewW = rect.width/scale, viewH = rect.height/scale;
                                    const mapNodes = renderedNodes.length ? renderedNodes : activeNodes;
                                    const xs = mapNodes.flatMap(n => [nodeX(n), nodeX(n)+nodeW(n)]).concat([viewX,viewX+viewW]);
                                    const ys = mapNodes.flatMap(n => [nodeY(n), nodeY(n)+nodeH(n)]).concat([viewY,viewY+viewH]);
                                    const minX = Math.min(...xs)-200, minY = Math.min(...ys)-200, maxX = Math.max(...xs)+200, maxY = Math.max(...ys)+200;
                                    const mapScale = Math.min((mmW-12)/(maxX-minX), (mmH-12)/(maxY-minY));
                                    const ox = (mmW-(maxX-minX)*mapScale)/2, oy = (mmH-(maxY-minY)*mapScale)/2;
                                    mc.querySelectorAll('.minimap-node,.minimap-lines').forEach(e => e.remove());
                                    const miniSvg = document.createElementNS('http://www.w3.org/2000/svg','svg');
                                    miniSvg.setAttribute('class','minimap-lines');
                                    miniSvg.setAttribute('width',mmW); miniSvg.setAttribute('height',mmH);
                                    miniSvg.style.cssText='position:absolute;inset:0';
                                    (canvasMode === 'atencao' ? [] : activeConns).forEach(c => {
                                        const a=mapNodes.find(n=>n.id===(c.de||c.from)), b=mapNodes.find(n=>n.id===(c.para||c.to));
                                        if(!a||!b)return;
                                        const line=document.createElementNS('http://www.w3.org/2000/svg','line');
                                        line.setAttribute('x1',ox+(nodeX(a)+nodeW(a)/2-minX)*mapScale); line.setAttribute('y1',oy+(nodeY(a)+nodeH(a)/2-minY)*mapScale);
                                        line.setAttribute('x2',ox+(nodeX(b)+nodeW(b)/2-minX)*mapScale); line.setAttribute('y2',oy+(nodeY(b)+nodeH(b)/2-minY)*mapScale);
                                        line.setAttribute('stroke','rgba(161,161,170,.3)'); line.setAttribute('stroke-width','.7'); miniSvg.appendChild(line);
                                    });
                                    mc.insertBefore(miniSvg, vp);
                                    mapNodes.forEach(n => {
                                        const d = document.createElement('div');
                                        d.className = 'minimap-node';
                                        const sessionID = terminalSessionID(n);
                                        const state = sessionID ? (sessionStatesMap[sessionID]||{}).estado : '';
                                        const color = nodeTipo(n)==='terminal' ? ({rodando:'#22c55e',iniciando:'#14b8a6',esperandoHumano:'#f59e0b',aprovacaoPendente:'#ef4444'}[state]||'#8b8b92') : '#8b8b92';
                                        d.style.cssText = `left:${ox+(nodeX(n)-minX)*mapScale}px;top:${oy+(nodeY(n)-minY)*mapScale}px;width:${Math.max(2,nodeW(n)*mapScale)}px;height:${Math.max(2,nodeH(n)*mapScale)}px;background:${color}`;
                                        mc.appendChild(d);
                                    });
                                    vp.style.left = ox+(viewX-minX)*mapScale + 'px';
                                    vp.style.top = oy+(viewY-minY)*mapScale + 'px';
                                    vp.style.width = viewW*mapScale + 'px';
                                    vp.style.height = viewH*mapScale + 'px';
                                }

                                function noteColorForAuthor(authorID) {
                                    const palette = ['amarelo','rosa','verde','azul','roxo'];
                                    let hash = 0;
                                    for (const ch of (authorID || 'anon')) hash = ((hash * 31) + ch.charCodeAt(0)) >>> 0;
                                    return palette[hash % palette.length];
                                }

                                function openInApp() {
                                    if (!INVITE_ROOM || !INVITE_TOKEN) {
                                        alert('Convite ainda não carregado.');
                                        return;
                                    }
                                    const selected = selectedNodeID();
                                    let url = 'colmeia://join/' + INVITE_ROOM + '/' + INVITE_TOKEN;
                                    if (selected) url += '?node=' + encodeURIComponent(selected);
                                    const btn = document.getElementById('appLink');
                                    if (btn) btn.dataset.url = url;
                                    window.location.href = url;
                                }

                                function remoteViewersForNode(nodeID) {
                                    const out = [];
                                    for (const presence of remotePresences.values()) {
                                        if (!presence.connected || presence.member_id === browserAuthor) continue;
                                        if (presence.selected_node_id === nodeID) {
                                            out.push({
                                                id: presence.member_id,
                                                name: presence.display_name || memberNames[presence.member_id] || presence.member_id
                                            });
                                        }
                                    }
                                    return out;
                                }

                                async function addNode(type) {
                                    const id = newULID();
                                    const pos = { x: 250 + Math.random() * 200, y: 150 + Math.random() * 200 };
                                    const tam = { w: 360, h: 260 };
                                     let node;
                                     if(type === 'terminal') {
                                         const existingNames = new Set(activeNodes.map(n => n.nome));
                                         let index = activeNodes.filter(n => nodeTipo(n) === 'terminal').length + 1;
                                         let terminalName = 'Terminal ' + index;
                                         while (existingNames.has(terminalName)) terminalName = 'Terminal ' + (++index);
                                         node = {
                                             id, tipo:'terminal', nome:terminalName, posicao:pos,
                                            tamanho:tam, adapter:'shell', cwd:'~', z:activeNodes.length,
                                            criado_em:new Date().toISOString(), monitorar_atividade:true
                                        };
                                     } else if(type === 'note') {
                                         node = {
                                             id, tipo:'nota', posicao:pos, tamanho:{w:320,h:240},
                                             cor: noteColorForAuthor(browserAuthor), arquivo:'notes/' + id + '.md',
                                             z:activeNodes.length, criado_em:new Date().toISOString()
                                         };
                                         noteContentsMap[id] = '';
                                     } else if (type === 'portal') {
                                         node = {
                                             id, tipo:'portal', posicao:pos, tamanho:{w:420,h:220},
                                             url:'https://duckduckgo.com/', titulo:'DuckDuckGo',
                                             z:activeNodes.length, criado_em:new Date().toISOString()
                                         };
                                     }
                                    if (!node) return;
                                    activeNodes.push(node);
                                    renderAllNodes(activeNodes);
                                    try {
                                        await applyDocumentOp('node.add', { node });
                                         if (type === 'note') {
                                             await rpc('note.replace', { workspace_id: workspaceID, node_id: id, conteudo: '' });
                                         } else if (type === 'terminal') {
                                             await relaunchTerminal(id);
                                         }
                                    } catch (error) {
                                        console.error('node.add failed', error);
                                        activeNodes = activeNodes.filter(n => n.id !== id);
                                        renderAllNodes(activeNodes);
                                    }
                                }

                                 async function loadCanvas(wsid) {
                                    try {
                                        const result = await rpc('workspace.open', { id: wsid });
                                        const snap = result.document_snapshot;
                                        if (snap) {
                                            activeNodes = snap.nodes || [];
                                            activeConns = snap.connections || [];
                                            workspaceSeq = snap.seq || 0;
                                            noteContentsMap = snap.note_contents || {};
                                            const ssList = snap.session_states || [];
                                                             indexSessionStates(ssList);
                                                             sessionOutputsMap = snap.session_outputs || {};
                                                             watchdogConfiguration = snap.watchdog_configuration || null;
                                                             watchdogAlerts = snap.watchdog_history || [];
                                                             renderWatchdog();
                                                             renderAllNodes(activeNodes);
                                            for (const n of activeNodes) {
                                                if (nodeTipo(n) === 'nota') {
                                                    fetchNoteContent(wsid, n);
                                                }
                                            }
                                        }
                                        setConnectionStatus('live');
                                    } catch (err) {
                                        console.warn('loadCanvas error:', err);
                                        setConnectionStatus('disconnected');
                                    }
                                }
                                
                                async function fetchNoteContent(wsid, n) {
                                    if (Object.prototype.hasOwnProperty.call(noteContentsMap, n.id)) {
                                        const conteudo = noteContentsMap[n.id] || '';
                                        const el = document.getElementById(n.id);
                                        if (el) renderNoteContent(el, conteudo);
                                        return;
                                    }
                                    try {
                                        const rec = await rpc('note.get', { workspace_id: wsid, node_id: n.id });
                                        const el = document.getElementById(n.id);
                                        noteContentsMap[n.id] = rec.conteudo || '';
                                        if (el) renderNoteContent(el, noteContentsMap[n.id]);
                                    } catch (err) {
                                        console.warn('note.get error for', n.id, err);
                                    }
                                }

                                function renderNoteContent(el, md) {
                                    let body = el.querySelector('.note-content');
                                    if (!body) return;
                                    body.innerHTML = renderMarkdown(md);
                                }

                                function beginNoteEdit(node, el) {
                                    const body = el.querySelector('.note-body');
                                    if (!body || body.querySelector('textarea')) return;
                                    const textarea = document.createElement('textarea');
                                    textarea.className = 'note-editor';
                                    textarea.value = noteContentsMap[node.id] || '';
                                    body.innerHTML = '';
                                    body.classList.add('editing');
                                    body.appendChild(textarea);
                                    const actions = document.createElement('div');
                                    actions.className = 'note-editor-actions';
                                    actions.innerHTML = '<button type="button" class="cancel">Cancelar</button><button type="button" class="save">Salvar</button>';
                                    body.appendChild(actions);
                                    textarea.focus();
                                    textarea.setSelectionRange(textarea.value.length, textarea.value.length);
                                    let saved = false;
                                    const save = async () => {
                                        if (saved) return;
                                        saved = true;
                                        const conteudo = textarea.value;
                                        try {
                                            const rec = await rpc('note.replace', { workspace_id: workspaceID, node_id: node.id, conteudo });
                                            noteContentsMap[node.id] = rec.conteudo !== undefined ? rec.conteudo : conteudo;
                                        } catch (error) {
                                            saved = false;
                                            alert('Não foi possível salvar a nota: ' + friendlyError(error.message));
                                            textarea.focus();
                                            return;
                                        }
                                        renderAllNodes(activeNodes);
                                    };
                                    textarea.addEventListener('blur', save);
                                    actions.querySelectorAll('button').forEach(button => button.addEventListener('mousedown', e => e.preventDefault()));
                                    actions.querySelector('.save').addEventListener('click', save);
                                    actions.querySelector('.cancel').addEventListener('click', () => { saved = true; renderAllNodes(activeNodes); });
                                    textarea.addEventListener('keydown', e => {
                                        if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { e.preventDefault(); textarea.blur(); }
                                        if (e.key === 'Escape') { saved = true; renderAllNodes(activeNodes); }
                                    });
                                }

                                function authorText(author) {
                                    if (!author) return 'desconhecido';
                                    const raw = typeof author === 'string' ? author : (author.raw_value || author.rawValue || author.id || JSON.stringify(author));
                                    return memberNames[raw] || raw;
                                }

                                async function editUserName() {
                                    const current = memberNames[browserAuthor] || '';
                                    const displayName = prompt('Como você quer aparecer nesta sala?', current);
                                    if (!displayName || !displayName.trim()) return;
                                    try {
                                        const result = await rpc('member.update', {
                                            room_id:INVITE_ROOM, member_id:browserAuthor,
                                            display_name:displayName.trim()
                                        });
                                        if (result.member) {
                                            memberNames[browserAuthor] = result.member.display_name;
                                            document.querySelector('#userNameButton .action-label').textContent = result.member.display_name;
                                            const members = await rpc('member.list', { room_id:INVITE_ROOM, status:'active' });
                                            renderMemberPills(members);
                                        }
                                    } catch (error) {
                                        alert('Não foi possível alterar o nome: ' + friendlyError(error.message));
                                    }
                                }

                                function addChatEvent(event) {
                                    if (!event || event.kind !== 'message_sent' || !event.payload || !event.payload.texto) return;
                                    if (roomEvents.some(e => e.id === event.id)) return;
                                    roomEvents.push(event);
                                    roomEvents.sort((a,b) => (a.logical_clock || 0) - (b.logical_clock || 0));
                                    renderChatEvents();
                                }

                                function renderChatEvents() {
                                    const c = document.getElementById('chatMessages');
                                    const messages = roomEvents.filter(e => e.kind === 'message_sent' && e.payload && e.payload.texto);
                                    if (!messages.length) {
                                        c.innerHTML = '<div style="text-align:center;color:#64748b;font-size:12px;margin-top:20px">Nenhuma mensagem ainda.</div>';
                                        return;
                                    }
                                    c.innerHTML = messages.map(event => {
                                        const author = authorText(event.author);
                                        const mine = author === browserAuthor || author.endsWith(browserAuthor.replace('humano:',''));
                                        const date = event.created_at ? new Date(event.created_at) : new Date();
                                        const time = date.toLocaleTimeString('pt-BR',{hour:'2-digit',minute:'2-digit'});
                                        return `<div class="msg ${mine ? 'me' : 'other'}">${mine ? '' : `<div class="author">${esc(author)}</div>`}${esc(event.payload.texto)}<div class="msg-meta">${time} <span>✓</span></div></div>`;
                                    }).join('');
                                    c.scrollTop = c.scrollHeight;
                                }

                                async function ensureChatSession() {
                                    if (roomAgentSessions.length) return roomAgentSessions[0].id;
                                    if (!workspaceID) throw new Error('workspace indisponível');
                                    const nodeID = activeNodes.length ? activeNodes[0].id : newULID();
                                    const result = await rpc('agent_session.create', {
                                        room_id: INVITE_ROOM, workspace_id: workspaceID,
                                        node_id: nodeID, objective: 'Chat da sala'
                                    });
                                    if (!result.agent_session) throw new Error('não foi possível criar a conversa');
                                    roomAgentSessions.push(result.agent_session);
                                    return result.agent_session.id;
                                }

                                function escHtml(s) {
                                    return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
                                }

                                function renderMarkdown(text) {
                                    if (!text) return '';
                                    let s = String(text);
                                    let html = '';
                                    let lines = s.split('\\n');
                                    let inCode = false, codeBuf = [], codeLang = '';
                                    for (let i = 0; i < lines.length; i++) {
                                        let line = lines[i];
                                        let isCodeFence = line.startsWith('```');
                                        if (isCodeFence) {
                                            if (inCode) {
                                                html += '<pre><code>' + escHtml(codeBuf.join('\\n')) + '</code></pre>';
                                                codeBuf = []; inCode = false;
                                            } else {
                                                inCode = true;
                                                codeLang = line.slice(3).trim();
                                            }
                                            continue;
                                        }
                                        if (inCode) { codeBuf.push(line); continue; }
                                        if (line.trim() === '') { html += '<br>'; continue; }
                                        if (line.startsWith('### ')) {
                                            html += '<h3 style="margin:8px 0 4px;font-size:14px;font-weight:700">' + escHtml(line.slice(4)) + '</h3>';
                                            continue;
                                        }
                                        if (line.startsWith('## ')) {
                                            html += '<h2 style="margin:8px 0 4px;font-size:16px;font-weight:700">' + escHtml(line.slice(3)) + '</h2>';
                                            continue;
                                        }
                                        if (line.startsWith('# ')) {
                                            html += '<h1 style="margin:8px 0 4px;font-size:18px;font-weight:800">' + escHtml(line.slice(2)) + '</h1>';
                                            continue;
                                        }
                                        if (line.startsWith('- [x] ') || line.startsWith('- [X] ')) {
                                            html += '<label style="display:block;font-size:12px;margin:2px 0;color:rgba(0,0,0,0.66)"><input type="checkbox" class="note-checkbox" data-line="' + i + '" checked> ' + escHtml(line.slice(6)) + '</label>';
                                            continue;
                                        }
                                        if (line.startsWith('- [ ] ')) {
                                            html += '<label style="display:block;font-size:12px;margin:2px 0;color:rgba(0,0,0,0.66)"><input type="checkbox" class="note-checkbox" data-line="' + i + '"> ' + escHtml(line.slice(6)) + '</label>';
                                            continue;
                                        }
                                        if (line.startsWith('- ') || line.startsWith('* ')) {
                                            html += '<li style="font-size:12px;margin:1px 0;color:rgba(0,0,0,0.66)">' + escHtml(line.slice(2)) + '</li>';
                                            continue;
                                        }
                                        if (line.startsWith('> ')) {
                                            html += '<blockquote style="border-left:3px solid #cbd5e1;margin:4px 0;padding:2px 8px;font-size:12px;color:#64748b">' + escHtml(line.slice(2)) + '</blockquote>';
                                            continue;
                                        }
                                        let inline = escHtml(line);
                                        inline = inline.replace(/`([^`]+)`/g, '<code style="background:#e2e8f0;padding:1px 4px;border-radius:3px;font-size:11px">$1</code>');
                                        inline = inline.replace(/\\*\\*([^*]+)\\*\\*/g, '<strong>$1</strong>');
                                        inline = inline.replace(/\\*([^*]+)\\*/g, '<em>$1</em>');
                                        inline = inline.replace(/~~([^~]+)~~/g, '<del>$1</del>');
                                        html += '<div style="padding:1px 0;font-size:12px;line-height:1.5;color:rgba(0,0,0,0.76)">' + inline + '</div>';
                                    }
                                    return html;
                                }

                                async function toggleNoteCheckbox(input) {
                                    const noteElement = input.closest('.node-note');
                                    const nodeID = noteElement && noteElement.id;
                                    const lineIndex = Number(input.dataset.line);
                                    if (!nodeID || !Number.isSafeInteger(lineIndex) || lineIndex < 0) return;
                                    const original = noteContentsMap[nodeID];
                                    if (typeof original !== 'string') return;
                                    const lines = original.split('\\n');
                                    const line = lines[lineIndex];
                                    const match = line && line.match(/^(- \\[)([ xX])(\\] )/);
                                    if (!match) { renderNoteContent(noteElement, original); return; }
                                    const stateOffset = match[1].length;
                                    lines[lineIndex] = line.slice(0, stateOffset) + (input.checked ? 'x' : ' ') + line.slice(stateOffset + 1);
                                    const conteudo = lines.join('\\n');
                                    input.disabled = true;
                                    try {
                                        const rec = await rpc('note.replace', { workspace_id:workspaceID, node_id:nodeID, conteudo });
                                        noteContentsMap[nodeID] = rec.conteudo !== undefined ? rec.conteudo : conteudo;
                                        const current = document.getElementById(nodeID);
                                        if (current) renderNoteContent(current, noteContentsMap[nodeID]);
                                    } catch (error) {
                                        const current = document.getElementById(nodeID);
                                        if (current) renderNoteContent(current, original);
                                        alert('Não foi possível atualizar a tarefa: ' + friendlyError(error.message));
                                    }
                                }

                                document.getElementById('nodesContainer').addEventListener('change', event => {
                                    const input = event.target.closest('.note-checkbox');
                                    if (input) toggleNoteCheckbox(input);
                                });

                                function toggleChat() {
                                    document.getElementById('chatPanel').classList.toggle('open');
                                }

                                function toggleWatchdog() {
                                    document.getElementById('watchdogPanel').classList.toggle('open');
                                }

                                function renderWatchdog() {
                                    const target = document.getElementById('watchdogContent');
                                    const policy = watchdogConfiguration && watchdogConfiguration.workspacePolicy;
                                    if (!policy) {
                                        target.textContent = 'Aguardando dados do Engine...';
                                        return;
                                    }
                                    const status = policy.enabled ? 'Ativo' : 'Desativado';
                                    document.getElementById('watchdogButton').style.color = policy.enabled ? '#fcd34d' : '';
                                    target.innerHTML = `<div style="color:#f1f5f9;font-weight:700">${status}</div>
                                        <div class="watchdog-grid">
                                            <div class="watchdog-stat">Sem atividade<strong>${Math.round(policy.staleAfter / 60)} min</strong></div>
                                            <div class="watchdog-stat">Intervalo<strong>${Math.round(policy.nudgeInterval / 60)} min</strong></div>
                                            <div class="watchdog-stat">Avisos por episódio<strong>${policy.maxNudgesPerEpisode}</strong></div>
                                            <div class="watchdog-stat">Exceções<strong>${Object.keys(watchdogConfiguration.sessionOverrides || {}).length}</strong></div>
                                        </div>` + watchdogAlerts.slice(-5).reverse().map(a =>
                                            `<div class="watchdog-alert"><strong>${esc(a.kind || 'aviso')}</strong><br>${esc(a.message || '')}</div>`
                                        ).join('');
                                }

                                /* --- State Machine: loading → authenticating → joining → snapshot → ready / error --- */
                                const inviteParts = location.pathname.split('/').filter(Boolean);
                                const joinIndex = inviteParts.indexOf('join');
                                const INVITE_ROOM = joinIndex >= 0 ? (inviteParts[joinIndex + 1] || '') : '';
                                const INVITE_TOKEN = joinIndex >= 0 ? (inviteParts[joinIndex + 2] || '') : '';

                                if (INVITE_TOKEN) {
                                    document.getElementById('stateAppBtn').href = 'colmeia://join/' + INVITE_ROOM + '/' + INVITE_TOKEN;
                                    document.getElementById('appLink').dataset.url = 'colmeia://join/' + INVITE_ROOM + '/' + INVITE_TOKEN;
                                }

                                let ws = null;
                                let state = 'loading';
                                let currentRoomName = 'Sala';
                                let stateTimer = null;
                                let reconnectTimer = null;

                                function friendlyError(msg) {
                                    if (!msg) return 'Erro desconhecido.';
                                    const m = msg.toLowerCase();
                                    if (m.includes('expirado') || m.includes('expir')) return 'Convite expirado.';
                                    if (m.includes('inválido') || m.includes('invalid')) return 'Convite inválido.';
                                    if (m.includes('usado') || m.includes('used') || m.includes('já utilizado')) return 'Convite já utilizado.';
                                    if (m.includes('revogado') || m.includes('revoked')) return 'Convite revogado.';
                                    if (m.includes('permissão') || m.includes('permission') || m.includes('insufficient')) return 'Você não tem permissão para entrar nesta sala.';
                                    if (m.includes('sala não encontrada') || m.includes('room not found') || m.includes('não existe')) return 'Sala não encontrada.';
                                    if (m.includes('timeout') || m.includes('tempo limite')) return 'Tempo limite excedido. Verifique sua conexão.';
                                    if (m.includes('token')) return 'Token de autenticação inválido.';
                                    return msg;
                                }

                                function setState(newState, errorMsg) {
                                    state = newState;
                                    clearTimeout(stateTimer);
                                    stateTimer = null;

                                    const overlay = document.getElementById('stateOverlay');
                                    const title = document.getElementById('roomTitle');
                                    const spinner = document.getElementById('stateSpinner');
                                    const msg = document.getElementById('stateMessage');
                                    const errorDetail = document.getElementById('stateErrorDetail');
                                    const retryBtn = document.getElementById('stateRetryBtn');
                                    const appBtn = document.getElementById('stateAppBtn');
                                    const dot = document.querySelector('.status-dot-small');

                                    const statusColors = { authenticating: '#f59e0b', joining: '#3b82f6', snapshot: '#8b5cf6', ready: '#10b981', error: '#ef4444', loading: '#94a3b8' };

                                    if (newState === 'error') {
                                        overlay.style.display = 'flex';
                                        overlay.style.background = 'rgba(0,0,0,0.85)';
                                        spinner.style.display = 'none';
                                        msg.textContent = 'Não foi possível conectar';
                                        msg.style.color = '#f87171';
                                        errorDetail.textContent = friendlyError(errorMsg || 'Erro desconhecido.');
                                        errorDetail.style.display = 'block';
                                        retryBtn.style.display = 'inline-block';
                                        appBtn.style.display = 'inline-block';
                                        retryBtn.onclick = startConnection;
                                        title.textContent = 'Erro de conexão';
                                        if (dot) { dot.style.background = statusColors.error; dot.style.boxShadow = `0 0 6px ${statusColors.error}`; }
                                    } else if (newState === 'ready') {
                                        overlay.style.display = 'none';
                                        title.textContent = currentRoomName;
                                        if (dot) { dot.style.background = statusColors.ready; dot.style.boxShadow = `0 0 6px ${statusColors.ready}`; }
                                    } else {
                                        overlay.style.display = 'flex';
                                        overlay.style.background = 'rgba(0,0,0,0.8)';
                                        spinner.style.display = 'block';
                                        msg.style.color = '#94a3b8';
                                        errorDetail.style.display = 'none';
                                        retryBtn.style.display = 'none';
                                        appBtn.style.display = 'none';
                                        const labels = { loading: 'Carregando sala...', authenticating: 'Autenticando...', joining: 'Entrando na sala...', snapshot: 'Carregando dados da sala...' };
                                        msg.textContent = labels[newState] || 'Carregando...';
                                        title.textContent = labels[newState] || 'Carregando...';
                                        if (dot) { dot.style.background = statusColors[newState]; dot.style.boxShadow = `0 0 6px ${statusColors[newState]}`; }
                                        stateTimer = setTimeout(() => {
                                            if (state === newState) setState('error', 'Tempo limite excedido. Verifique sua conexão.');
                                        }, 10000);
                                    }
                                }

                                const pendingRequests = {};
                                let requestCounter = 0;

                                function rpc(method, params) {
                                    return new Promise((resolve, reject) => {
                                        const id = 'wr_' + (++requestCounter) + '_' + Math.random().toString(36).slice(2, 8);
                                        const timer = setTimeout(() => {
                                            delete pendingRequests[id];
                                            reject(new Error('timeout'));
                                        }, 8000);
                                        pendingRequests[id] = { resolve, reject, timer };
                                        ws.send(JSON.stringify({ kind: 'request', id, method, params: params || {} }));
                                    });
                                }

                                function stopConnection() {
                                    clearTimeout(stateTimer);
                                    stateTimer = null;
                                    clearTimeout(reconnectTimer);
                                    reconnectTimer = null;
                                    for (const id in pendingRequests) {
                                        clearTimeout(pendingRequests[id].timer);
                                        pendingRequests[id].reject(new Error('connection closed'));
                                    }
                                    for (const id in pendingRequests) delete pendingRequests[id];
                                    if (ws) {
                                        ws.onopen = null; ws.onmessage = null; ws.onclose = null; ws.onerror = null;
                                        try { ws.close(); } catch {}
                                        ws = null;
                                    }
                                }

                                function handleEvent(ev) {
                                    const topic = ev.topic;
                                     const p = ev.params || {};
                                     if (topic === 'session.output' && p.session_id && p.data_b64) {
                                         let bytes, dec = '';
                                         try {
                                             bytes = base64ToBytes(p.data_b64);
                                             dec = new TextDecoder().decode(bytes);
                                         } catch { return; }
                                         if (!sessionOutputsMap[p.session_id]) sessionOutputsMap[p.session_id] = [];
                                         sessionOutputsMap[p.session_id].push({text:dec, data_b64:p.data_b64, seq:String(p.seq || 0)});
                                         if (sessionOutputsMap[p.session_id].length > 500) {
                                             sessionOutputsMap[p.session_id] = sessionOutputsMap[p.session_id].slice(-500);
                                         }
                                         const node = activeNodes.find(n => terminalSessionID(n) === p.session_id);
                                         if (node) {
                                             const controller = terminalControllers.get(node.id);
                                             if (controller && controller.sessionID === p.session_id) {
                                                 const seq = Number(p.seq || 0);
                                                 if (!seq || seq > controller.lastSeq) {
                                                     controller.term.write(bytes);
                                                     if (seq) controller.lastSeq = seq;
                                                 }
                                                 return;
                                             }
                                             const el = document.getElementById(node.id);
                                             if (el) {
                                                 try {
                                                     let outputArea = el.querySelector('.term-output');
                                                    if (!outputArea) {
                                                        let body = el.querySelector('.term-body');
                                                        if (!body) return;
                                                        outputArea = document.createElement('div');
                                                        outputArea.className = 'term-output';
                                                        body.parentNode.insertBefore(outputArea, body.nextSibling);
                                                    }
                                                    const terminalScreen = el.querySelector('.terminal-screen');
                                                    const shouldFollow = terminalScreen &&
                                                        terminalScreen.scrollHeight - terminalScreen.scrollTop - terminalScreen.clientHeight < 36;
                                                    const safe = esc(cleanTerminalOutput(dec)).replace(/\\n/g, '<br>');
                                                     outputArea.innerHTML += safe;
                                                     if (shouldFollow) terminalScreen.scrollTop = terminalScreen.scrollHeight;
                                                 } catch {}
                                            }
                                        }
                                    } else if (topic === 'session.state' && p.session_id) {
                                        const stateRecord = { session_id: p.session_id, estado: p.estado || '', node_id: p.node_id || '' };
                                        sessionStatesMap[p.session_id] = stateRecord;
                                        if (p.node_id) {
                                            const list = sessionStatesByNode[p.node_id] || [];
                                            sessionStatesByNode[p.node_id] = list.filter(s => s.session_id !== p.session_id).concat([stateRecord]);
                                            if (!['encerrada','morta'].includes(p.estado)) currentSessionByNode[p.node_id] = p.session_id;
                                            else if (currentSessionByNode[p.node_id] === p.session_id) delete currentSessionByNode[p.node_id];
                                        }
                                        const node = activeNodes.find(n => terminalSessionID(n) === p.session_id);
                                        if (node) {
                                            node.launching = false;
                                            const el = document.getElementById(node.id);
                                            if (el) {
                                                const dot = el.querySelector('.status-dot');
                                                if (dot) {
                                                    if (p.estado && p.estado !== 'encerrada') {
                                                        dot.className = 'status-dot pulsing';
                                                    } else {
                                                        dot.className = 'status-dot';
                                                        dot.style.background = '#64748b';
                                                    }
                                                }
                                                const footer = el.querySelector('.term-footer');
                                                if (footer) {
                                                    const sEstado = p.estado || '';
                                                    const label = sEstado === 'encerrada' ? ' ⚫ encerrada' : (sEstado === 'rodando' ? ' 🟢 ativo' : (sEstado === 'viva' ? ' 🟡 viva' : ' 🟡 ' + (sEstado || '?')));
                                                    footer.innerHTML = footer.innerHTML.replace(/[🟢🟡⚫].*$/, label);
                                                }
                                            }
                                            renderAllNodes(activeNodes);
                                        }
                                    } else if (topic === 'presence.changed' && p.room_id === INVITE_ROOM) {
                                        if (p.member_id !== browserAuthor) {
                                            if (p.connected) remotePresences.set(p.member_id, p);
                                            else remotePresences.delete(p.member_id);
                                            renderRemotePresences();
                                            // Atualiza badges "quem está no terminal" sem destruir xterm.
                                            document.querySelectorAll('.node-terminal').forEach(card => {
                                                const head = card.querySelector('.node-head');
                                                if (!head) return;
                                                let pills = head.querySelector('.viewer-pills');
                                                const viewers = remoteViewersForNode(card.id);
                                                if (!viewers.length) { if (pills) pills.remove(); return; }
                                                if (!pills) {
                                                    pills = document.createElement('span');
                                                    pills.className = 'viewer-pills';
                                                    const state = head.querySelector('.node-state');
                                                    if (state) head.insertBefore(pills, state); else head.appendChild(pills);
                                                }
                                                pills.title = viewers.map(v => v.name).join(', ') + ' usando';
                                                pills.innerHTML = viewers.slice(0,3).map(v =>
                                                    `<span class="viewer-pill" style="background:${memberCursorColor(v.id)}" title="${esc(v.name)}">${esc((v.name||'?').slice(0,1).toUpperCase())}</span>`
                                                ).join('');
                                            });
                                        }
                                    } else if (topic === 'watchdog.alert') {
                                        watchdogAlerts.push(p);
                                        if (watchdogAlerts.length > 100) watchdogAlerts.splice(0, watchdogAlerts.length - 100);
                                        renderWatchdog();
                                    } else if (topic === 'note.appended' && p.node_id && p.conteudo) {
                                        const node = activeNodes.find(n => n.id === p.node_id);
                                        if (node) {
                                            noteContentsMap[p.node_id] = p.conteudo;
                                            const el = document.getElementById(p.node_id);
                                            if (el) renderNoteContent(el, p.conteudo);
                                        }
                                    } else if (topic === 'member.updated' && p.member) {
                                        memberNames[p.member.id] = p.member.display_name || p.member.id;
                                        renderChatEvents();
                                    } else if (topic === 'session_event.appended' && p.event) {
                                        addChatEvent(p.event);
                                    } else if (topic === 'document.op' && p.op) {
                                        const op = p.op;
                                        const tipo = op.tipo;
                                        const seq = p.seq || op.seq || 0;
                                        if (workspaceSeq && seq > workspaceSeq + 1) {
                                            console.warn('seq gap: was', workspaceSeq, 'got', seq, '— requesting snapshot');
                                            requestSnapshot();
                                            return;
                                        }
                                        if (seq) workspaceSeq = seq;
                                        const payload = op.payload || {};
                                        switch (tipo) {
                                            case 'node.add': {
                                                if (payload.node && !activeNodes.find(n => n.id === payload.node.id)) {
                                                    activeNodes.push(payload.node);
                                                    renderAllNodes(activeNodes);
                                                }
                                                break;
                                            }
                                            case 'node.move': {
                                                const n = activeNodes.find(n => n.id === payload.id);
                                                if (n) {
                                                    if (n.posicao) { n.posicao.x = payload.posicao.x; n.posicao.y = payload.posicao.y; }
                                                    else { n.x = payload.posicao.x; n.y = payload.posicao.y; }
                                                    const el = document.getElementById(payload.id);
                                                    if (el) { el.style.left = nodeX(n) + 'px'; el.style.top = nodeY(n) + 'px'; }
                                                    renderConnections(activeConns, activeNodes);
                                                    updateMinimap();
                                                }
                                                break;
                                            }
                                            case 'node.resize': {
                                                const n = activeNodes.find(n => n.id === payload.id);
                                                if (n) {
                                                    if (n.tamanho) { n.tamanho.w = payload.tamanho.w; n.tamanho.h = payload.tamanho.h; }
                                                    else { n.w = payload.tamanho.w; n.h = payload.tamanho.h; }
                                                    const el = document.getElementById(payload.id);
                                                    if (el) { el.style.width = nodeW(n) + 'px'; el.style.height = nodeH(n) + 'px'; }
                                                    renderConnections(activeConns, activeNodes);
                                                    updateMinimap();
                                                }
                                                break;
                                            }
                                            case 'node.update': {
                                                const n = activeNodes.find(n => n.id === payload.id);
                                                if (n && payload.campos) {
                                                    for (const key in payload.campos) n[key] = payload.campos[key];
                                                    renderAllNodes(activeNodes);
                                                }
                                                break;
                                            }
                                            case 'node.delete': {
                                                const idx = activeNodes.findIndex(n => n.id === payload.id);
                                                if (idx >= 0) { activeNodes.splice(idx, 1); renderAllNodes(activeNodes); }
                                                break;
                                            }
                                            case 'connection.add': {
                                                const conn = payload.connection;
                                                if (conn && !activeConns.find(c => (c.id || c.de+'-'+c.para) === (conn.id || conn.de+'-'+conn.para))) {
                                                    activeConns.push(conn);
                                                    renderAllNodes(activeNodes);
                                                }
                                                break;
                                            }
                                            case 'connection.delete': {
                                                const idx = activeConns.findIndex(c => c.id === payload.id || c.de === payload.id || c.from === payload.id);
                                                if (idx >= 0) { activeConns.splice(idx, 1); renderAllNodes(activeNodes); }
                                                break;
                                            }
                                            case 'traco.add': {
                                                const n = activeNodes.find(n => n.id === payload.node_id);
                                                if (n && payload.traco) {
                                                    if (!n.tracos) n.tracos = [];
                                                    n.tracos.push(payload.traco);
                                                    renderAllNodes(activeNodes);
                                                }
                                                break;
                                            }
                                            case 'traco.delete': {
                                                const n = activeNodes.find(n => n.id === payload.node_id);
                                                if (n && n.tracos && payload.traco_id) {
                                                    n.tracos = n.tracos.filter(t => t.id !== payload.traco_id);
                                                    renderAllNodes(activeNodes);
                                                }
                                                break;
                                            }
                                            case 'workspace.rename': {
                                                const badge = document.getElementById('workspaceBadge');
                                                if (badge) badge.textContent = payload.nome || 'ws:' + workspaceID;
                                                break;
                                            }
                                        }
                                    }
                                }

                                async function startConnection() {
                                    stopConnection();
                                    if (!INVITE_TOKEN) { setState('error', 'Nenhum convite encontrado. Use o link de convite para acessar a sala.'); return; }

                                    const wsProtocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
                                    ws = new WebSocket(wsProtocol + '//' + location.host + '/colmeia-ws');
                                    if (state !== 'ready' && state !== 'disconnected') setState('authenticating');
                                    setConnectionStatus('syncing');

                                    ws.onerror = () => {
                                        if (state === 'ready') { setConnectionStatus('disconnected'); }
                                        else { setState('error', 'Erro de conexão com o servidor.'); }
                                    };

                                    ws.onclose = (e) => {
                                        if (state === 'ready' || state === 'disconnected') {
                                            setConnectionStatus('disconnected');
                                            const delay = Math.min(1000 * Math.pow(2, Math.min(reconnectAttempt, 6)), 30000);
                                            reconnectAttempt++;
                                            reconnectTimer = setTimeout(startConnection, delay);
                                        } else if (state !== 'error') {
                                            setState('error', 'Conexão fechada inesperadamente.');
                                        }
                                    };

                                    ws.onmessage = (e) => {
                                        let d;
                                        try { d = JSON.parse(e.data); } catch { return; }
                                        // Handle responses (RPC replies)
                                        if (d.id) {
                                            const handler = pendingRequests[d.id];
                                            if (!handler) return;
                                            delete pendingRequests[d.id];
                                            clearTimeout(handler.timer);
                                            if (d.ok === true && d.result !== undefined) handler.resolve(d.result);
                                            else if (d.error) handler.reject(new Error(d.error.message || d.error.name || d.error || 'unknown'));
                                            else handler.reject(new Error('Resposta inesperada do servidor.'));
                                            return;
                                        }
                                        // Handle events (kind === 'event')
                                        if (d.kind === 'event') {
                                            handleEvent(d);
                                        }
                                    };

                                    ws.onopen = async () => {
                                        reconnectAttempt = 0;
                                        try {
                                            const helloResult = await rpc('hello', { protocol_version: 1, client: 'web-canvas', author: browserAuthor, token: INVITE_TOKEN });
                                            if (helloResult.author && helloResult.author !== browserAuthor) {
                                                browserAuthor = helloResult.author;
                                                try { localStorage.setItem(browserAuthorKey, browserAuthor); } catch {}
                                            }

                                            if (state !== 'ready') setState('joining');
                                            const joinResult = await rpc('room.join', { room_id: INVITE_ROOM, invite_token: INVITE_TOKEN });
                                            if (joinResult.room && joinResult.room.name) {
                                                currentRoomName = joinResult.room.name;
                                                document.getElementById('roomTitle').textContent = currentRoomName;
                                            }
                                            if (joinResult.members) renderMemberPills(joinResult.members);
                                            roomAgentSessions = joinResult.agent_sessions || [];
                                            workspaceID = joinResult.room && joinResult.room.workspace_id ? joinResult.room.workspace_id : null;
                                            if (workspaceID) {
                                                const badge = document.getElementById('workspaceBadge');
                                                if (badge) badge.style.display = 'none';
                                            }

                                            if (state !== 'ready') {
                                                setState('snapshot');
                                                const snapResult = await rpc('room.snapshot', { room_id: INVITE_ROOM });
                                                if (snapResult.members) renderMemberPills(snapResult.members);
                                                roomAgentSessions = snapResult.agent_sessions || roomAgentSessions;
                                                roomEvents = [];
                                                (snapResult.events || []).forEach(addChatEvent);
                                            }

                                            // Carrega ou recarrega o canvas
                                            if (workspaceID) {
                                                setConnectionStatus('syncing');
                                                if (workspaceSeq !== null) {
                                                    // Reconnect — tenta catch-up
                                                    try {
                                                        const catchResult = await rpc('workspace.catchUp', { workspace_id: workspaceID, from_seq: workspaceSeq });
                                                        if (catchResult && catchResult.ops && catchResult.ops.length > 0) {
                                                            for (const opPayload of catchResult.ops) {
                                                                handleEvent({ topic: 'document.op', params: opPayload });
                                                            }
                                                            setConnectionStatus('live');
                                                        } else if (catchResult && catchResult.snapshot) {
                                                            const snap = catchResult.snapshot;
                                                            activeNodes = snap.nodes || [];
                                                            activeConns = snap.connections || [];
                                                            workspaceSeq = snap.seq || 0;
                                                             noteContentsMap = snap.note_contents || {};
                                                             const ssList = snap.session_states || [];
                                                             indexSessionStates(ssList);
                                                            sessionOutputsMap = snap.session_outputs || {};
                                                            renderAllNodes(activeNodes);
                                                            setConnectionStatus('live');
                                                        } else {
                                                            await loadCanvas(workspaceID);
                                                        }
                                                    } catch {
                                                        await loadCanvas(workspaceID);
                                                    }
                                                } else {
                                                    await loadCanvas(workspaceID);
                                                }
                                            }

                                             setConnectionStatus('live');
                                             setState('ready');
                                             schedulePresence(true);
                                        } catch (err) {
                                            setState('error', err.message);
                                        }
                                    };
                                }

                                 startConnection();
                                 setInterval(() => schedulePresence(true), 5000);

                                function renderMemberPills(members) {
                                    const c = document.getElementById('memberPills');
                                    (members || []).forEach(m => { memberNames[m.id] = m.display_name || m.id; });
                                    if (memberNames[browserAuthor]) {
                                        document.querySelector('#userNameButton .action-label').textContent = memberNames[browserAuthor];
                                    }
                                    c.innerHTML = (members || []).map((m) => {
                                        const name = m.display_name || m.id || '?';
                                        const initials = name.substring(0,2).toUpperCase();
                                        const isOnline = m.status !== 'offline';
                                        const statusClass = isOnline ? 'online' : 'offline';
                                        const role = m.roles && m.roles.length > 0 ? `<div class="role-badge">${m.roles[0].substring(0,1).toUpperCase()}</div>` : '';
                                        return `<div class="member-pill ${statusClass}" title="${name}">${initials}${role}</div>`;
                                    }).join('');
                                }

                                document.getElementById('chatForm').onsubmit = async (e) => {
                                    e.preventDefault();
                                    const input = document.getElementById('msgInput');
                                    const text = input.value.trim();
                                    if(!text) return;
                                    input.disabled = true;
                                    try {
                                        const sessionID = await ensureChatSession();
                                        const result = await rpc('session_event.append', {
                                            room_id: INVITE_ROOM, session_id: sessionID,
                                            kind: 'message_sent', payload: { texto: text }, event_id: newULID()
                                        });
                                        if (result.event) addChatEvent(result.event);
                                    } catch (error) {
                                        alert('Não foi possível enviar: ' + friendlyError(error.message));
                                        return;
                                    } finally {
                                        input.disabled = false;
                                        input.focus();
                                    }
                                    input.value = '';
                                };

                                window.bootReady = true;
                            </script>
                        </body>
                        </html>
                        """
                        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n" + html
                        let respData = Data(response.utf8)
                        respData.withUnsafeBytes { buffer in
                            guard let ptr = buffer.baseAddress else { return }
                            var written = 0
                            while written < buffer.count {
                                let n = write(fd, ptr.advanced(by: written), buffer.count - written)
                                if n <= 0 { break }
                                written += n
                            }
                        }
                        break
                    }

                    let body = "{\"status\":\"online\",\"service\":\"Colmeia Hub\",\"version\":\"\(versionStr)\",\"transport\":\"NDJSON / WebSocket (WSS)\",\"port\":9620}\n"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n" + body
                    let respData = Data(response.utf8)
                    respData.withUnsafeBytes { buffer in
                        guard let ptr = buffer.baseAddress else { return }
                        var written = 0
                        while written < buffer.count {
                            let n = write(fd, ptr.advanced(by: written), buffer.count - written)
                            if n <= 0 { break }
                            written += n
                        }
                    }
                    break
                }

                if isWebSocket {
                    for payload in wsDecoder.append(data) {
                        hub?.receive(line: payload, from: self)
                    }
                } else {
                    for line in lineBuffer.append(data) {
                        hub?.receive(line: line, from: self)
                    }
                }
            } else if count < 0 && errno == EINTR { continue }
            else { break }
        }
        hub?.dropClient(self, motivo: "desconectou")
    }

    func send(_ envelope: Envelope) {
        guard let data = try? SocketFraming.encodeLine(envelope) else { return }
        guard fd >= 0 else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !writeClosed else { return }
        if isWebSocket {
            let frame = WebSocketFraming.encodeFrame(data)
            var offset = 0
            frame.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written > 0 { offset += written }
                    else if written < 0 && errno == EINTR { continue }
                    else { break }
                }
            }
        } else {
            try? SocketFraming.writeLine(fd: fd, data)
        }
    }

    func respond(id: String, result: JSONValue?) {
        send(.response(ResponseMessage(id: id, result: result)))
    }

    func respond(id: String, error: ProtocolError) {
        send(.response(ResponseMessage(id: id, error: error)))
    }

    func close() {
        writeLock.lock()
        let alreadyClosed = writeClosed
        writeClosed = true
        writeLock.unlock()
        guard !alreadyClosed else { return }
        shutdown(fd, Int32(SHUT_RDWR))
        #if canImport(Darwin)
        writeQueue.async { [fd] in _ = Darwin.close(fd) }
        #elseif canImport(Glibc)
        writeQueue.async { [fd] in _ = Glibc.close(fd) }
        #endif
    }
}

// MARK: - Store Helpers

func nidFromDict(_ dict: [String: JSONValue]) -> ULID? {
    if case .string(let s) = dict["node_id"] ?? dict["no_id"] { return ULID(s) }
    return nil
}

extension HubServer {
    func storeForNode(nodeID: ULID) -> WorkspaceStore? {
        for store in workspaceStores.values {
            if store.nodes.contains(where: { $0.id == nodeID }) {
                return store
            }
        }
        // Procura também em noteContents e sessionStates (itens órfãos)
        for store in workspaceStores.values {
            if store.noteContents[nodeID] != nil { return store }
        }
        return nil
    }
}

// MARK: - Engine Connection (persistente)

/// Mantém uma conexão TCP persistente com o Engine, encaminhando eventos
/// para os clientes WebSocket do Hub e permitindo RPCs sem abrir um novo socket.
public final class EngineConnection: @unchecked Sendable {
    public weak var hub: HubServer?
    private let url: String
    private let queue = DispatchQueue(label: "colmeia.hub.engine")
    private var fd: Int32 = -1
    private var isConnected = false
    private var shouldReconnect = true
    private var reconnectDelay: Double = 1.0
    private var pending: [String: (Result<JSONValue, Error>) -> Void] = [:]
    private let pendingLock = NSLock()

    public init(url: String, hub: HubServer) {
        self.url = url
        self.hub = hub
    }

    /// Inicia a conexão (tenta em background, reconecta automaticamente).
    public func start() {
        shouldReconnect = true
        queue.async { [weak self] in self?.connectLoop() }
    }

    public func stop() {
        shouldReconnect = false
        queue.async { [weak self] in self?.close() }
    }

    /// Envia um RPC e espera a resposta de forma assíncrona.
    public func call(method: String, params: JSONValue?, completion: @escaping (Result<JSONValue, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, self.isConnected else {
                completion(.failure(ProtocolError(name: .internal_error, message: "engine desconectado")))
                return
            }
            let callID = "px-\(ULID.generate().string)"
            pendingLock.lock()
            pending[callID] = completion
            pendingLock.unlock()
            let req = Envelope.request(RequestMessage(id: callID, method: method, params: params))
            guard let data = try? SocketFraming.encodeLine(req) else {
                pendingLock.lock(); pending.removeValue(forKey: callID); pendingLock.unlock()
                completion(.failure(ProtocolError(name: .internal_error, message: "encode falhou")))
                return
            }
            #if canImport(Darwin)
            _ = Darwin.write(fd, (data as NSData).bytes, data.count)
            #elseif canImport(Glibc)
            _ = Glibc.write(fd, (data as NSData).bytes, data.count)
            #endif
        }
    }

    // MARK: - Internos

    private func connectLoop() {
        while shouldReconnect {
            do {
                try connect()
                isConnected = true
                reconnectDelay = 1.0
                try readLoop()
            } catch {
                hub?.log.warn("engine_conn", "falha: \(error.localizedDescription)")
            }
            isConnected = false
            close()
            // Rejeita pendentes
            pendingLock.lock()
            for (_, cb) in pending { cb(.failure(ProtocolError(name: .internal_error, message: "engine desconectou"))) }
            pending.removeAll()
            pendingLock.unlock()
            guard shouldReconnect else { break }
            Thread.sleep(forTimeInterval: reconnectDelay)
            reconnectDelay = min(reconnectDelay * 2, 30)
        }
    }

    private func connect() throws {
        let raw = url
        let clean: String
        if raw.hasPrefix("tcp://") { clean = String(raw.dropFirst(6)) }
        else { clean = raw }
        let parts = clean.split(separator: ":")
        let host = parts.count > 0 ? String(parts[0]) : "127.0.0.1"
        let port = parts.count > 1 ? (UInt16(parts[1]) ?? 9622) : 9622

        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        let status = host.withCString { h in portStr.withCString { p in getaddrinfo(h, p, &hints, &res) } }
        guard status == 0, let info = res else { throw ProtocolError(name: .internal_error, message: "engine getaddrinfo falhou") }
        defer { freeaddrinfo(res) }

        let s = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard s >= 0 else { throw ProtocolError(name: .internal_error, message: "engine socket() falhou") }
        #if canImport(Darwin)
        var one: Int32 = 1; setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(s, F_SETFL, O_NONBLOCK)
        let cr = Darwin.connect(s, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if cr != 0 {
            let e = errno
            guard e == EINPROGRESS else { Darwin.close(s); throw ProtocolError(name: .internal_error, message: "engine connect falhou (\(String(cString: strerror(e))))") }
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&pfd, 1, 5000) > 0 else { Darwin.close(s); throw ProtocolError(name: .internal_error, message: "engine connect timeout") }
            var soErr: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &soErr, &len)
            guard soErr == 0 else { Darwin.close(s); throw ProtocolError(name: .internal_error, message: "engine connect falhou (\(String(cString: strerror(soErr))))") }
        }
        _ = fcntl(s, F_SETFL, 0)
        #elseif canImport(Glibc)
        _ = Glibc.fcntl(s, F_SETFL, O_NONBLOCK)
        let cr = Glibc.connect(s, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if cr != 0 {
            let e = errno
            guard e == EINPROGRESS else { Glibc.close(s); throw ProtocolError(name: .internal_error, message: "engine connect falhou (\(String(cString: strerror(e))))") }
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            guard Glibc.poll(&pfd, 1, 5000) > 0 else { Glibc.close(s); throw ProtocolError(name: .internal_error, message: "engine connect timeout") }
            var soErr: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &soErr, &len)
            guard soErr == 0 else { Glibc.close(s); throw ProtocolError(name: .internal_error, message: "engine connect falhou (\(String(cString: strerror(soErr))))") }
        }
        _ = Glibc.fcntl(s, F_SETFL, 0)
        #endif
        fd = s

        // Hello
        let helloID = "px-h-\(ULID.generate().string)"
        let helloReq = Envelope.request(RequestMessage(id: helloID, method: "hello",
            params: try? JSONValue(encoding: HelloParams(protocolVersion: ColmeiaVersion.protocolVersion, client: "colmeia-hub", author: Author.humanoLocal))))
        guard let helloData = try? SocketFraming.encodeLine(helloReq) else { throw ProtocolError(name: .internal_error, message: "engine hello encode falhou") }
        #if canImport(Darwin)
        _ = Darwin.write(s, (helloData as NSData).bytes, helloData.count)
        #elseif canImport(Glibc)
        _ = Glibc.write(s, (helloData as NSData).bytes, helloData.count)
        #endif

        var lineBuffer = SocketFraming.LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let helloResp = try readEngineResponse(expectedID: helloID, lineBuffer: &lineBuffer, chunk: &chunk)
        guard helloResp.ok else { close(); throw ProtocolError(name: .internal_error, message: "engine hello recusado") }
        hub?.log.info("engine_conn", "conectado (\(host):\(port))")
    }

    private func readLoop() throws {
        let lineBuffer = SocketFraming.LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while shouldReconnect && isConnected {
            #if canImport(Darwin)
            let count = Darwin.read(fd, &chunk, chunk.count)
            #elseif canImport(Glibc)
            let count = Glibc.read(fd, &chunk, chunk.count)
            #endif
            if count > 0 {
                let data = Data(bytes: chunk, count: count)
                for line in lineBuffer.append(data) {
                    processLine(line)
                }
            } else if count == 0 { break }
            else if count < 0 && errno == EINTR { continue }
            else { break }
        }
    }

    private func processLine(_ data: Data) {
        guard let envelope = try? SocketFraming.decodeLine(Envelope.self, from: data) else { return }
        switch envelope {
        case .response(let resp):
            pendingLock.lock()
            let cb = pending.removeValue(forKey: resp.id)
            pendingLock.unlock()
            if let cb {
                if resp.ok { cb(.success(resp.result ?? .object([:]))) }
                else { cb(.failure(resp.error ?? ProtocolError(name: .internal_error, message: "engine error"))) }
            }
        case .event(let event):
            if let topic = event.knownTopic {
                if case .object(let dict) = event.params {
                    if topic == .noteAppended {
                        if case .string(let nodeIDStr) = dict["node_id"],
                           let nodeID = ULID(nodeIDStr),
                           case .string(let conteudo) = dict["conteudo"],
                           let store = hub?.storeForNode(nodeID: nodeID) {
                            store.setNoteContent(nodeID: nodeID, content: conteudo)
                            store.save()
                        }
                    } else if topic == .sessionState {
                        if case .string(let sidStr) = dict["session_id"],
                           let sessionID = ULID(sidStr),
                           case .string(let estado) = dict["estado"] {
                            let wsID: ULID?
                            if case .string(let wsidStr) = dict["workspace_id"] { wsID = ULID(wsidStr)
                            } else if case .string(let nidStr) = dict["node_id"] ?? dict["no_id"],
                                      let nid = ULID(nidStr) { wsID = hub?.storeForNode(nodeID: nid)?.workspace.id
                            } else { wsID = hub?.sessionToWorkspace[sessionID] }
                            if let wsID, let store = hub?.workspaceStores[wsID] {
                                store.setSessionState(sessionID: sessionID, estado: estado, nodeID: nidFromDict(dict))
                                store.save()
                                hub?.sessionToWorkspace[sessionID] = wsID
                            }
                        }
                    } else if topic == .sessionOutput {
                        if case .string(let sidStr) = dict["session_id"],
                           let sessionID = ULID(sidStr),
                           case .string(let dataB64) = dict["data_b64"],
                           let data = Data(base64Encoded: dataB64),
                           let text = String(data: data, encoding: .utf8) {
                            let wsID: ULID?
                            if case .string(let wsidStr) = dict["workspace_id"] { wsID = ULID(wsidStr)
                            } else { wsID = hub?.sessionToWorkspace[sessionID] }
                            if let wsID, let store = hub?.workspaceStores[wsID] {
                                store.appendSessionOutput(sessionID: sessionID, text: text)
                                store.save()
                            }
                        }
                    } else if topic == .documentOp {
                        if case .string(let wsidStr) = dict["workspace_id"],
                           let wsid = ULID(wsidStr),
                           let store = hub?.workspaceStores[wsid],
                           let opValue = dict["op"] {
                            do {
                                let op = try opValue.decode(as: DocOp.self)
                                store.applyDocOp(op)
                                store.save()
                            } catch {
                                print("[Hub] engine document.op decode error: \(error)")
                            }
                        }
                    }
                }
                hub?.broadcast(topic, ws: nil, event.params)
            }
        case .request:
            break // Hub não processa requests do Engine
        }
    }

    private func readEngineResponse(expectedID: String, lineBuffer: inout SocketFraming.LineBuffer, chunk: inout [UInt8]) throws -> ResponseMessage {
        while true {
            #if canImport(Darwin)
            let count = Darwin.read(fd, &chunk, chunk.count)
            #elseif canImport(Glibc)
            let count = Glibc.read(fd, &chunk, chunk.count)
            #endif
            guard count > 0 else { throw ProtocolError(name: .internal_error, message: "engine read falhou") }
            for line in lineBuffer.append(Data(bytes: chunk, count: count)) {
                guard let env = try? SocketFraming.decodeLine(Envelope.self, from: line),
                      case .response(let resp) = env, resp.id == expectedID else { continue }
                return resp
            }
        }
    }

    private func close() {
        guard fd >= 0 else { return }
        #if canImport(Darwin)
        Darwin.close(fd)
        #elseif canImport(Glibc)
        Glibc.close(fd)
        #endif
        fd = -1
    }
}

// MARK: - Errors

public enum HubError: Error, Equatable, Sendable, LocalizedError {
    case io(String, Int32)
    public var errorDescription: String? {
        switch self { case .io(let m, let c): return "Hub IO: \(m) (errno \(c))" }
    }
}

// MARK: - Logger

public struct HubLogger {
    private let queue = DispatchQueue(label: "colmeia.hub.log")
    public func info(_ event: String, _ message: String) { log("INFO", event, message) }
    public func warn(_ event: String, _ message: String) { log("WARN", event, message) }
    private func log(_ level: String, _ event: String, _ message: String) {
        queue.async {
            let ts = ISO8601DateFormatter().string(from: Date())
            print("[\(ts)] [\(level)] [\(event)] \(message)")
        }
    }
}
