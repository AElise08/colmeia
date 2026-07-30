import Foundation

public enum ColmeiaVersion {
    public static let string = "0.3.0"
    /// §6.2 — começa em 1; incompatibilidade DEVE falhar o handshake com `protocol_version_mismatch`.
    public static let protocolVersion = 1

    /// Compara versões numéricas `major.minor.patch`. Isso permite distinguir
    /// engine antigo de uma interface antiga ainda carregada em memória.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func components(_ value: String) -> [Int] {
            value.split(separator: ".").map { part in
                Int(part.prefix { $0.isNumber }) ?? 0
            }
        }
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }
}

/// Variáveis de ambiente injetadas nos terminais gerenciados (§13.1).
public enum ColmeiaEnv {
    public static let socket = "COLMEIA_SOCKET"
    public static let sessionID = "COLMEIA_SESSION_ID"
    public static let nodeID = "COLMEIA_NODE_ID"
    public static let workspaceID = "COLMEIA_WORKSPACE_ID"
    /// Informativas (extensão forward-compatible, §0): nome e papel do nó, para
    /// agentes que leem env se situarem no canvas sem falar o protocolo.
    public static let nodeNome = "COLMEIA_NODE_NOME"
    public static let nodePapel = "COLMEIA_NODE_PAPEL"
    public static let canvasSkill = "COLMEIA_CANVAS_SKILL"
}
