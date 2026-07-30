import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

// Esta suíte usa um repositório git real; as operações passam pelo socket do
// Engine para cobrir o contrato público de §16/§25.6, não handlers privados.
private func floorTestRoot() -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cfloor-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func floorGit(_ args: [String], cwd: URL) throws {
    let result = Git.run(args, cwd: cwd.path)
    guard result.status == 0 else {
        throw NSError(
            domain: "FloorsRealGitTests", code: Int(result.status),
            userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(result.stderr)"])
    }
}

private func makeFloorRepo(in root: URL) throws -> URL {
    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try floorGit(["init", "-b", "main"], cwd: repo)
    try floorGit(["config", "user.email", "colmeia-tests@example.invalid"], cwd: repo)
    try floorGit(["config", "user.name", "Colmeia Tests"], cwd: repo)
    try Data("base\n".utf8).write(to: repo.appendingPathComponent("README.md"))
    try floorGit(["add", "."], cwd: repo)
    try floorGit(["commit", "-m", "initial"], cwd: repo)
    return repo
}

private func bootFloorEngine(_ root: URL) throws -> (Engine, SocketClient) {
    let paths = ColmeiaPaths(root: root)
    let engine = Engine(paths: paths)
    try engine.start()
    let client = SocketClient()
    try client.connect(to: paths.engineSocket.path)
    return (engine, client)
}

private func createFloorWorkspace(_ client: SocketClient, repo: URL) async throws -> ULID {
    _ = try await client.hello(client: "floors-real-git")
    let created = try await client.call(
        .workspaceCreate,
        params: WorkspaceCreateParams(nome: "repo", caminhoRaiz: repo.path),
        expecting: WorkspaceResult.self)
    return created.workspace.id
}

@Suite("Andares com git real (§16/§25.6.1–25.6.3)", .serialized)
struct FloorsRealGitTests {
    @Test func workspaceNovoUsaCloneGerenciadoEPersisteTrocaComTerreo() async throws {
        let root = floorTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var boot = try bootFloorEngine(root)
        _ = try await boot.1.hello(client: "floors-new-workspace")
        let workspace = try await boot.1.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "novo"), expecting: WorkspaceResult.self).workspace

        let floor = try await boot.1.call(
            .floorCreate, params: FloorCreateParams(workspaceID: workspace.id, nome: "explorar"),
            expecting: FloorResult.self).floor
        #expect(floor.mecanismo == .apfsClone)
        #expect(floor.branch == nil)
        #expect(FileManager.default.fileExists(atPath: floor.caminho))

        let entered = try await boot.1.call(
            .floorSwitch, params: FloorSwitchParams(workspaceID: workspace.id, floorID: floor.id),
            expecting: FloorSwitchResult.self)
        #expect(try #require(entered.floor).id == floor.id)
        let base = try await boot.1.call(
            .floorSwitch, params: FloorSwitchParams(workspaceID: workspace.id, floorID: nil),
            expecting: FloorSwitchResult.self)
        #expect(base.floor == nil)
        let opened = try await boot.1.call(
            .workspaceOpen, params: WorkspaceOpenParams(id: workspace.id), expecting: WorkspaceOpenResult.self)
        #expect(opened.workspace.caminhoRaiz != nil)

        boot.1.close()
        boot.0.stop()
        boot = try bootFloorEngine(root)
        defer { boot.1.close(); boot.0.stop() }
        _ = try await boot.1.hello(client: "floors-new-workspace-reopen")
        let listed = try await boot.1.call(
            .floorList, params: FloorListParams(workspaceID: workspace.id), expecting: FloorListResult.self)
        let persisted = try #require(listed.first(where: { $0.id == floor.id }))
        #expect(persisted.mecanismo == .apfsClone)
        #expect(persisted.estado == .ativo)
        let switchedAgain = try await boot.1.call(
            .floorSwitch, params: FloorSwitchParams(workspaceID: workspace.id, floorID: floor.id),
            expecting: FloorSwitchResult.self)
        #expect(try #require(switchedAgain.floor).id == floor.id)
        _ = try await boot.1.call(
            .floorDiscard, params: FloorDiscardParams(floorID: floor.id, confirmar: true))
        #expect(!FileManager.default.fileExists(atPath: floor.caminho))
    }

    @Test func createAlternaEAtterrissaPreservandoBranch() async throws {
        let root = floorTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeFloorRepo(in: root)
        let (engine, client) = try bootFloorEngine(root)
        defer { client.close(); engine.stop() }
        let wsID = try await createFloorWorkspace(client, repo: repo)

        let created = try await client.call(
            .floorCreate,
            params: FloorCreateParams(workspaceID: wsID, nome: "review-42"),
            expecting: FloorResult.self)
        #expect(created.floor.estado == .ativo)
        #expect(created.floor.mecanismo == .gitWorktree)
        #expect(FileManager.default.fileExists(atPath: created.floor.caminho))
        #expect(created.floor.branch == "andar/review-42")

        let viewportBase = Viewport(x: 11, y: 22, zoom: 1.25)
        let switched = try await client.call(
            .floorSwitch, params: FloorSwitchParams(floorID: created.floor.id, viewport: viewportBase),
            expecting: FloorSwitchResult.self)
        #expect(try #require(switched.floor).id == created.floor.id)
        let reopened = try await client.call(
            .workspaceOpen, params: WorkspaceOpenParams(id: wsID), expecting: WorkspaceOpenResult.self)
        #expect(reopened.workspace.viewport == viewportBase)

        // O vínculo explícito no start elimina a ambiguidade que o documento
        // original tinha: o TerminalNode pertence ao floor, não só o seu cwd.
        let node = TerminalNode(
            id: ULID.generate(), posicao: Ponto(x: 10, y: 10), tamanho: Tamanho(w: 400, h: 300),
            criadoEm: Date(), nome: "terminal-do-andar", adapter: "shell",
            comandoOverride: "exit 0", cwd: created.floor.caminho)
        _ = try await client.call(
            .docApply,
            params: DocApplyParams(workspaceID: wsID, ops: [DocOp(
                opID: ULID.generate(), author: .humanoLocal, ts: Date(),
                payload: .nodeAdd(NodeAddOpPayload(node: .terminal(node))))]))
        _ = try await client.call(
            .sessionStart,
            params: SessionStartParams(workspaceID: wsID, nodeID: node.id, floorID: created.floor.id),
            expecting: SessionResult.self)
        let withNode = try await client.call(
            .floorList, params: FloorListParams(workspaceID: wsID), expecting: FloorListResult.self)
        #expect(try #require(withNode.first(where: { $0.id == created.floor.id })).nos.contains(node.id))

        let viewportFloor = Viewport(x: -60, y: 33, zoom: 0.8)
        let base = try await client.call(
            .floorSwitch, params: FloorSwitchParams(floorID: nil, viewport: viewportFloor),
            expecting: FloorSwitchResult.self)
        #expect(base.floor == nil)
        let afterBase = try await client.call(
            .floorList, params: FloorListParams(workspaceID: wsID), expecting: FloorListResult.self)
        let persistedFloor = try #require(afterBase.first(where: { $0.id == created.floor.id }))
        #expect(persistedFloor.viewport == viewportFloor)

        _ = try await client.call(
            .floorLand, params: FloorLandParams(floorID: created.floor.id, confirmar: true))
        #expect(!FileManager.default.fileExists(atPath: created.floor.caminho))
        let branch = Git.run(["branch", "--list", "andar/review-42"], cwd: repo.path)
        #expect(branch.status == 0)
        #expect(branch.stdout.contains("andar/review-42"))
    }

    @Test func aterrissagemSujaFalhaELimpaDepois() async throws {
        let root = floorTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeFloorRepo(in: root)
        let (engine, client) = try bootFloorEngine(root)
        defer { client.close(); engine.stop() }
        let wsID = try await createFloorWorkspace(client, repo: repo)
        let floor = try await client.call(
            .floorCreate, params: FloorCreateParams(workspaceID: wsID, nome: "dirty"), expecting: FloorResult.self).floor
        let dirtyFile = URL(fileURLWithPath: floor.caminho).appendingPathComponent("nao-commitado.txt")
        try Data("mudança\n".utf8).write(to: dirtyFile)

        do {
            _ = try await client.call(.floorLand, params: FloorLandParams(floorID: floor.id, confirmar: true))
            Issue.record("floor.land deveria recusar worktree sujo")
        } catch let error as ProtocolError {
            #expect(error.known == .floor_dirty)
        }
        try FileManager.default.removeItem(at: dirtyFile)
        _ = try await client.call(.floorLand, params: FloorLandParams(floorID: floor.id, confirmar: true))
        #expect(!FileManager.default.fileExists(atPath: floor.caminho))
    }

    @Test func reconciliacaoEncontraOrfaoEReadocaoORecupera() async throws {
        let root = floorTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeFloorRepo(in: root)
        let paths = ColmeiaPaths(root: root)
        var boot = try bootFloorEngine(root)
        let wsID = try await createFloorWorkspace(boot.1, repo: repo)
        let original = try await boot.1.call(
            .floorCreate, params: FloorCreateParams(workspaceID: wsID, nome: "perdido"), expecting: FloorResult.self).floor
        boot.1.close()
        boot.0.stop()

        // Simula perda apenas do registro: o worktree real continua no disco.
        try AtomicJSON.write([Floor](), to: paths.floorsFile(wsID))
        boot = try bootFloorEngine(root)
        defer { boot.1.close(); boot.0.stop() }
        _ = try await boot.1.hello(client: "floors-reconcile")
        let listed = try await boot.1.call(
            .floorList, params: FloorListParams(workspaceID: wsID), expecting: FloorListResult.self)
        let orphan = try #require(listed.first(where: { $0.caminho == original.caminho }))
        #expect(orphan.estado == .orfao)

        let adopted = try await boot.1.call(
            .floorSwitch, params: FloorSwitchParams(floorID: orphan.id), expecting: FloorSwitchResult.self)
        #expect(try #require(adopted.floor).estado == .ativo)
    }
}
