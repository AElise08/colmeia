import Foundation

public enum WorkspaceHealthState: String, Codable, CaseIterable, Sendable {
    case open
    case recoverable
    case corrupt
}

/// Diagnóstico mínimo e seguro para a UI. Não contém conteúdo de PTY, secrets
/// nem paths privados; aponta apenas para ações de recuperação disponíveis.
public struct WorkspaceHealth: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var state: WorkspaceHealthState
    public var message: String?
    public var snapshotAvailable: Bool
    public var journalAvailable: Bool
    public var quarantineAvailable: Bool
    public var canExportDiagnostics: Bool

    enum CodingKeys: String, CodingKey {
        case state, message
        case workspaceID = "workspace_id"
        case snapshotAvailable = "snapshot_available"
        case journalAvailable = "journal_available"
        case quarantineAvailable = "quarantine_available"
        case canExportDiagnostics = "can_export_diagnostics"
    }

    public init(
        workspaceID: ULID,
        state: WorkspaceHealthState,
        message: String? = nil,
        snapshotAvailable: Bool,
        journalAvailable: Bool,
        quarantineAvailable: Bool,
        canExportDiagnostics: Bool = true
    ) {
        self.workspaceID = workspaceID
        self.state = state
        self.message = message
        self.snapshotAvailable = snapshotAvailable
        self.journalAvailable = journalAvailable
        self.quarantineAvailable = quarantineAvailable
        self.canExportDiagnostics = canExportDiagnostics
    }
}
