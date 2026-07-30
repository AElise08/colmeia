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
    /// Nós (terminal, nota, portal etc.) que pertencem ao andar.
    public var nos: [ULID]
    /// Posição de câmera própria do andar (§16.2). Não fazia parte dos primeiros
    /// `floors.json`; a decodificação abaixo usa o default para preservar esses
    /// arquivos. Campos extras continuam seguros para clientes antigos (§0).
    public var viewport: Viewport

    enum CodingKeys: String, CodingKey {
        case id, nome, origem, mecanismo, branch, caminho, estado, nos, viewport
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
        nos: [ULID] = [],
        viewport: Viewport = Viewport()
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
        self.viewport = viewport
    }

    /// Compatibilidade com floors criados antes do viewport por andar.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ULID.self, forKey: .id)
        nome = try container.decode(String.self, forKey: .nome)
        origem = try container.decode(ULID.self, forKey: .origem)
        mecanismo = try container.decode(FloorMecanismo.self, forKey: .mecanismo)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        caminho = try container.decode(String.self, forKey: .caminho)
        estado = try container.decode(FloorEstado.self, forKey: .estado)
        criadoEm = try container.decode(Date.self, forKey: .criadoEm)
        nos = try container.decodeIfPresent([ULID].self, forKey: .nos) ?? []
        viewport = try container.decodeIfPresent(Viewport.self, forKey: .viewport) ?? Viewport()
    }
}
