import Foundation
import ColmeiaKit

enum ConnectionStatus: Equatable {
    case conectando
    case conectado
    case reconectando(tentativa: Int)
}

/// Cliente único do engine para toda a UI (§4.1): reconexão com backoff 1s→30s (§22.5),
/// lançamento do engine quando ausente e fan-out do stream de eventos (o AsyncStream do
/// SocketClient é de consumidor único).
@MainActor
final class EngineConnection: ObservableObject {
    @Published private(set) var status: ConnectionStatus = .conectando

    /// Eventos que não são `session.output` (baixa frequência) — consumidos pelo AppStore.
    var onEvent: ((EventMessage) -> Void)?
    /// Chamado a cada (re)conexão bem-sucedida, após o hello — re-subscribe/re-attach.
    var onConnected: (() async -> Void)?
    /// Rota quente: chunk de terminal direto para o controller da sessão.
    private var outputHandlers: [ULID: (SessionOutputTopicPayload) -> Void] = [:]

    private var client: SocketClient?
    private var loopTask: Task<Void, Never>?
    private var engineLaunched = false
    private let socketPath: String

    init(socketPath: String = ColmeiaPaths.socketPath()) {
        self.socketPath = socketPath
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { await runLoop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        client?.close()
        client = nil
    }

    func registerOutputHandler(session: ULID, _ handler: @escaping (SessionOutputTopicPayload) -> Void) {
        outputHandlers[session] = handler
    }

    func unregisterOutputHandler(session: ULID) {
        outputHandlers[session] = nil
    }

    // MARK: - Chamadas

    var isConnected: Bool { status == .conectado }

    func call<R: Decodable>(_ method: ColmeiaMethod, params: some Encodable, expecting: R.Type) async throws -> R {
        guard let client else { throw SocketClientError.notConnected }
        return try await client.call(method, params: params, expecting: expecting)
    }

    func call<R: Decodable>(_ method: ColmeiaMethod, expecting: R.Type) async throws -> R {
        guard let client else { throw SocketClientError.notConnected }
        return try await client.call(method, expecting: expecting)
    }

    @discardableResult
    func call(_ method: ColmeiaMethod, params: some Encodable) async throws -> JSONValue {
        guard let client else { throw SocketClientError.notConnected }
        return try await client.call(method, params: params)
    }

    // MARK: - Loop de conexão

    private func runLoop() async {
        var tentativa = 0
        while !Task.isCancelled {
            let candidate = SocketClient()
            do {
                try candidate.connect(to: socketPath)
                _ = try await candidate.hello(client: "canvas-ui")
                client = candidate
                tentativa = 0
                engineLaunched = false
                status = .conectado
                await onConnected?()
                for await event in candidate.events {
                    route(event)
                }
            } catch {
                candidate.close()
            }
            client = nil
            if Task.isCancelled { break }
            tentativa += 1
            status = .reconectando(tentativa: tentativa)
            if !engineLaunched {
                engineLaunched = launchEngine()
            }
            let delay = min(30.0, pow(2.0, Double(tentativa - 1)))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func route(_ event: EventMessage) {
        if event.knownTopic == .sessionOutput,
           let payload = try? event.decodeParams(SessionOutputTopicPayload.self) {
            outputHandlers[payload.sessionID]?(payload)
            return
        }
        onEvent?(event)
    }

    // MARK: - Lançamento do engine (ordem da tarefa: app → .build do projeto → PATH)

    private func launchEngine() -> Bool {
        guard let binary = Self.findEngineBinary() else { return false }
        let process = Process()
        process.executableURL = binary
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    static func findEngineBinary() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let exec = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exec.deletingLastPathComponent().appendingPathComponent("colmeia-engine"))
        }
        candidates.append(
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("app/colmeia-canvas/.build/arm64-apple-macosx/debug/colmeia-engine")
        )
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("colmeia-engine"))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
