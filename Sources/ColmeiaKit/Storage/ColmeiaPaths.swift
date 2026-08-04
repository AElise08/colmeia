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

    /// Root normative do layout v2. `defaultRoot()` permanece apontando para o
    /// Application Support da v1 para não quebrar workspaces existentes.
    public static func v2Default() -> ColmeiaPaths {
        ColmeiaPaths(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".colmeia", isDirectory: true))
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
    /// Layout v2 mantém `config.json` para compatibilidade; novos engines podem
    /// optar pelo TOML sem fazer versões antigas perderem o arquivo conhecido.
    public var configTOMLFile: URL { root.appendingPathComponent("config.toml") }
    /// Content-addressable storage compartilhado por workspaces e workers.
    public var casDir: URL { root.appendingPathComponent("cas", isDirectory: true) }
    public func casBucket(_ prefix: String) -> URL {
        casDir.appendingPathComponent(prefix.lowercased(), isDirectory: true)
    }
    /// Identidade do nó e CA da sala (arquivos privados, modo 0600 quando criados).
    public var identitiesDir: URL { root.appendingPathComponent("identities", isDirectory: true) }
    public var nodeIdentityFile: URL { identitiesDir.appendingPathComponent("node_id.pem") }
    public var caCertificateFile: URL { identitiesDir.appendingPathComponent("ca_cert.pem") }
    /// PIDs de agentes que precisam de limpeza no próximo boot após crash.
    public var pidsLockFile: URL { root.appendingPathComponent("pids.lock") }
    public var workspacesDir: URL { root.appendingPathComponent("workspaces", isDirectory: true) }
    /// Salas multiplayer persistentes (§6.1).
    public var roomsDir: URL { root.appendingPathComponent("rooms", isDirectory: true) }

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

    // MARK: - Persistência CRDT v2

    public func metaSQLiteFile(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("meta.sqlite")
    }

    public func crdtOpsWAL(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("crdt_ops.wal")
    }

    public func crdtSnapshot(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("crdt_snapshot.bin")
    }

    public func journalsDir(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("journals", isDirectory: true)
    }

    public func agentJournal(workspace workspaceID: ULID, agent agentID: ULID) -> URL {
        journalsDir(workspaceID).appendingPathComponent("\(agentID.string).ndjson")
    }

    public func agentsDir(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("agents", isDirectory: true)
    }

    public func agentHome(workspace workspaceID: ULID, agent agentID: ULID) -> URL {
        agentsDir(workspaceID).appendingPathComponent(agentID.string, isDirectory: true)
    }

    public func agentTemp(workspace workspaceID: ULID, agent agentID: ULID) -> URL {
        agentHome(workspace: workspaceID, agent: agentID).appendingPathComponent("tmp", isDirectory: true)
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

    /// DTO persistido da sessão (§5.4); centraliza a convenção para manutenção.
    public func sessionMeta(workspace workspaceID: ULID, session sessionID: ULID) -> URL {
        sessionsDir(workspaceID).appendingPathComponent("\(sessionID.string).meta.json")
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

    public func memoryDir(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("memory", isDirectory: true)
    }

    public func deliveriesDir(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("deliveries", isDirectory: true)
    }

    public func watchdogFile(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("watchdog.json")
    }

    public func workerArchiveDir(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("archive", isDirectory: true)
    }

    public func workerArchiveFile(_ workspaceID: ULID) -> URL {
        workerArchiveDir(workspaceID).appendingPathComponent("workers.json")
    }

    public func delegationsFile(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("delegations.json")
    }

    /// Projeção persistente do Agent Chat, separada do output ANSI dos journals.
    public func chatMessagesFile(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("chat-messages.json")
    }

    public func semanticEventsFile(_ workspaceID: ULID) -> URL {
        workspaceDir(workspaceID).appendingPathComponent("semantic-events.jsonl")
    }

    // MARK: - Multiplayer

    public func roomDir(_ roomID: ULID) -> URL {
        roomsDir.appendingPathComponent(roomID.string, isDirectory: true)
    }

    /// Registro da sala (§4.1.1).
    public func roomFile(_ roomID: ULID) -> URL {
        roomDir(roomID).appendingPathComponent("room.json")
    }

    /// Eventos colaborativos append-only da sala (§4.1.4).
    public func roomEventsFile(_ roomID: ULID) -> URL {
        roomDir(roomID).appendingPathComponent("events.jsonl")
    }

    /// Snapshot de estado da sala para recuperação rápida (§6.2).
    public func roomSnapshotFile(_ roomID: ULID) -> URL {
        roomDir(roomID).appendingPathComponent("snapshot.json")
    }

    /// Membros da sala (§4.1.2).
    public func roomMembersFile(_ roomID: ULID) -> URL {
        roomDir(roomID).appendingPathComponent("members.json")
    }

    /// AgentSessions da sala (§4.1.3).
    public func roomAgentSessionsFile(_ roomID: ULID) -> URL {
        roomDir(roomID).appendingPathComponent("agent_sessions.json")
    }

    /// Grants ativos da sala (§4.1.5).
    public func roomGrantsFile(_ roomID: ULID) -> URL {
        roomDir(roomID).appendingPathComponent("grants.json")
    }

    /// §13 — Missões, Frentes, Decisões e Relações da Sala.
    public func roomMissionsFile(_ roomID: ULID) -> URL {
        roomDir(roomID).appendingPathComponent("missions.json")
    }

    /// §11.4 — fila offline durável de mutações remotas.
    public func roomOutboxFile(_ roomID: ULID) -> URL {
        roomDir(roomID).appendingPathComponent("outbox.jsonl")
    }

    // MARK: - Criação de diretórios

    public func ensureRootLayout() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: workspacesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: roomsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: casDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: identitiesDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: identitiesDir.path)
    }

    public func ensureWorkspaceLayout(_ workspaceID: ULID) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: workspaceDir(workspaceID), withIntermediateDirectories: true)
        try fm.createDirectory(at: sessionsDir(workspaceID), withIntermediateDirectories: true)
        try fm.createDirectory(at: journalsDir(workspaceID), withIntermediateDirectories: true)
        try fm.createDirectory(at: agentsDir(workspaceID), withIntermediateDirectories: true)
        try fm.createDirectory(at: notesDir(workspaceID), withIntermediateDirectories: true)
        try fm.createDirectory(at: memoryDir(workspaceID), withIntermediateDirectories: true)
        try fm.createDirectory(at: deliveriesDir(workspaceID), withIntermediateDirectories: true)
        try fm.createDirectory(at: workerArchiveDir(workspaceID), withIntermediateDirectories: true)
    }
}
