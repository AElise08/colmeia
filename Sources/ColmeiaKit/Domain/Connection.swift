import Foundation

/// §5.3 — um terminal DEVE ter no máximo uma conexão `escrita-de-nota` ativa.
public enum ConnectionSemantica: String, Codable, CaseIterable, Sendable {
    case conversa
    case escritaDeNota = "escrita-de-nota"
    case visual
}

public enum ConnectionEstilo: String, Codable, CaseIterable, Sendable {
    case tracejada, solida
}

public struct Connection: Codable, Equatable, Sendable {
    public var id: ULID
    public var de: ULID
    public var para: ULID
    public var semantica: ConnectionSemantica
    public var estilo: ConnectionEstilo

    public init(id: ULID, de: ULID, para: ULID, semantica: ConnectionSemantica, estilo: ConnectionEstilo) {
        self.id = id
        self.de = de
        self.para = para
        self.semantica = semantica
        self.estilo = estilo
    }
}
