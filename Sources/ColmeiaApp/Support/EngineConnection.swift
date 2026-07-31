import Foundation
import AppKit
import Darwin
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

    /// `engine_version` do último hello (§6.3) — comparada com a versão do app.
    @Published private(set) var engineVersion: String?
    /// Reciclagem (§3.3) em curso: shutdown gracioso → respawn → reconexão.
    @Published private(set) var reciclandoEngine = false
    /// Falha na reciclagem (ex.: engine velho rejeitou o shutdown) — para a UI exibir.
    @Published var erroReciclagem: String?

    /// §3.3/§6.3 — engine sobreviveu a um upgrade dos binários: métodos novos
    /// falhariam silenciosamente. Não bloqueia o uso; a UI oferece a reciclagem.
    var engineDesatualizado: Bool {
        guard let engineVersion else { return false }
        return engineVersion != ColmeiaVersion.string
    }

    var appDesatualizado: Bool {
        guard let engineVersion else { return false }
        return ColmeiaVersion.compare(ColmeiaVersion.string, engineVersion) == .orderedAscending
    }

    /// Versão do próprio app (fonte de verdade única no Kit).
    var appVersion: String { ColmeiaVersion.string }

    /// Eventos que não são `session.output` (baixa frequência) — consumidos pelo AppStore.
    var onEvent: ((EventMessage) -> Void)?
    /// Chamado a cada (re)conexão bem-sucedida, após o hello — re-subscribe/re-attach.
    var onConnected: (() async -> Void)?
    /// Rota quente: chunk de terminal direto para o controller da sessão.
    private var outputHandlers: [ULID: (SessionOutputTopicPayload) -> Void] = [:]

    private var client: SocketClient?
    private var loopTask: Task<Void, Never>?
    /// Processo do engine lançado pelo app — nulo se engine externo ou já morto.
    private var engineProcess: Process?
    /// Última tentativa de spawn — o relançamento é limitado a 1×/2s (sem storm)
    /// e volta a tentar sozinho depois (necessário na reciclagem: o processo
    /// antigo ainda pode segurar o lock por um instante).
    private var lastEngineLaunch: Date = .distantPast
    private let socketPath: String
    /// Se true, stop() também mata o processo do engine.
    private var killEngineOnStop = true

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
        if killEngineOnStop, let proc = engineProcess {
            engineProcess = nil
            let pid = proc.processIdentifier
            ChildPIDTracker.remove(pid)
            guard proc.isRunning else { return }
            proc.terminate()
            let deadline = Date().addingTimeInterval(3)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(pid, SIGKILL)
                Thread.sleep(forTimeInterval: 0.1)
                var status: Int32 = 0
                waitpid(pid, &status, WNOHANG)
            }
        }
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
        var jaConectou = false
        while !Task.isCancelled {
            let candidate = SocketClient()
            do {
                try candidate.connect(to: socketPath)
                let hello = try await candidate.hello(client: "canvas-ui")
                client = candidate
                tentativa = 0
                jaConectou = true
                // §6.3 — engine_version não é decorativa: divergência da versão do
                // app aciona o banner de reciclagem (§3.3) na UI. Não bloqueia.
                engineVersion = hello.engineVersion
                status = .conectado

                // O stream precisa ser drenado enquanto o resync faz requests de
                // reattach. Se esperarmos o `onConnected` terminar, um replay de
                // journal grande enche o buffer de escrita do Engine antes de a UI
                // começar a consumir os eventos, disparando `client_backpressure`.
                let eventTask = Task { [weak self] in
                    for await event in candidate.events {
                        self?.route(event)
                    }
                }
                await onConnected?()
                await eventTask.value
            } catch {
                candidate.close()
            }
            client = nil
            if Task.isCancelled { break }
            tentativa += 1
            if Date().timeIntervalSince(lastEngineLaunch) > 2 {
                lastEngineLaunch = Date()
                _ = launchEngine()
            }
            let delay: Double
            if jaConectou {
                status = .reconectando(tentativa: tentativa)
                delay = min(30.0, pow(2.0, Double(tentativa - 1)))
            } else {
                // Cold start (§21.1): o engine recém-lançado sobe em <1s — tentar
                // rápido; o backoff 1s→30s (§22.5) é só para RE-conexão.
                status = .conectando
                delay = tentativa < 20 ? 0.25 : 1.0
            }
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

    // MARK: - Reciclagem do engine desatualizado (§3.3/§6.3)

    /// Shutdown gracioso (flush; sessões ativas ENCERRADAS — journals preservados,
    /// a UI avisa antes) seguido de respawn do binário novo. A reconexão fica com
    /// o runLoop: o hello seguinte re-verifica a versão e o banner some sozinho
    /// quando ela bate.
    func recycleEngine() async {
        guard !reciclandoEngine else { return }
        guard !appDesatualizado else {
            erroReciclagem = "O engine já é mais novo. Reabra o Colmeia para atualizar a interface."
            return
        }
        reciclandoEngine = true
        erroReciclagem = nil
        defer { reciclandoEngine = false }
        if let client {
            do {
                // Aguarda a response; a conexão CAIR antes dela também vale como
                // "desceu" (connectionClosed) — os dois caminhos seguem adiante.
                _ = try await client.call(.engineShutdown, params: EngineShutdownParams(confirmar: true))
            } catch let error as ProtocolError {
                // Engine respondeu recusando (ex.: velho demais para o método):
                // segue vivo segurando o lock — não adianta respawnar por cima.
                erroReciclagem = "engine recusou o shutdown: \(error.message)"
                return
            } catch {
                // Erro de transporte = engine caiu no meio — exatamente o que queríamos.
            }
            client.close()
        }
        client = nil
        engineVersion = nil
        // O processo antigo solta socket+lock ~200ms após a response (§6.4);
        // esperar um instante evita um spawn que morre em "já está rodando".
        try? await Task.sleep(nanoseconds: 500_000_000)
        lastEngineLaunch = Date()
        _ = launchEngine()

        // Spawn aceito não significa reciclagem concluída: só o novo hello
        // confirma que o daemon esperado realmente assumiu o socket.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if status == .conectado, engineVersion == ColmeiaVersion.string {
                erroReciclagem = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        erroReciclagem = "O engine não voltou a conectar. Tente reabrir o Colmeia."
    }

    /// Abre o bundle atual do disco antes de encerrar esta interface antiga.
    /// O engine permanece vivo; somente o processo visual é substituído.
    func relaunchApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.erroReciclagem = "Não foi possível reabrir o Colmeia: \(error.localizedDescription)"
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    // MARK: - Lançamento do engine (ordem da tarefa: app → .build do projeto → PATH)

    private func launchEngine() -> Bool {
        // Se já temos um engine vivo, não spawna outro
        if let existing = engineProcess, existing.isRunning { return true }
        guard let binary = Self.findEngineBinary() else { return false }
        let process = Process()
        process.executableURL = binary
        var arguments = ["--tcp-port", "9622"]
        if socketPath.hasSuffix("/engine.sock") {
            let root = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
            arguments = ["--root", root] + arguments
        }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.engineProcess = nil
            }
        }
        do {
            try process.run()
            engineProcess = process
            ChildPIDTracker.add(process.processIdentifier)
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
