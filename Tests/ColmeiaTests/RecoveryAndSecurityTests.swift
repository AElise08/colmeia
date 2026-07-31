import Foundation
import Testing
import ColmeiaKit
import ColmeiaHub

@Suite("Recuperação, diagnóstico e limites remotos")
struct RecoveryAndSecurityTests {
    @Test func rateLimiterImpedeBurstEBytesExcessivos() {
        let limiter = HubRateLimiter(maxRequestsPerSecond: 2, maxBytesPerSecond: 10, maxRequestBytes: 8)
        let now = Date(timeIntervalSince1970: 100)
        #expect(limiter.allow(bytes: 4, now: now))
        #expect(limiter.allow(bytes: 4, now: now.addingTimeInterval(0.1)))
        #expect(!limiter.allow(bytes: 1, now: now.addingTimeInterval(0.2)))
        #expect(!limiter.allow(bytes: 9, now: now.addingTimeInterval(1.1)))
        #expect(limiter.allow(bytes: 2, now: now.addingTimeInterval(1.1)))
    }

    @Test func diagnosticoNaoSerializaPayloadDeOperacaoNemPathPrivado() throws {
        let workspaceID = ULID.generate()
        let node = TerminalNode(
            id: ULID.generate(), posicao: Ponto(x: 0, y: 0), tamanho: Tamanho(w: 300, h: 200),
            criadoEm: Date(), nome: "Alfa", adapter: "shell",
            comandoOverride: "cat segredo.txt", cwd: "/Users/private/project")
        let workspace = Workspace(
            id: workspaceID, nome: "diagnostico", caminhoRaiz: "/Users/private/project",
            criadoEm: Date(), atualizadoEm: Date())
        let snapshot = DocumentSnapshot(
            workspaceID: workspaceID, seq: 1, nodes: [.terminal(node)], connections: [], criadoEm: Date(),
            noteContents: ["private": "token-super-secreto"])
        let op = DocOp(
            opID: ULID.generate(), seq: 1, author: .humanoLocal, ts: Date(),
            payload: .nodeAdd(NodeAddOpPayload(node: .terminal(node))))
        let diagnostic = WorkspaceDiagnostic(
            workspace: workspace,
            health: WorkspaceHealth(
                workspaceID: workspaceID, state: .recoverable, message: "snapshot reparado",
                snapshotAvailable: true, journalAvailable: true, quarantineAvailable: true),
            snapshot: snapshot, operations: [op], sessions: [])
        let data = try ColmeiaJSON.encoder().encode(diagnostic)
        let string = String(decoding: data, as: UTF8.self)
        #expect(!string.contains("cat segredo.txt"))
        #expect(!string.contains("/Users/private/project"))
        #expect(!string.contains("token-super-secreto"))
        #expect(string.contains("node.add"))
        #expect(diagnostic.operations.first?.hasUndoData == false)
    }
}
