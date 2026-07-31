import Foundation
import Testing
import ColmeiaKit

struct WorkspaceArchiveTests {
    @Test func exportacaoRemoveRuntimeSegredosEImportacaoReidentificaWorkspace() throws {
        let workspaceID = ULID.generate()
        let terminal = TerminalNode(
            id: ULID.generate(), posicao: Ponto(x: 1, y: 2), tamanho: Tamanho(w: 320, h: 240), criadoEm: Date(),
            nome: "Agent", adapter: "shell", comandoOverride: "TOKEN=secret",
            cwd: "/Users/private/project", sessionID: ULID.generate())
        let note = NotaNode(
            id: ULID.generate(), posicao: Ponto(x: 4, y: 5), tamanho: Tamanho(w: 200, h: 160), criadoEm: Date(),
            arquivo: "notes/note.md", cor: "yellow")
        let workspace = Workspace(
            id: workspaceID, nome: "Original", caminhoRaiz: "/Users/private/project",
            criadoEm: Date(), atualizadoEm: Date())
        let snapshot = DocumentSnapshot(
            workspaceID: workspaceID, seq: 3, nodes: [.terminal(terminal), .nota(note)],
            connections: [], criadoEm: Date(), noteContents: [note.id.string: "# Nota"])
        let archive = WorkspaceArchive(workspace: workspace, snapshot: snapshot)

        #expect(archive.workspace.caminhoRaiz == nil)
        guard case .terminal(let exportedTerminal) = archive.snapshot.nodes[0] else {
            Issue.record("terminal não exportado")
            return
        }
        #expect(exportedTerminal.cwd == ".")
        #expect(exportedTerminal.comandoOverride == nil)
        #expect(exportedTerminal.sessionID == nil)

        let importedID = ULID.generate()
        let imported = archive.reidentified(workspaceID: importedID, name: "Cópia")
        #expect(imported.workspace.id == importedID)
        #expect(imported.workspace.nome == "Cópia")
        #expect(imported.snapshot.workspaceID == importedID)
        #expect(imported.snapshot.noteContents?[note.id.string] == "# Nota")
    }

    @Test func arquivoRoundTripERejeitaSchemaDesconhecido() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("colmeia-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspaceID = ULID.generate()
        let archive = WorkspaceArchive(
            workspace: Workspace(id: workspaceID, nome: "Roundtrip", criadoEm: Date(), atualizadoEm: Date()),
            snapshot: DocumentSnapshot(workspaceID: workspaceID, seq: 0, nodes: [], connections: [], criadoEm: Date()))
        let url = root.appendingPathComponent("workspace.json")
        try archive.write(to: url)
        let restored = try WorkspaceArchive.read(from: url)
        #expect(restored.schemaVersion == WorkspaceArchive.currentSchemaVersion)
        #expect(restored.workspace.id == archive.workspace.id)
        #expect(restored.workspace.nome == archive.workspace.nome)
        #expect(restored.snapshot.workspaceID == archive.snapshot.workspaceID)
        #expect(restored.snapshot.nodes == archive.snapshot.nodes)
    }
}
