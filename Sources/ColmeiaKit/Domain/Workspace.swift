import Foundation

/// §5.1 — um canvas por contexto de trabalho. O registro é o índice; nós, conexões,
/// rotinas e andares vivem no documento (§7) e em arquivos próprios (§20).
public struct Workspace: Codable, Equatable, Sendable {
    public var id: ULID
    public var nome: String
    /// Base para cwd dos terminais e para andares (§16).
    public var caminhoRaiz: String?
    /// Identidade estável do agente principal deste workspace. Fica no registro
    /// do engine para que a escolha não dependa de uma UI ou desta máquina.
    public var primaryNodeID: ULID?
    /// DEVE persistir: reabrir mostra exatamente onde a usuária parou.
    public var viewport: Viewport
    public var criadoEm: Date
    public var atualizadoEm: Date

    enum CodingKeys: String, CodingKey {
        case id, nome, viewport
        case caminhoRaiz = "caminho_raiz"
        case primaryNodeID = "primary_node_id"
        case criadoEm = "criado_em"
        case atualizadoEm = "atualizado_em"
    }

    public init(
        id: ULID,
        nome: String,
        caminhoRaiz: String? = nil,
        primaryNodeID: ULID? = nil,
        viewport: Viewport = Viewport(),
        criadoEm: Date,
        atualizadoEm: Date
    ) {
        self.id = id
        self.nome = nome
        self.caminhoRaiz = caminhoRaiz
        self.primaryNodeID = primaryNodeID
        self.viewport = viewport
        self.criadoEm = criadoEm
        self.atualizadoEm = atualizadoEm
    }
}
