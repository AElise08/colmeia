import Foundation

/// Identidade presente em todo evento (§4.3): `humano:<id>` | `agente:<node-id>` | `sistema`.
/// Na v1, `humanoLocal` mantém `humano:local` para compatibilidade; para a identidade
/// estável de instalação (Fase 0), use `InstallationIdentity.currentAuthor()`.
public enum Author: Hashable, Sendable, RawRepresentable, Codable, CustomStringConvertible {
    case humano(String)
    case agente(String)
    case sistema

    /// Identidade local singleton — `humano:local`. Mantido para compatibilidade com a v1.
    /// Para identidade estável de instalação, veja `InstallationIdentity.currentAuthor()`.
    public static let humanoLocal = Author.humano("local")

    public var rawValue: String {
        switch self {
        case .humano(let id): return "humano:\(id)"
        case .agente(let nodeID): return "agente:\(nodeID)"
        case .sistema: return "sistema"
        }
    }

    public init?(rawValue: String) {
        if rawValue == "sistema" {
            self = .sistema
        } else if rawValue.hasPrefix("humano:") {
            self = .humano(String(rawValue.dropFirst("humano:".count)))
        } else if rawValue.hasPrefix("agente:") {
            self = .agente(String(rawValue.dropFirst("agente:".count)))
        } else {
            return nil
        }
    }

    public var description: String { rawValue }
}
