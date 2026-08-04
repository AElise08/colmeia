import Foundation

public struct SessionTokenClaims: Codable, Equatable, Sendable {
    public let tokenID: ULID
    public let workspaceID: ULID
    public let issuedAt: Date
    public let expiresAt: Date

    public init(tokenID: ULID, workspaceID: ULID, issuedAt: Date, expiresAt: Date) {
        self.tokenID = tokenID
        self.workspaceID = workspaceID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool { Date() >= expiresAt }
}

public enum SessionTokenError: Error, Equatable, Sendable, LocalizedError {
    case expired
    case revoked
    case workspaceMismatch
    case invalidSignature

    public var errorDescription: String? {
        switch self {
        case .expired: return "token de sessão expirado"
        case .revoked: return "token de sessão já utilizado ou revogado"
        case .workspaceMismatch: return "token de sessão pertence a outra sala"
        case .invalidSignature: return "assinatura do token de sessão inválida"
        }
    }
}

/// A verificação criptográfica fica atrás deste contrato para que a implementação
/// concreta possa usar a chave do nó/Keychain sem cruzar fronteiras de atores.
public protocol SessionTokenVerifier: Sendable {
    func verify(token: String, expectedWorkspaceID: ULID) throws -> SessionTokenClaims
}

/// Registro single-use do lado do engine. A assinatura é validada pelo verifier;
/// este ator somente controla expiração, escopo e revogação imediata.
public actor SingleUseSessionTokenRegistry {
    private var consumed: Set<ULID> = []

    public init() {}

    public func consume(
        token: String,
        workspaceID: ULID,
        verifier: any SessionTokenVerifier
    ) throws -> SessionTokenClaims {
        let claims = try verifier.verify(token: token, expectedWorkspaceID: workspaceID)
        guard claims.workspaceID == workspaceID else { throw SessionTokenError.workspaceMismatch }
        guard claims.expiresAt > Date() else { throw SessionTokenError.expired }
        guard !consumed.contains(claims.tokenID) else { throw SessionTokenError.revoked }
        consumed.insert(claims.tokenID)
        return claims
    }

    public func revoke(_ tokenID: ULID) {
        consumed.insert(tokenID)
    }
}

public struct WorkerCertificatePolicy: Codable, Equatable, Sendable {
    public let workspaceID: ULID
    public let allowedCertificateFingerprints: Set<String>

    public init(workspaceID: ULID, allowedCertificateFingerprints: Set<String> = []) {
        self.workspaceID = workspaceID
        self.allowedCertificateFingerprints = Set(allowedCertificateFingerprints.map { $0.lowercased() })
    }

    public func accepts(certificateFingerprint: String, workspaceID: ULID) -> Bool {
        self.workspaceID == workspaceID
            && allowedCertificateFingerprints.contains(certificateFingerprint.lowercased())
    }
}
