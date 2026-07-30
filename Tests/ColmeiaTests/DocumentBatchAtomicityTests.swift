import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

@Suite("Documento — atomicidade de lote (§7.1)", .serialized)
struct DocumentBatchAtomicityTests {
    @Test func propostaInvalidaNaoAplicaNemPersistePrefixo() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cbatch-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ColmeiaPaths(root: root)
        try paths.ensureRootLayout()

        let now = Date()
        let workspace = Workspace(
            id: ULID.generate(),
            nome: "atomic",
            criadoEm: now,
            atualizadoEm: now)
        let state = try WorkspaceState(paths: paths, workspace: workspace)
        let node = NotaNode(
            id: ULID.generate(),
            posicao: Ponto(x: 0, y: 0),
            tamanho: Tamanho(w: 200, h: 120),
            criadoEm: now,
            arquivo: "notes/\(ULID.generate().string).md",
            cor: "amarelo")
        let missing = ULID.generate()
        let connection = Connection(
            id: ULID.generate(),
            de: node.id,
            para: missing,
            semantica: .visual,
            estilo: .solida)
        let proposals = [
            DocOp(
                opID: ULID.generate(),
                author: .humanoLocal,
                ts: now,
                payload: .nodeAdd(NodeAddOpPayload(node: .nota(node)))),
            DocOp(
                opID: ULID.generate(),
                author: .humanoLocal,
                ts: now,
                payload: .connectionAdd(ConnectionAddOpPayload(connection: connection))),
        ]

        #expect(throws: ProtocolError.self) {
            _ = try state.applyBatch(proposals, liveNodeIDs: [])
        }
        #expect(state.seq == 0)
        #expect(state.nodes[node.id] == nil)
        #expect(state.connections.isEmpty)
        let document = try Data(contentsOf: paths.documentFile(workspace.id))
        #expect(document.isEmpty)
    }

    @Test func terminalPodeConectarVariasNotas() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmulti-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ColmeiaPaths(root: root)
        try paths.ensureRootLayout()
        let now = Date()
        let workspace = Workspace(
            id: ULID.generate(), nome: "multi", criadoEm: now, atualizadoEm: now)
        let state = try WorkspaceState(paths: paths, workspace: workspace)
        let terminal = TerminalNode(
            id: ULID.generate(), posicao: Ponto(x: 0, y: 0),
            tamanho: Tamanho(w: 400, h: 280), criadoEm: now,
            nome: "Alfie", adapter: "shell", cwd: root.path)
        let notes = [0, 1].map { index in
            NotaNode(
                id: ULID.generate(), posicao: Ponto(x: 500, y: Double(index * 180)),
                tamanho: Tamanho(w: 240, h: 140), criadoEm: now,
                arquivo: "notes/\(ULID.generate()).md", cor: "amarelo")
        }
        var proposals = [
            DocOp(opID: ULID.generate(), author: .humanoLocal, ts: now,
                  payload: .nodeAdd(NodeAddOpPayload(node: .terminal(terminal)))),
        ]
        proposals += notes.map {
            DocOp(opID: ULID.generate(), author: .humanoLocal, ts: now,
                  payload: .nodeAdd(NodeAddOpPayload(node: .nota($0))))
        }
        proposals += notes.map {
            DocOp(
                opID: ULID.generate(), author: .humanoLocal, ts: now,
                payload: .connectionAdd(ConnectionAddOpPayload(connection: Connection(
                    id: ULID.generate(), de: terminal.id, para: $0.id,
                    semantica: .escritaDeNota, estilo: .solida))))
        }

        _ = try state.applyBatch(proposals, liveNodeIDs: [])

        #expect(state.connections.values.filter {
            $0.de == terminal.id && $0.semantica == .escritaDeNota
        }.count == 2)
    }
}
