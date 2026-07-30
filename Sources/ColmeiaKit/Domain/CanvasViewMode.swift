import Foundation

/// §6.3 — visões derivadas do Canvas (Marco C).
public enum CanvasViewMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Organização espacial definida pela pessoa.
    case livre
    /// Missão/Frente/Decisão/Entrega/dependência.
    case missao
    /// Pessoas e Agentes agrupados por papel.
    case equipe
    /// Objetos bloqueados ou aguardando pessoa.
    case atencao
    /// Agentes e sessões locais, como detalhe operacional.
    case execucao

    public var id: String { rawValue }

    public var titulo: String {
        switch self {
        case .livre: return "Visão livre"
        case .missao: return "Visão da Missão"
        case .equipe: return "Equipe"
        case .atencao: return "Atenção"
        case .execucao: return "Execução"
        }
    }

    public var simbolo: String {
        switch self {
        case .livre: return "rectangle.3.group"
        case .missao: return "flag.checkered"
        case .equipe: return "person.3.fill"
        case .atencao: return "exclamationmark.triangle.fill"
        case .execucao: return "terminal"
        }
    }
}
