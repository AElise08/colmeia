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

    private var webSocketTask: URLSessionWebSocketTask?
    private var pendingRequests: [String: CheckedContinuation<ResponseMessage, Error>] = [:]
    private var requestCounter: UInt64 = 0
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
        guard let task = webSocketTask else {
            throw ProtocolError(name: .internal_error, message: "HubConnection não está conectado ao Hub remoto (\(hubURL))")
        }

        requestCounter += 1
        let reqID = "hub-\(requestCounter)-\(ULID.generate().string)"
        let requestMsg = RequestMessage(id: reqID, method: method, params: params)
        let envelope = Envelope.request(requestMsg)

        let data = try SocketFraming.encodeLine(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProtocolError(name: .internal_error, message: "Falha ao codificar mensagem para JSON")
        }

        let response: ResponseMessage = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[reqID] = continuation
            task.send(.string(text)) { [weak self] error in
                if let error {
                    Task { @MainActor [weak self] in
                        let orphan = self?.pendingRequests.removeValue(forKey: reqID)
                        orphan?.resume(throwing: error)
                    }
                }
            }
        }

        if response.ok {
            return response.result ?? .object([:])
        }
        throw response.error ?? ProtocolError(name: .internal_error, message: "response !ok sem error")
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
        var urlString = hubURL
        if !urlString.hasPrefix("ws://") && !urlString.hasPrefix("wss://") {
            urlString = "ws://" + urlString
        }
        guard let url = URL(string: urlString) else {
            throw ProtocolError(name: .invalid_params, message: "URL do Hub inválida: \(hubURL)")
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        let listenTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let ws = task as URLSessionWebSocketTask? else { break }
                do {
                    let message = try await ws.receive()
                    let data: Data
                    switch message {
                    case .string(let text):
                        data = Data(text.utf8)
                    case .data(let d):
                        data = d
                    @unknown default:
                        continue
                    }
                    self?.handleReceivedLine(data)
                } catch {
                    break
                }
            }
        }

        // Send Hello Handshake
        let author = Author.humano(InstallationIdentity.current().string)
        let helloParams = HelloParams(protocolVersion: ColmeiaVersion.protocolVersion, client: "canvas-ui", author: author)

        // Marcar temporariamente como conectado para permitir que hello passe pelo check
        status = .conectado

        let helloParamsWithToken = HelloParams(
            protocolVersion: helloParams.protocolVersion,
            client: helloParams.client,
            author: helloParams.author,
            token: hubToken)
        let helloResult: HelloResult
        do {
            helloResult = try await call(.hello, params: helloParamsWithToken, expecting: HelloResult.self)
        } catch {
            listenTask.cancel()
            status = .conectando
            throw error
        }

        engineVersion = helloResult.engineVersion
        lastConnectionError = nil
        reconnectAttempt = 0
        await onConnected?()

        _ = await listenTask.result
    }

    private func handleReceivedLine(_ data: Data) {
        guard let envelope = try? SocketFraming.decodeLine(Envelope.self, from: data) else { return }
        switch envelope {
        case .response(let response):
            if let continuation = pendingRequests.removeValue(forKey: response.id) {
                continuation.resume(returning: response)
            }
        case .event(let event):
            onEvent?(event)
            for observer in eventObservers.values { observer(event) }
        case .request:
            break
        }
    }

    private func disconnectWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        let orphans = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in orphans {
            continuation.resume(throwing: SocketClientError.connectionClosed)
        }
    }
}

extension Notification.Name {
    static let colmeiaHubConfigurationChanged = Notification.Name("colmeia.hub.configuration.changed")
}
