import Foundation
import Combine
import ColmeiaKit

@MainActor
final class HubConnection: ObservableObject {
    static let defaultHubURL = "ws://127.0.0.1:9620"
    static let hubURLDefaultsKey = "colmeia.hub.url"
    static let hubTokenDefaultsKey = "colmeia.hub.token"

    static var savedHubURL: String {
        UserDefaults.standard.string(forKey: hubURLDefaultsKey)
            ?? ProcessInfo.processInfo.environment["COLMEIA_HUB_URL"]
            ?? defaultHubURL
    }

    static var savedHubToken: String? {
        let token = UserDefaults.standard.string(forKey: hubTokenDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    @Published private(set) var status: ConnectionStatus = .conectando
    @Published private(set) var hubURL: String
    @Published private(set) var engineVersion: String?
    @Published private(set) var activeRoomID: ULID?
    @Published private(set) var lastConnectionError: String?
    @Published private(set) var pendingOutboxCount: Int = 0

    public var onEvent: ((EventMessage) -> Void)?
    public var onConnected: (() async -> Void)?
    public var hubToken: String?

    private var socketClient: SocketClient?
    private var reconnectAttempt = 0
    private var loopTask: Task<Void, Never>?
    private var eventObservers: [UUID: (EventMessage) -> Void] = [:]
    private var outboxes: [ULID: HubOutbox] = [:]
    private let outboxPaths = ColmeiaPaths()

    public init(hubURL: String? = nil, token: String? = nil) {
        self.hubURL = hubURL ?? HubConnection.savedHubURL
        self.hubToken = token
            ?? HubConnection.savedHubToken
            ?? ProcessInfo.processInfo.environment["COLMEIA_HUB_TOKEN"]
        loadPersistedOutboxes()
    }

    public func saveConfiguration(url: String, token: String) {
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(cleanURL, forKey: Self.hubURLDefaultsKey)
        UserDefaults.standard.set(cleanToken, forKey: Self.hubTokenDefaultsKey)
        hubToken = cleanToken.isEmpty ? nil : cleanToken
        NotificationCenter.default.post(name: .colmeiaHubConfigurationChanged, object: nil)
        connect(to: cleanURL)
    }

    public func connect(to url: String) {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        self.hubURL = clean
        stop()
        start()
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { await runLoop() }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        disconnectWebSocket()
        status = .conectando
    }

    public var isConnected: Bool {
        status == .conectado
    }

    @discardableResult
    public func addEventObserver(_ observer: @escaping (EventMessage) -> Void) -> UUID {
        let id = UUID()
        eventObservers[id] = observer
        return id
    }

    public func removeEventObserver(_ id: UUID) {
        eventObservers.removeValue(forKey: id)
    }

    // MARK: - RPC Calls

    public func call<R: Decodable>(_ method: ColmeiaMethod, expecting: R.Type) async throws -> R {
        try await call(method, params: JSONValue.object([:]), expecting: expecting)
    }

    public func call<R: Decodable>(_ method: ColmeiaMethod, params: some Encodable, expecting: R.Type) async throws -> R {
        let encoded = try JSONValue(encoding: params)
        let rawResult = try await callWithOfflineQueue(method: method, params: encoded)
        return try rawResult.decode(as: R.self)
    }

    @discardableResult
    public func call(_ method: ColmeiaMethod, params: some Encodable) async throws -> JSONValue {
        try await callWithOfflineQueue(method: method, params: JSONValue(encoding: params))
    }

    public func callRaw(method: String, params: JSONValue?) async throws -> JSONValue {
        guard let socketClient else {
            throw ProtocolError(name: .internal_error, message: "HubConnection não está conectado ao Hub remoto (\(hubURL))")
        }
        return try await socketClient.callRaw(method: method, params: params)
    }

    // MARK: - Reconnection Loop

    private func runLoop() async {
        reconnectAttempt = 0
        while !Task.isCancelled {
            do {
                status = reconnectAttempt == 0 ? .conectando : .reconectando(tentativa: reconnectAttempt)
                try await connectAndListen()
            } catch {
                lastConnectionError = error.localizedDescription
                disconnectWebSocket()
            }

            if Task.isCancelled { break }
            reconnectAttempt += 1
            status = .reconectando(tentativa: reconnectAttempt)
            let delaySeconds = min(30.0, pow(2.0, Double(reconnectAttempt - 1)))
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
    }

    private func connectAndListen() async throws {
        let client = SocketClient()
        try client.connect(to: hubURL)
        socketClient = client

        let author = Author.humano(InstallationIdentity.current().string)
        status = .conectado
        let helloResult: HelloResult
        do {
            helloResult = try await client.hello(client: "canvas-ui", author: author, token: hubToken)
        } catch {
            status = .conectando
            throw error
        }

        engineVersion = helloResult.engineVersion
        lastConnectionError = nil
        reconnectAttempt = 0
        await replayOutboxes()
        await onConnected?()

        for await event in client.events {
            onEvent?(event)
            for observer in eventObservers.values { observer(event) }
        }
    }

    private func disconnectWebSocket() {
        socketClient?.close()
        socketClient = nil
    }

    private func callWithOfflineQueue(method: ColmeiaMethod, params: JSONValue) async throws -> JSONValue {
        let requestID = "offline-\(ULID.generate().string)"
        do {
            guard let socketClient else {
                throw SocketClientError.notConnected
            }
            return try await socketClient.callRaw(
                method: method.rawValue, params: params, requestID: requestID)
        } catch {
            guard Self.isTransportFailure(error), Self.isQueueable(method),
                  let roomID = Self.roomID(from: params) else { throw error }
            do {
                let data = try ColmeiaJSON.encoder().encode(params)
                let outbox = outbox(for: roomID)
                _ = try outbox.enqueue(method: method, paramsJSON: data, requestID: requestID)
                refreshOutboxCount()
            } catch {
                // Preserva o erro original de transporte: não fingimos que a
                // intenção foi persistida se o disco também falhou.
            }
            throw error
        }
    }

    private func outbox(for roomID: ULID) -> HubOutbox {
        if let existing = outboxes[roomID] { return existing }
        let created = HubOutbox(roomID: roomID, paths: outboxPaths)
        outboxes[roomID] = created
        return created
    }

    private func loadPersistedOutboxes() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: outboxPaths.roomsDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            guard let roomID = ULID(entry.lastPathComponent) else { continue }
            let outbox = HubOutbox(roomID: roomID, paths: outboxPaths)
            if outbox.pendingCount > 0 { outboxes[roomID] = outbox }
        }
        refreshOutboxCount()
    }

    private func refreshOutboxCount() {
        pendingOutboxCount = outboxes.values.reduce(0) { $0 + $1.pendingCount }
    }

    private func replayOutboxes() async {
        let pending = outboxes.values.flatMap { outbox in
            outbox.pending().map { (outbox, $0) }
        }
        for (outbox, entry) in pending {
            guard let params = try? ColmeiaJSON.decoder().decode(JSONValue.self, from: entry.paramsJSON) else {
                try? outbox.markFailure(id: entry.id, error: "payload JSON inválido")
                continue
            }
            do {
                _ = try await socketClientCall(
                    method: entry.method.rawValue,
                    params: params,
                    requestID: entry.requestID)
                try outbox.remove(id: entry.id)
            } catch {
                try? outbox.markFailure(id: entry.id, error: error.localizedDescription)
                if Self.isTransportFailure(error) { break }
            }
        }
        refreshOutboxCount()
    }

    private func socketClientCall(
        method: String,
        params: JSONValue,
        requestID: String?
    ) async throws -> JSONValue {
        guard let socketClient else { throw SocketClientError.notConnected }
        return try await socketClient.callRaw(method: method, params: params, requestID: requestID)
    }

    private static func roomID(from params: JSONValue) -> ULID? {
        guard case .object(let object) = params,
              case .string(let value) = object["room_id"] else { return nil }
        return ULID(value)
    }

    private static func isTransportFailure(_ error: Error) -> Bool {
        if error is SocketClientError { return true }
        return false
    }

    private static func isQueueable(_ method: ColmeiaMethod) -> Bool {
        switch method {
        case .roomLeave, .roomDelete, .roomUpdate,
             .memberInvite, .memberInviteRevoke, .memberUpdate, .memberRemove,
             .agentSessionCreate, .agentSessionUpdate,
             .sessionEventAppend, .grantIssue, .grantRevoke,
             .missionCreate, .missionUpdate, .missionTransition,
             .workstreamCreate, .workstreamUpdate, .workstreamTransition,
             .decisionCreate, .decisionDecide, .decisionSupersede, .decisionCancel,
             .relationAdd, .relationRemove, .roomLayoutUpdate,
             .executionJobCreate, .executionJobTransition:
            return true
        default:
            return false
        }
    }
}

extension Notification.Name {
    static let colmeiaHubConfigurationChanged = Notification.Name("colmeia.hub.configuration.changed")
}
