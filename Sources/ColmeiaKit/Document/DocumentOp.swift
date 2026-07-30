import Foundation

/// Inventário de operações do documento (§7.2). Operações DEVEM ser pequenas e
/// nomeadas por intenção — pré-requisito de mesclagem futura (CRDT, Fase 2).
public enum OpTipo: String, Codable, CaseIterable, Sendable {
    case nodeAdd = "node.add"
    case nodeMove = "node.move"
    case nodeResize = "node.resize"
    case nodeUpdate = "node.update"
    case nodeDelete = "node.delete"
    case connectionAdd = "connection.add"
    case connectionDelete = "connection.delete"
    case tracoAdd = "traco.add"
    case tracoDelete = "traco.delete"
    /// PODE ser throttled e fica fora do undo (§7.2/§7.3).
    case viewportSet = "viewport.set"
    case workspaceRename = "workspace.rename"
}

public struct NodeAddOpPayload: Codable, Equatable, Sendable {
    public var node: Node

    public init(node: Node) {
        self.node = node
    }
}

public struct NodeMoveOpPayload: Codable, Equatable, Sendable {
    public var id: ULID
    public var posicao: Ponto

    public init(id: ULID, posicao: Ponto) {
        self.id = id
        self.posicao = posicao
    }
}

public struct NodeResizeOpPayload: Codable, Equatable, Sendable {
    public var id: ULID
    public var tamanho: Tamanho

    public init(id: ULID, tamanho: Tamanho) {
        self.id = id
        self.tamanho = tamanho
    }
}

/// `campos` é objeto parcial com os campos do nó a atualizar (§7.2).
public struct NodeUpdateOpPayload: Codable, Equatable, Sendable {
    public var id: ULID
    public var campos: JSONValue

    public init(id: ULID, campos: JSONValue) {
        self.id = id
        self.campos = campos
    }
}

/// `node.delete` de TerminalNode com sessão ativa DEVE falhar com `session_already_running` (§7.2).
public struct NodeDeleteOpPayload: Codable, Equatable, Sendable {
    public var id: ULID

    public init(id: ULID) {
        self.id = id
    }
}

public struct ConnectionAddOpPayload: Codable, Equatable, Sendable {
    public var connection: Connection

    public init(connection: Connection) {
        self.connection = connection
    }
}

public struct ConnectionDeleteOpPayload: Codable, Equatable, Sendable {
    public var id: ULID

    public init(id: ULID) {
        self.id = id
    }
}

public struct TracoAddOpPayload: Codable, Equatable, Sendable {
    public var nodeID: ULID
    public var traco: Traco

    enum CodingKeys: String, CodingKey {
        case traco
        case nodeID = "node_id"
    }

    public init(nodeID: ULID, traco: Traco) {
        self.nodeID = nodeID
        self.traco = traco
    }
}

public struct TracoDeleteOpPayload: Codable, Equatable, Sendable {
    public var nodeID: ULID
    public var tracoID: ULID

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case tracoID = "traco_id"
    }

    public init(nodeID: ULID, tracoID: ULID) {
        self.nodeID = nodeID
        self.tracoID = tracoID
    }
}

public struct ViewportSetOpPayload: Codable, Equatable, Sendable {
    public var viewport: Viewport

    public init(viewport: Viewport) {
        self.viewport = viewport
    }
}

public struct WorkspaceRenameOpPayload: Codable, Equatable, Sendable {
    public var nome: String

    public init(nome: String) {
        self.nome = nome
    }
}

public enum OpPayload: Equatable, Sendable {
    case nodeAdd(NodeAddOpPayload)
    case nodeMove(NodeMoveOpPayload)
    case nodeResize(NodeResizeOpPayload)
    case nodeUpdate(NodeUpdateOpPayload)
    case nodeDelete(NodeDeleteOpPayload)
    case connectionAdd(ConnectionAddOpPayload)
    case connectionDelete(ConnectionDeleteOpPayload)
    case tracoAdd(TracoAddOpPayload)
    case tracoDelete(TracoDeleteOpPayload)
    case viewportSet(ViewportSetOpPayload)
    case workspaceRename(WorkspaceRenameOpPayload)

    public var tipo: OpTipo {
        switch self {
        case .nodeAdd: return .nodeAdd
        case .nodeMove: return .nodeMove
        case .nodeResize: return .nodeResize
        case .nodeUpdate: return .nodeUpdate
        case .nodeDelete: return .nodeDelete
        case .connectionAdd: return .connectionAdd
        case .connectionDelete: return .connectionDelete
        case .tracoAdd: return .tracoAdd
        case .tracoDelete: return .tracoDelete
        case .viewportSet: return .viewportSet
        case .workspaceRename: return .workspaceRename
        }
    }
}

/// §7.1 — SOMENTE o engine atribui `seq` (clientes propõem com `seq` nulo em `doc.apply`).
/// NÃO DEVE existir mutação do documento fora de `doc.apply`.
public struct DocOp: Codable, Equatable, Sendable {
    public var opID: ULID
    /// Nulo enquanto proposta; atribuído pelo engine na aplicação; monotônico por workspace.
    public var seq: UInt64?
    public var author: Author
    public var ts: Date
    public var payload: OpPayload
    /// §7.3 — o eco da op DEVE incluir os dados para inversão (undo).
    public var anterior: JSONValue?
    /// §6.3 — relógio lógico para ordem na sala.
    public var logicalClock: UInt64?
    /// §6.3 — número de sequência da sala após aceite.
    public var roomSeq: UInt64?

    public var tipo: OpTipo { payload.tipo }

    enum CodingKeys: String, CodingKey {
        case seq, author, ts, tipo, payload, anterior
        case opID = "op_id"
        case logicalClock = "logical_clock"
        case roomSeq = "room_seq"
    }

