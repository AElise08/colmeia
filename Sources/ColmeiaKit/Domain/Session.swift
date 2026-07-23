import Foundation

/// Máquina de estados de atividade (§11.1). Toda transição gera evento `state`
/// no journal + `session.state` para assinantes (§11.2).
public enum SessionEstado: String, Codable, CaseIterable, Sendable {
    case iniciando
    case rodando
    case esperandoHumano = "esperando_humano"
    case aprovacaoPendente = "aprovacao_pendente"
    case ociosa
    case encerrada
    case morta

    public var isViva: Bool {
        switch self {
        case .encerrada, .morta: return false
        default: return true
        }
    }
}

/// §5.4 — DTO do protocolo, "session sem handles": o handle de PTY é interno ao
/// engine e NUNCA cruza o socket. A Session nunca é serializada dentro do documento.
public struct Session: Codable, Equatable, Sendable {
    public var id: ULID
    public var workspaceID: ULID
    public var nodeID: ULID
    public var adapter: String
    public var estado: SessionEstado
    /// Processo raiz no PTY.
    public var pid: Int32?
    /// Path do journal: `sessions/<id>.jsonl` (§20).
    public var journal: String?
    public var iniciadaEm: Date
    public var encerradaEm: Date?
    /// Última geometria conhecida.
    public var cols: Int
    public var rows: Int
    /// Extensão (§0): instante da última transição de `estado` — a CLI usa para "HÁ" (§13.4).
    public var estadoDesde: Date?

    enum CodingKeys: String, CodingKey {
        case id, adapter, estado, pid, journal, cols, rows
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case iniciadaEm = "iniciada_em"
        case encerradaEm = "encerrada_em"
        case estadoDesde = "estado_desde"
    }

    public init(
        id: ULID,
        workspaceID: ULID,
        nodeID: ULID,
        adapter: String,
        estado: SessionEstado,
        pid: Int32? = nil,
        journal: String? = nil,
        iniciadaEm: Date,
        encerradaEm: Date? = nil,
        cols: Int,
        rows: Int,
        estadoDesde: Date? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.adapter = adapter
        self.estado = estado
        self.pid = pid
        self.journal = journal
        self.iniciadaEm = iniciadaEm
        self.encerradaEm = encerradaEm
        self.cols = cols
        self.rows = rows
        self.estadoDesde = estadoDesde
    }
}
