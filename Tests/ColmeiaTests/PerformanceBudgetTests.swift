import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

// Benchmarks estáveis e sem GUI (§21/§25.8). Eles medem apenas o que este
// runner consegue controlar: socket do engine e troca de andar. FPS, RAM da UI
// e tecla→eco visual continuam validação manual documentada no README.
private func performanceRoot() -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cperf-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func milliseconds(since start: Date) -> Double {
    Date().timeIntervalSince(start) * 1_000
}

private func percentile95(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
}

private func performanceGit(_ args: [String], cwd: URL) throws {
    let result = Git.run(args, cwd: cwd.path)
    guard result.status == 0 else {
        throw NSError(
            domain: "PerformanceBudgetTests", code: Int(result.status),
            userInfo: [NSLocalizedDescriptionKey: result.stderr])
    }
}

@Suite("Orçamento de performance sem GUI (§21.1)", .serialized)
struct PerformanceBudgetTests {
    @Test func coldBootDoEngineFicaAbaixoDeDoisSegundos() throws {
        var samples: [Double] = []
        for _ in 0..<3 {
            let root = performanceRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let engine = Engine(paths: ColmeiaPaths(root: root))
            let start = Date()
            try engine.start()
            samples.append(milliseconds(since: start))
            engine.stop()
        }
        let worst = samples.max() ?? .infinity
        print(String(format: "BENCH engine_cold_boot_max_ms=%.2f samples=%@", worst, String(describing: samples)))
        // É o boot do daemon até o socket aceitar clientes; o tempo de canvas UI
        // continua fora deste harness (AppKit/SwiftUI não roda no test runner).
        #expect(worst < 2_000, "cold boot do engine excedeu 2 s: \(worst) ms")
    }

    @Test func trocaDeAndarP95FicaAbaixoDeCemMilissegundos() async throws {
        let root = performanceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try performanceGit(["init", "-b", "main"], cwd: repo)
        try performanceGit(["config", "user.email", "bench@example.invalid"], cwd: repo)
        try performanceGit(["config", "user.name", "Benchmark"], cwd: repo)
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        try performanceGit(["add", "."], cwd: repo)
        try performanceGit(["commit", "-m", "initial"], cwd: repo)

        let paths = ColmeiaPaths(root: root)
        let engine = Engine(paths: paths)
        try engine.start()
        defer { engine.stop() }
        let client = SocketClient()
        try client.connect(to: paths.engineSocket.path)
        defer { client.close() }
        _ = try await client.hello(client: "performance")
        let workspace = try await client.call(
            .workspaceCreate,
            params: WorkspaceCreateParams(nome: "bench", caminhoRaiz: repo.path),
            expecting: WorkspaceResult.self).workspace
        let floor = try await client.call(
            .floorCreate, params: FloorCreateParams(workspaceID: workspace.id, nome: "latency"),
            expecting: FloorResult.self).floor

        // Warm-up de socket e escrita do primeiro floors.json; as 24 trocas
        // seguintes representam a interação já aberta na UI.
        _ = try await client.call(
            .floorSwitch,
            params: FloorSwitchParams(workspaceID: workspace.id, floorID: floor.id, viewport: Viewport()),
            expecting: FloorSwitchResult.self)
        var samples: [Double] = []
        for index in 0..<24 {
            let target: ULID? = index.isMultiple(of: 2) ? nil : floor.id
            let start = Date()
            _ = try await client.call(
                .floorSwitch,
                params: FloorSwitchParams(
                    workspaceID: workspace.id, floorID: target,
                    viewport: Viewport(x: Double(index), y: 0, zoom: 1)),
                expecting: FloorSwitchResult.self)
            samples.append(milliseconds(since: start))
        }
        let p95 = percentile95(samples)
        print(String(format: "BENCH floor_switch_p95_ms=%.2f samples=%@", p95, String(describing: samples)))
        #expect(p95 < 100, "p95 de floor.switch excedeu 100 ms: \(p95) ms")
    }
}
