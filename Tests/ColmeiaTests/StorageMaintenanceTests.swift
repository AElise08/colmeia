import Foundation
import Darwin
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

private func storageTempRoot() -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("colm-storage-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func storageWorkspace(_ root: URL) throws -> WorkspaceState {
    let now = Date()
    return try WorkspaceState(
        paths: ColmeiaPaths(root: root),
        workspace: Workspace(id: ULID.generate(), nome: "storage", criadoEm: now, atualizadoEm: now)
    )
}

private func storageNode(_ name: String) -> TerminalNode {
    TerminalNode(
        id: ULID.generate(), posicao: Ponto(x: 1, y: 2), tamanho: Tamanho(w: 300, h: 200),
        criadoEm: Date(), nome: name, adapter: "shell", cwd: NSHomeDirectory()
    )
}

@Suite("Manutenção de armazenamento")
struct StorageMaintenanceTests {
    @Test func rotacaoPreservaSeqReplayEAuditoria() throws {
        let root = storageTempRoot()
        let journalURL = root.appendingPathComponent("s.jsonl")
        let journal = try SessionJournal(
            url: journalURL, policy: JournalStoragePolicy(maxActiveBytes: 1 * 1024 * 1024)
        )
        _ = journal.append(.resize(ResizeEventPayload(cols: 120, rows: 32)), author: .sistema)
        let chunk = Data(repeating: 0x61, count: 650 * 1024).base64EncodedString()
        _ = journal.append(.output(OutputEventPayload(dataB64: chunk)), author: .agente("a"))
        _ = journal.append(.output(OutputEventPayload(dataB64: chunk)), author: .agente("a"))
        // As duas saídas excedem o limite e vão ao archive; resize permanece ativo.
        let active = try String(contentsOf: journalURL, encoding: .utf8)
        #expect(active.contains("resize"))
        #expect(!active.contains("data_b64"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("s.scrollback").path))
        _ = journal.append(.system(SystemEventPayload(name: "ok", message: "auditável")), author: .sistema)
        journal.seal()
        let replay = JournalReader.read(url: journalURL, repair: false)
        #expect(!replay.corrupted)
        #expect(replay.events.map(\.seq) == [1, 2, 3, 4])
        #expect(replay.events[0].tipo == .resize)
        #expect(replay.events[3].tipo == .system)
    }

    @Test func compactacaoMantemReconstrucaoMesmoSemOpsRetidas() throws {
        let root = storageTempRoot()
        let state = try storageWorkspace(root)
        let node = storageNode("compact")
        let old = Date(timeIntervalSinceNow: -2 * 86_400)
        let op = DocOp(opID: ULID.generate(), author: .humanoLocal, ts: old,
                       payload: .nodeAdd(NodeAddOpPayload(node: .terminal(node))))
        _ = try state.applyProposal(op, liveNodeIDs: [])
        try state.compactDocument(now: Date(), retainSince: Date())
        let paths = ColmeiaPaths(root: root)
        #expect((try Data(contentsOf: paths.documentFile(state.workspace.id))).isEmpty)
        let reloaded = try WorkspaceState(paths: paths, workspace: state.workspace)
        #expect(reloaded.seq == 1)
        #expect(reloaded.nodes[node.id] != nil)
    }

    @Test func atomicWriteComDiscoCheioSimuladoPreservaVersaoAnterior() throws {
        defer { StorageHealth.shared.resetForTesting() }
        let url = storageTempRoot().appendingPathComponent("value.json")
        try AtomicJSON.write(["versao": 1], to: url)
        StorageFaultInjection.failNextWriteForTesting(errno: ENOSPC, operationContaining: "write value.json")
        #expect(throws: EngineFailure.self) {
            try AtomicJSON.write(["versao": 2], to: url)
        }
        let previous = try AtomicJSON.read([String: Int].self, from: url)
        #expect(previous["versao"] == 1)
    }

    @Test func configIgnoraCampoFuturoEValidaLimites() throws {
        let root = storageTempRoot()
        let paths = ColmeiaPaths(root: root)
        try paths.ensureRootLayout()
        let json = """
        {"schema_version":1,"journal_max_active_bytes":0,
         "closed_journal_retention_days":0,"campo_do_futuro":{"ok":true}}
        """
        try json.data(using: .utf8)!.write(to: paths.configFile)
        let loaded = EngineConfig.load(from: paths)
        #expect(loaded.warning != nil)
        #expect(loaded.config.journalMaxActiveBytes == EngineConfig.default.journalMaxActiveBytes)
        #expect(loaded.config.closedJournalRetentionDays == 30)
    }

    @Test func retencaoNuncaApagaSessaoRecenteENemSemData() throws {
        let root = storageTempRoot()
        let paths = ColmeiaPaths(root: root)
        let ws = ULID.generate()
        try paths.ensureWorkspaceLayout(ws)
        let oldID = ULID.generate()
        let newID = ULID.generate()
        let unknownID = ULID.generate()
        func meta(_ id: ULID, ended: Date?) -> Session {
            Session(id: id, workspaceID: ws, nodeID: ULID.generate(), adapter: "shell", estado: .encerrada,
                    journal: paths.sessionJournal(workspace: ws, session: id).path, iniciadaEm: Date(),
                    encerradaEm: ended, cols: 80, rows: 24)
        }
        for value in [meta(oldID, ended: Date(timeIntervalSinceNow: -31 * 86_400)),
                      meta(newID, ended: Date(timeIntervalSinceNow: -29 * 86_400)),
                      meta(unknownID, ended: nil)] {
            try AtomicJSON.write(value, to: paths.sessionMeta(workspace: ws, session: value.id))
            try Data("{}\n".utf8).write(to: paths.sessionJournal(workspace: ws, session: value.id))
        }
        let removed = SessionRetention.pruneClosedJournals(paths: paths, retentionDays: 30)
        #expect(removed.map(\.sessionID) == [oldID])
        #expect(!FileManager.default.fileExists(atPath: paths.sessionMeta(workspace: ws, session: oldID).path))
        #expect(FileManager.default.fileExists(atPath: paths.sessionMeta(workspace: ws, session: newID).path))
        #expect(FileManager.default.fileExists(atPath: paths.sessionMeta(workspace: ws, session: unknownID).path))
    }
}
