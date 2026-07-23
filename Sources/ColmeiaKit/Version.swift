import Foundation

public enum ColmeiaVersion {
    public static let string = "0.1.0"
    /// §6.2 — começa em 1; incompatibilidade DEVE falhar o handshake com `protocol_version_mismatch`.
    public static let protocolVersion = 1
}

/// Variáveis de ambiente injetadas nos terminais gerenciados (§13.1).
public enum ColmeiaEnv {
    public static let socket = "COLMEIA_SOCKET"
    public static let sessionID = "COLMEIA_SESSION_ID"
    public static let nodeID = "COLMEIA_NODE_ID"
    public static let workspaceID = "COLMEIA_WORKSPACE_ID"
}
