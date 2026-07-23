import Foundation

/// Layout de storage (§20.1) sob `~/Library/Application Support/Colmeia/`.
/// Tudo legível (JSON/JSONL/Markdown); escritas de JSON inteiro DEVEM ser atômicas (§20.2).
public struct ColmeiaPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public init() {
        self.init(root: ColmeiaPaths.defaultRoot())
    }

    public static func defaultRoot() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Colmeia", isDirectory: true)
    }

    /// §13.1 — dentro de sessão gerenciada a CLI DEVE preferir a env COLMEIA_SOCKET.
    public static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        environment[ColmeiaEnv.socket] ?? ColmeiaPaths().engineSocket.path
    }

    // MARK: - Raiz

    public var engineSocket: URL { root.appendingPathComponent("engine.sock") }
    /// Lock de instância única com pid via flock (§20.5).
    public var engineLock: URL { root.appendingPathComponent("engine.lock") }
    public var engineLog: URL { root.appendingPathComponent("engine.log") }
    public var configFile: URL { root.appendingPathComponent("config.json") }
    public var workspacesDir: URL { root.appendingPathComponent("workspaces", isDirectory: true) }

    // MARK: - Por workspace

    public func workspaceDir(_ workspaceID: ULID) -> URL {
        workspacesDir.appendingPathComponent(workspaceID.string, isDirectory: true)
    }

    public func workspaceFile(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("workspace.json")
    }

    /// Ops append-only (§7).
    public func documentFile(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("document.jsonl")
    }

    public func documentSnapshotFile(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("document.snapshot.json")
    }

    public func sessionsDir(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("sessions", isDirectory: true)
    }

    /// Journal append-only da sessão (§8): o engine é o único escritor.
    public func sessionJournal(workspace workspaceID: ULID, session sessionID: ULID) -> URL {
        sessionsDir(workspaceID).appendingPathComponent("\(sessionID.string).jsonl")
    }

    /// Snapshot de scrollback, se rotacionado (§8.3).
    public func sessionScrollback(workspace workspaceID: ULID, session sessionID: ULID) -> URL {
        sessionsDir(workspaceID).appendingPathComponent("\(sessionID.string).scrollback")
    }

    public func notesDir(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("notes", isDirectory: true)
    }

    /// Notas DEVEM ser legíveis e editáveis fora do app (§5.2.2).
    public func noteFile(workspace workspaceID: ULID, node nodeID: ULID) -> URL {
        notesDir(workspaceID).appendingPathComponent("\(nodeID.string).md")
    }

    public func routinesFile(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("routines.json")
    }

    public func floorsFile(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("floors.json")
    }

    // MARK: - Criação de diretórios

    public func ensureRootLayout() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: workspacesDir, withIntermediateDirectories: true)
    }

    public func ensureWorkspaceLayout(_ workspaceID: ULID) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: workspaceDir(workspaceID), withIntermediateDirectories: true)
        try fm.createDirectory(at: sessionsDir(workspaceID), withIntermediateDirectories: true)
        try fm.createDirectory(at: notesDir(workspaceID), withIntermediateDirectories: true)
    }
}
