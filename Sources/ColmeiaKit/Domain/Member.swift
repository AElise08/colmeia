import Foundation

/// §5.5 — papéis de autorização da Sala. `conductor` e `executor` não são
/// MemberRoles: são responsabilidades de sessão conforme §5.5/§10.4 e vivem
/// em `HandoffScope`/`LeaseRecord`. Esta enum é apenas sobre quem pode
/// administrar, editar ou apenas ler a Sala.
public enum MemberRole: String, Codable, CaseIterable, Sendable {
    /// Autoridade administrativa da sala.
    case owner
    /// Pode alterar objetos autorizados e fazer propostas (não pode administrar).
    case editor
    /// Somente leitura.
    case viewer
}

public enum MemberStatus: String, Codable, CaseIterable, Sendable {
    case active
    case revoked
    case left
    case invited
}

public struct Member: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var publicKey: String?
    /// §5.5 — um membro pode ter mais de um papel (owner tem precedência).
    public var roles: Set<MemberRole>
    public var status: MemberStatus
    public var joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, roles, status
        case displayName = "display_name"
        case publicKey = "public_key"
        case joinedAt = "joined_at"
    }

    public init(
        id: String,
        displayName: String,
        publicKey: String? = nil,
        roles: Set<MemberRole>,
        status: MemberStatus = .active,
        joinedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.publicKey = publicKey
        self.roles = roles
        self.status = status
        self.joinedAt = joinedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
        self.publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        self.roles = try container.decodeIfPresent(Set<MemberRole>.self, forKey: .roles) ?? [.viewer]
        self.status = try container.decodeIfPresent(MemberStatus.self, forKey: .status) ?? .active
        self.joinedAt = try container.decodeIfPresent(Date.self, forKey: .joinedAt) ?? Date()
    }

    public var isActive: Bool { status == .active }

    /// §10.3 — papel primário para autorização; owner sempre precede editor, que
    /// precede viewer quando múltiplos papéis coexistem.
    public var primaryRole: MemberRole? {
        if roles.contains(.owner) { return .owner }
        if roles.contains(.editor) { return .editor }
        if roles.contains(.viewer) { return .viewer }
        return nil
    }

    public func hasRole(_ role: MemberRole) -> Bool {
        roles.contains(role)
    }

    /// §10.3 — `owner` administra membros e política; `editor` não.
    public var canAdminister: Bool { roles.contains(.owner) }
    /// §10.3 — `viewer` somente lê; `editor` e `owner` alteram objetos autorizados.
    public var canEdit: Bool { roles.contains(.owner) || roles.contains(.editor) }
}
