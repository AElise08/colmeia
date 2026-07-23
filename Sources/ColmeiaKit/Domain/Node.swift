import Foundation

/// §5.2 — `portal` é [v1.5]: reconhecido no enum, mas sem nó concreto na v1.
public enum NodeTipo: String, Codable, CaseIterable, Sendable {
    case terminal, nota, desenho, portal
}

/// Adapters conhecidos na v1 (§5.2.1). O campo `adapter` do nó é String
/// porque adapters são plugáveis (§4.6).
public enum KnownAdapter: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case geminiCli = "gemini-cli"
    case opencode
    case shell
}

/// Tema/fonte/tamanho — definido-pela-implementação (§5.2.1).
public struct Aparencia: Codable, Equatable, Sendable {
    public var tema: String?
    public var fonte: String?
    public var tamanhoFonte: Double?

    enum CodingKeys: String, CodingKey {
        case tema, fonte
        case tamanhoFonte = "tamanho_fonte"
    }

    public init(tema: String? = nil, fonte: String? = nil, tamanhoFonte: Double? = nil) {
        self.tema = tema
        self.fonte = fonte
        self.tamanhoFonte = tamanhoFonte
    }
}

/// §5.2.1 — `nome` DEVE ser único no workspace (case-insensitive): é o endereço
/// de `colmeia ask` (§14). Colisão na criação → `duplicate_node_name`.
public struct TerminalNode: Codable, Equatable, Sendable {
    public var id: ULID
    public var posicao: Ponto
    public var tamanho: Tamanho
    public var z: Int
    public var criadoEm: Date
    public var nome: String
    public var papel: String?
    public var adapter: String
    public var comandoOverride: String?
    public var cwd: String
    public var monitorarAtividade: Bool
    public var aparencia: Aparencia?
    public var sessionID: ULID?

    enum CodingKeys: String, CodingKey {
        case id, posicao, tamanho, z, nome, papel, adapter, cwd, aparencia
        case criadoEm = "criado_em"
        case comandoOverride = "comando_override"
        case monitorarAtividade = "monitorar_atividade"
        case sessionID = "session_id"
    }

    public init(
        id: ULID,
        posicao: Ponto,
        tamanho: Tamanho,
        z: Int = 0,
        criadoEm: Date,
        nome: String,
        papel: String? = nil,
        adapter: String,
        comandoOverride: String? = nil,
        cwd: String,
        monitorarAtividade: Bool = true,
        aparencia: Aparencia? = nil,
        sessionID: ULID? = nil
    ) {
        self.id = id
        self.posicao = posicao
        self.tamanho = tamanho
        self.z = z
        self.criadoEm = criadoEm
        self.nome = nome
        self.papel = papel
        self.adapter = adapter
        self.comandoOverride = comandoOverride
        self.cwd = cwd
        self.monitorarAtividade = monitorarAtividade
        self.aparencia = aparencia
        self.sessionID = sessionID
    }
}

/// §5.2.2 — o conteúdo vive em `notes/<node-id>.md` (§20), não no documento.
public struct NotaNode: Codable, Equatable, Sendable {
    public var id: ULID
    public var posicao: Ponto
    public var tamanho: Tamanho
    public var z: Int
    public var criadoEm: Date
    /// Path relativo à pasta do workspace: `notes/<node-id>.md`.
    public var arquivo: String
    public var cor: String
    /// DEVE ser atualizada a cada escrita ("última escrita: Marcus").
    public var ultimaFonte: Author?

    enum CodingKeys: String, CodingKey {
        case id, posicao, tamanho, z, arquivo, cor
        case criadoEm = "criado_em"
        case ultimaFonte = "ultima_fonte"
    }

    public init(
        id: ULID,
        posicao: Ponto,
        tamanho: Tamanho,
        z: Int = 0,
        criadoEm: Date,
        arquivo: String,
        cor: String,
        ultimaFonte: Author? = nil
    ) {
        self.id = id
        self.posicao = posicao
        self.tamanho = tamanho
        self.z = z
        self.criadoEm = criadoEm
        self.arquivo = arquivo
        self.cor = cor
        self.ultimaFonte = ultimaFonte
    }
}

