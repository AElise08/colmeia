import Foundation

public struct DiagnosticSession: Codable, Equatable, Sendable {
    public var id: ULID
    public var nodeID: ULID
    public var adapter: String
    public var state: SessionEstado
    public var startedAt: Date
    public var endedAt: Date?

    public init(session: Session) {
        id = session.id
        nodeID = session.nodeID
        adapter = session.adapter
        state = session.estado
        startedAt = session.iniciadaEm
        endedAt = session.encerradaEm
    }
}

/// Cabeçalho auditável de uma operação. O payload fica deliberadamente fora
/// do diagnóstico: ele pode conter conteúdo de nota, cwd ou outros dados que
/// não devem sair do workspace junto com um relatório de suporte.
public struct SanitizedDocOperation: Codable, Equatable, Sendable {
    public var opID: ULID
    public var seq: UInt64?
    public var type: String
    public var author: Author
    public var timestamp: Date
    public var hasUndoData: Bool
    public var logicalClock: UInt64?
    public var roomSeq: UInt64?

    enum CodingKeys: String, CodingKey {
        case seq, author, timestamp, type
        case opID = "op_id"
        case hasUndoData = "has_undo_data"
        case logicalClock = "logical_clock"
        case roomSeq = "room_seq"
    }

    public init(op: DocOp) {
        opID = op.opID
        seq = op.seq
        type = op.tipo.rawValue
        author = op.author
        timestamp = op.ts
        hasUndoData = op.anterior != nil
        logicalClock = op.logicalClock
        roomSeq = op.roomSeq
    }
}

/// Diagnóstico exportável sem output ANSI, cookies, tokens, PIDs, journals
/// absolutos ou conteúdo remoto. Ops e snapshot permanecem para auditoria.
public struct WorkspaceDiagnostic: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var workspace: Workspace
    public var health: WorkspaceHealth
    public var snapshot: DocumentSnapshot
    public var operations: [SanitizedDocOperation]
    public var sessions: [DiagnosticSession]
    public var omitted: [String]

    enum CodingKeys: String, CodingKey {
        case workspace, health, snapshot, operations, sessions, omitted
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
    }

    public init(
        workspace: Workspace,
        health: WorkspaceHealth,
        snapshot: DocumentSnapshot,
        operations: [DocOp],
        sessions: [DiagnosticSession],
        generatedAt: Date = Date()
    ) {
        self.schemaVersion = 1
        self.generatedAt = generatedAt
        let archive = WorkspaceArchive(workspace: workspace, snapshot: snapshot)
        self.workspace = archive.workspace
        self.health = health
        var sanitizedSnapshot = archive.snapshot
        // Diagnóstico responde “o que quebrou”, não exporta o conteúdo do
        // workspace: notas, scrollback, estados de sessão e histórico do
        // watchdog podem carregar segredos ou dados remotos.
        sanitizedSnapshot.noteContents = nil
        sanitizedSnapshot.sessionStates = nil
        sanitizedSnapshot.sessionOutputs = nil
        sanitizedSnapshot.watchdogHistory = nil
        self.snapshot = sanitizedSnapshot
        self.operations = operations.map(SanitizedDocOperation.init)
        self.sessions = sessions
        self.omitted = [
            "raw PTY output and ANSI scrollback",
            "session journal paths and process IDs",
            "cookies, tokens and remote credentials",
            "private absolute filesystem paths"
        ]
    }

    public func write(to url: URL) throws { try AtomicJSON.write(self, to: url) }
}
