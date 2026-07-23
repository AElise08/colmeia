import Foundation

public enum FloorMecanismo: String, Codable, CaseIterable, Sendable {
    case gitWorktree = "git-worktree"
    case apfsClone = "apfs-clone"
}

public enum FloorEstado: String, Codable, CaseIterable, Sendable {
    case ativo, aterrissado, descartado, orfao
}

/// §5.8 — cópia isolada e instantânea do ambiente de trabalho (§16).
public struct Floor: Codable, Equatable, Sendable {
    public var id: ULID
    public var nome: String
    /// Workspace de origem.
    public var origem: ULID
    public var mecanismo: FloorMecanismo
    /// Apenas git-worktree.
    public var branch: String?
    /// Onde o worktree/clone vive.
    public var caminho: String
    public var estado: FloorEstado
    public var criadoEm: Date
    /// TerminalNodes que pertencem ao andar.
    public var nos: [ULID]

    enum CodingKeys: String, CodingKey {
        case id, nome, origem, mecanismo, branch, caminho, estado, nos
        case criadoEm = "criado_em"
    }

    public init(
        id: ULID,
        nome: String,
        origem: ULID,
        mecanismo: FloorMecanismo,
        branch: String? = nil,
        caminho: String,
        estado: FloorEstado,
        criadoEm: Date,
        nos: [ULID] = []
    ) {
        self.id = id
        self.nome = nome
        self.origem = origem
        self.mecanismo = mecanismo
        self.branch = branch
        self.caminho = caminho
        self.estado = estado
        self.criadoEm = criadoEm
        self.nos = nos
    }
}