public enum TracoTipo: String, Codable, CaseIterable, Sendable {
    case livre, seta, retangulo, elipse, texto
}

/// §5.2.3 — o `id` não está no schema da spec, mas é exigido por `traco.delete {node_id, traco_id}` (§7.2).
public struct Traco: Codable, Equatable, Sendable {
    public var id: ULID
    public var pontos: [Ponto]
    public var espessura: Double
    public var cor: String
    public var tipo: TracoTipo

    public init(id: ULID, pontos: [Ponto], espessura: Double, cor: String, tipo: TracoTipo) {
        self.id = id
        self.pontos = pontos
        self.espessura = espessura
        self.cor = cor
        self.tipo = tipo
    }
}

/// §5.2.3 — traços participam de undo/redo como ops do documento (§7).
public struct DesenhoNode: Codable, Equatable, Sendable {
    public var id: ULID
    public var posicao: Ponto
    public var tamanho: Tamanho
    public var z: Int
    public var criadoEm: Date
    public var tracos: [Traco]
    /// Apenas para tipo `texto` (§5.2.3).
    public var texto: String?

    enum CodingKeys: String, CodingKey {
        case id, posicao, tamanho, z, tracos, texto
        case criadoEm = "criado_em"
    }

    public init(
        id: ULID,
        posicao: Ponto,
        tamanho: Tamanho,
        z: Int = 0,
        criadoEm: Date,
        tracos: [Traco] = [],
        texto: String? = nil
    ) {
        self.id = id
        self.posicao = posicao
        self.tamanho = tamanho
        self.z = z
        self.criadoEm = criadoEm
        self.tracos = tracos
        self.texto = texto
    }
}

/// Nó polimórfico do canvas. No wire os campos ficam achatados com discriminador `tipo`,
/// como nos schemas "extends Node" da §5.2.
public enum Node: Codable, Equatable, Sendable {
    case terminal(TerminalNode)
    case nota(NotaNode)
    case desenho(DesenhoNode)

    private enum TipoKey: String, CodingKey { case tipo }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TipoKey.self)
        let tipo = try container.decode(NodeTipo.self, forKey: .tipo)
        switch tipo {
        case .terminal:
            self = .terminal(try TerminalNode(from: decoder))
        case .nota:
            self = .nota(try NotaNode(from: decoder))
        case .desenho:
            self = .desenho(try DesenhoNode(from: decoder))
        case .portal:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "portal é [v1.5] — sem suporte na v1"
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TipoKey.self)
        try container.encode(tipo, forKey: .tipo)
        switch self {
        case .terminal(let node): try node.encode(to: encoder)
        case .nota(let node): try node.encode(to: encoder)
        case .desenho(let node): try node.encode(to: encoder)
        }
    }

    public var tipo: NodeTipo {
        switch self {
        case .terminal: return .terminal
        case .nota: return .nota
        case .desenho: return .desenho
        }
    }

    public var id: ULID {
        switch self {
        case .terminal(let node): return node.id
        case .nota(let node): return node.id
        case .desenho(let node): return node.id
        }
    }

    public var posicao: Ponto {
        switch self {
        case .terminal(let node): return node.posicao
        case .nota(let node): return node.posicao
        case .desenho(let node): return node.posicao
        }
    }

    public var tamanho: Tamanho {
        switch self {
        case .terminal(let node): return node.tamanho
        case .nota(let node): return node.tamanho
        case .desenho(let node): return node.tamanho
        }
    }

    public var z: Int {
        switch self {
        case .terminal(let node): return node.z
        case .nota(let node): return node.z
        case .desenho(let node): return node.z
        }
    }

    public var criadoEm: Date {
        switch self {
        case .terminal(let node): return node.criadoEm
        case .nota(let node): return node.criadoEm
        case .desenho(let node): return node.criadoEm
        }
    }
}