    public init(
        opID: ULID,
        seq: UInt64? = nil,
        author: Author,
        ts: Date,
        payload: OpPayload,
        anterior: JSONValue? = nil,
        logicalClock: UInt64? = nil,
        roomSeq: UInt64? = nil
    ) {
        self.opID = opID
        self.seq = seq
        self.author = author
        self.ts = ts
        self.payload = payload
        self.anterior = anterior
        self.logicalClock = logicalClock
        self.roomSeq = roomSeq
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opID = try container.decode(ULID.self, forKey: .opID)
        seq = try container.decodeIfPresent(UInt64.self, forKey: .seq)
        author = try container.decode(Author.self, forKey: .author)
        ts = try container.decode(Date.self, forKey: .ts)
        anterior = try container.decodeIfPresent(JSONValue.self, forKey: .anterior)
        logicalClock = try container.decodeIfPresent(UInt64.self, forKey: .logicalClock)
        roomSeq = try container.decodeIfPresent(UInt64.self, forKey: .roomSeq)
        let tipo = try container.decode(OpTipo.self, forKey: .tipo)
        switch tipo {
        case .nodeAdd:
            payload = .nodeAdd(try container.decode(NodeAddOpPayload.self, forKey: .payload))
        case .nodeMove:
            payload = .nodeMove(try container.decode(NodeMoveOpPayload.self, forKey: .payload))
        case .nodeResize:
            payload = .nodeResize(try container.decode(NodeResizeOpPayload.self, forKey: .payload))
        case .nodeUpdate:
            payload = .nodeUpdate(try container.decode(NodeUpdateOpPayload.self, forKey: .payload))
        case .nodeDelete:
            payload = .nodeDelete(try container.decode(NodeDeleteOpPayload.self, forKey: .payload))
        case .connectionAdd:
            payload = .connectionAdd(try container.decode(ConnectionAddOpPayload.self, forKey: .payload))
        case .connectionDelete:
            payload = .connectionDelete(try container.decode(ConnectionDeleteOpPayload.self, forKey: .payload))
        case .tracoAdd:
            payload = .tracoAdd(try container.decode(TracoAddOpPayload.self, forKey: .payload))
        case .tracoDelete:
            payload = .tracoDelete(try container.decode(TracoDeleteOpPayload.self, forKey: .payload))
        case .viewportSet:
            payload = .viewportSet(try container.decode(ViewportSetOpPayload.self, forKey: .payload))
        case .workspaceRename:
            payload = .workspaceRename(try container.decode(WorkspaceRenameOpPayload.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(opID, forKey: .opID)
        try container.encodeIfPresent(seq, forKey: .seq)
        try container.encode(author, forKey: .author)
        try container.encode(ts, forKey: .ts)
        try container.encode(payload.tipo, forKey: .tipo)
        try container.encodeIfPresent(anterior, forKey: .anterior)
        try container.encodeIfPresent(logicalClock, forKey: .logicalClock)
        try container.encodeIfPresent(roomSeq, forKey: .roomSeq)
        switch payload {
        case .nodeAdd(let value): try container.encode(value, forKey: .payload)
        case .nodeMove(let value): try container.encode(value, forKey: .payload)
        case .nodeResize(let value): try container.encode(value, forKey: .payload)
        case .nodeUpdate(let value): try container.encode(value, forKey: .payload)
        case .nodeDelete(let value): try container.encode(value, forKey: .payload)
        case .connectionAdd(let value): try container.encode(value, forKey: .payload)
        case .connectionDelete(let value): try container.encode(value, forKey: .payload)
        case .tracoAdd(let value): try container.encode(value, forKey: .payload)
        case .tracoDelete(let value): try container.encode(value, forKey: .payload)
        case .viewportSet(let value): try container.encode(value, forKey: .payload)
        case .workspaceRename(let value): try container.encode(value, forKey: .payload)
        }
    }
}

/// §7.4 — forma do snapshot é definida-pela-implementação; esta é a escolhida:
/// estado materializado do canvas até `seq` inclusive.
public struct DocumentSnapshot: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    /// Última op incluída no snapshot; carregar workspace = snapshot + ops com seq maior.
    public var seq: UInt64
    public var nodes: [Node]
    public var connections: [Connection]
    public var criadoEm: Date
    public var noteContents: [String: String]?
    public var sessionStates: [[String: String]]?
    public var sessionOutputs: [String: [[String: String]]]?
    public var watchdogConfiguration: WorkerWatchdogConfiguration?
    public var watchdogHistory: [WatchdogHistoryEntry]?

    enum CodingKeys: String, CodingKey {
        case seq, nodes, connections
        case workspaceID = "workspace_id"
        case criadoEm = "criado_em"
        case noteContents = "note_contents"
        case sessionStates = "session_states"
        case sessionOutputs = "session_outputs"
        case watchdogConfiguration = "watchdog_configuration"
        case watchdogHistory = "watchdog_history"
    }

    public init(workspaceID: ULID, seq: UInt64, nodes: [Node], connections: [Connection], criadoEm: Date,
                noteContents: [String: String]? = nil,
                sessionStates: [[String: String]]? = nil,
                sessionOutputs: [String: [[String: String]]]? = nil,
                watchdogConfiguration: WorkerWatchdogConfiguration? = nil,
                watchdogHistory: [WatchdogHistoryEntry]? = nil) {
        self.workspaceID = workspaceID
        self.seq = seq
        self.nodes = nodes
        self.connections = connections
        self.criadoEm = criadoEm
        self.noteContents = noteContents
        self.sessionStates = sessionStates
        self.sessionOutputs = sessionOutputs
        self.watchdogConfiguration = watchdogConfiguration
        self.watchdogHistory = watchdogHistory
    }
}
