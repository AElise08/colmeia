import Foundation

/// Formato público e portátil do Base Workspace. O arquivo contém apenas a
/// projeção do canvas e o conteúdo das notas; journals, PTY, cookies, tokens e
/// paths de sessão não fazem parte da exportação.
public struct WorkspaceArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var workspace: Workspace
    public var snapshot: DocumentSnapshot

    enum CodingKeys: String, CodingKey {
        case workspace, snapshot
        case schemaVersion = "schema_version"
    }

    public init(workspace: Workspace, snapshot: DocumentSnapshot) {
        self.schemaVersion = Self.currentSchemaVersion
        let portableNodes = snapshot.nodes.map { node -> Node in
            guard case .terminal(var terminal) = node else { return node }
            terminal.cwd = "."
            terminal.comandoOverride = nil
            terminal.sessionID = nil
            return .terminal(terminal)
        }
        var portableWorkspace = workspace
        portableWorkspace.caminhoRaiz = nil
        self.snapshot = DocumentSnapshot(
            workspaceID: snapshot.workspaceID,
            seq: snapshot.seq,
            nodes: portableNodes,
            connections: snapshot.connections,
            criadoEm: snapshot.criadoEm,
            noteContents: snapshot.noteContents,
            // Sessões e configurações de runtime são deliberadamente omitidas.
            sessionStates: nil,
            sessionOutputs: nil,
            watchdogConfiguration: nil,
            watchdogHistory: nil)
        self.workspace = portableWorkspace
    }

    /// Reidentifica o snapshot para um novo workspace durante a importação.
    public func reidentified(workspaceID: ULID, name: String? = nil, rootPath: String? = nil) -> WorkspaceArchive {
        var copiedWorkspace = workspace
        copiedWorkspace.id = workspaceID
        if let name { copiedWorkspace.nome = name }
        if let rootPath { copiedWorkspace.caminhoRaiz = rootPath }
        if let primary = copiedWorkspace.primaryNodeID,
           !snapshot.nodes.contains(where: { $0.id == primary }) {
            copiedWorkspace.primaryNodeID = nil
        }
        var copiedSnapshot = snapshot
        copiedSnapshot.workspaceID = workspaceID
        return WorkspaceArchive(workspace: copiedWorkspace, snapshot: copiedSnapshot)
    }

    public func write(to url: URL) throws {
        try AtomicJSON.write(self, to: url)
    }

    public static func read(from url: URL) throws -> WorkspaceArchive {
        let archive = try AtomicJSON.read(WorkspaceArchive.self, from: url)
        guard archive.schemaVersion == currentSchemaVersion else {
            throw WorkspaceArchiveError.unsupportedSchema(archive.schemaVersion)
        }
        guard archive.snapshot.workspaceID == archive.workspace.id else {
            throw WorkspaceArchiveError.workspaceMismatch
        }
        return archive
    }
}

public enum WorkspaceArchiveError: Error, Equatable {
    case unsupportedSchema(Int)
    case workspaceMismatch
}
