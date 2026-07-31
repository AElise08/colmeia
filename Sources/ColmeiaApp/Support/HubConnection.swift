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

    public var onEvent: ((EventMessage) -> Void)?
    public var onConnected: (() async -> Void)?
    public var hubToken: String?

    private var socketClient: SocketClient?
    private var reconnectAttempt = 0
    private var loopTask: Task<Void, Never>?
    private var eventObservers: [UUID: (EventMessage) -> Void] = [:]

    public init(hubURL: String? = nil, token: String? = nil) {
        self.hubURL = hubURL ?? HubConnection.savedHubURL
        self.hubToken = token
            ?? HubConnection.savedHubToken
            ?? ProcessInfo.processInfo.environment["COLMEIA_HUB_TOKEN"]
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
        let rawResult = try await callRaw(method: method.rawValue, params: JSONValue(encoding: params))
        return try rawResult.decode(as: R.self)
    }

    @discardableResult
    public func call(_ method: ColmeiaMethod, params: some Encodable) async throws -> JSONValue {
        try await callRaw(method: method.rawValue, params: JSONValue(encoding: params))
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
}

extension Notification.Name {
    static let colmeiaHubConfigurationChanged = Notification.Name("colmeia.hub.configuration.changed")
}
