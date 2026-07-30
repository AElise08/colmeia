import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

// §3.3/§6.3 — reciclagem do engine desatualizado. A comparação no cliente é
// `engine_version != ColmeiaVersion.string`; estes testes prendem os dois lados:
// o hello carrega a MESMA constante do Kit (fonte de verdade única — se divergir,
// o banner da UI dispararia contra um engine recém-buildado) e o fluxo
// shutdown→respawn→reconexão funciona contra um engine REAL em raiz temporária.

// Raiz temporária CURTA: sockaddr_un limita o path do socket a ~104 bytes.
private func tempRoot() -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("colm-rec-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Binário real do engine, buildado junto com os testes (SPM builda o pacote inteiro).
private func engineBinary() -> URL? {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ColmeiaTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // raiz do pacote
    let candidato = packageRoot.appendingPathComponent(".build/debug/colmeia-engine")
    return FileManager.default.isExecutableFile(atPath: candidato.path) ? candidato : nil
}

private func spawnEngine(_ binario: URL, root: URL) throws -> Process {
    let process = Process()
    process.executableURL = binario
    process.arguments = ["--root", root.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

/// Conexão com retry curto — o engine recém-spawnado sobe em <1s (§21.1).
private func conectar(root: URL, timeout: TimeInterval = 5) async throws -> SocketClient {
    let socket = ColmeiaPaths(root: root).engineSocket.path
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let client = SocketClient()
        do {
            try client.connect(to: socket)
            return client
        } catch {
            client.close()
            if Date() > deadline { throw error }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

private func aguardarSaida(_ process: Process, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return true
}

@Suite("Reciclagem do engine (§3.3/§6.3)", .serialized)
struct EngineRecycleTests {
    /// O lado "engine" da comparação de versão vem da MESMA constante do Kit que
    /// o app usa — hello divergente aqui significaria banner falso em produção.
    @Test func helloCarregaAVersaoDoKit() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Engine(paths: ColmeiaPaths(root: root))
        try engine.start()
        defer { engine.stop() }
        let client = SocketClient()
        try client.connect(to: ColmeiaPaths(root: root).engineSocket.path)
        let hello = try await client.hello(client: "test")
        #expect(hello.engineVersion == ColmeiaVersion.string)
        client.close()
    }

    @Test func shutdownSemConfirmarERecusado() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Engine(paths: ColmeiaPaths(root: root))
        try engine.start()
        defer { engine.stop() }
        let client = SocketClient()
        try client.connect(to: ColmeiaPaths(root: root).engineSocket.path)
        _ = try await client.hello(client: "test")
        do {
            _ = try await client.call(.engineShutdown, params: EngineShutdownParams(confirmar: false))
            Issue.record("shutdown sem confirmar deveria ser recusado")
        } catch let error as ProtocolError {
            #expect(error.known == .confirmation_required)
        }
        client.close()
    }

    /// O núcleo da reciclagem, contra o binário real (o shutdown confirmado dá
    /// exit(0) — não pode rodar in-process no runner de testes): shutdown
    /// gracioso responde ok E o processo desce; respawn na mesma raiz aceita
    /// nova conexão e o hello volta a reportar a versão.
    @Test func fluxoShutdownRespawnReconecta() async throws {
        let binario = try #require(engineBinary(), ".build/debug/colmeia-engine ausente — build do pacote incompleto")
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let velho = try spawnEngine(binario, root: root)
        defer { if velho.isRunning { velho.terminate() } }
        let cliente1 = try await conectar(root: root)
        let hello1 = try await cliente1.hello(client: "test")
        #expect(hello1.engineVersion == ColmeiaVersion.string)

        // passo 1 da reciclagem: shutdown gracioso confirmado → response ok, processo sai
        _ = try await cliente1.call(.engineShutdown, params: EngineShutdownParams(confirmar: true))
        cliente1.close()
        #expect(await aguardarSaida(velho, timeout: 5), "engine antigo não saiu após o shutdown")

        // passo 2: respawn do binário "novo" na MESMA raiz + reconexão + hello
        let novo = try spawnEngine(binario, root: root)
        defer { if novo.isRunning { novo.terminate() } }
        let cliente2 = try await conectar(root: root)
        let hello2 = try await cliente2.hello(client: "test")
        #expect(hello2.engineVersion == ColmeiaVersion.string)
        cliente2.close()
        novo.terminate()
        #expect(await aguardarSaida(novo, timeout: 5))
    }
}
