import Foundation

/// §7.1 — convite de uso único para entrada em sala.
/// Expira e carrega o menor papel necessário. Armazenado no RoomStore.
public struct InviteToken: Codable, Equatable, Sendable {
    public var token: String
    public var roomID: ULID
    public var displayName: String
    public var roles: Set<MemberRole>
    public var createdAt: Date
    public var expiresAt: Date
    public var used: Bool
    public var usedByMemberID: String?

    enum CodingKeys: String, CodingKey {
        case token, roles, used
        case roomID = "room_id"
        case displayName = "display_name"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case usedByMemberID = "used_by_member_id"
    }

    public init(
        token: String,
        roomID: ULID,
        displayName: String,
        roles: Set<MemberRole>,
        createdAt: Date,
        expiresAt: Date,
        used: Bool = false,
        usedByMemberID: String? = nil
    ) {
        self.token = token
        self.roomID = roomID
        self.displayName = displayName
        self.roles = roles
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.used = used
        self.usedByMemberID = usedByMemberID
    }

    public var isExpired: Bool { Date() > expiresAt }
    public var isValid: Bool { !used && !isExpired }
}
