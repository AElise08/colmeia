import Foundation

/// Tópicos de evento (§6.5). `session.output` só flui para clientes com
/// `session.attach` naquela sessão; os demais, para assinantes do workspace.
public enum ColmeiaTopic: String, Codable, CaseIterable, Sendable {
    case sessionOutput = "session.output"
    case sessionState = "session.state"
    case documentOp = "document.op"
    case approvalCreated = "approval.created"
    case approvalResolved = "approval.resolved"
    case messageDelivered = "message.delivered"
    case noteAppended = "note.appended"
    case routineFired = "routine.fired"
    case floorChanged = "floor.changed"
    case engineWarning = "engine.warning"
}

public struct SessionOutputTopicPayload: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var seq: UInt64
    public var dataB64: String

    enum CodingKeys: String, CodingKey {
        case seq
        case sessionID = "session_id"
        case dataB64 = "data_b64"
    }

    public init(sessionID: ULID, seq: UInt64, dataB64: String) {
        self.sessionID = sessionID
        self.seq = seq
        self.dataB64 = dataB64
    }
}

public struct SessionStateTopicPayload: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var estado: SessionEstado
    public var motivo: String?

    enum CodingKeys: String, CodingKey {
        case estado, motivo
        case sessionID = "session_id"
    }

    public init(sessionID: ULID, estado: SessionEstado, motivo: String? = nil) {
        self.sessionID = sessionID
        self.estado = estado
        self.motivo = motivo
    }
}

/// O eco da própria op confirma persistência (§6.5).
public struct DocumentOpTopicPayload: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var op: DocOp
    public var seq: UInt64

    enum CodingKeys: String, CodingKey {
        case op, seq
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID, op: DocOp, seq: UInt64) {
        self.workspaceID = workspaceID
        self.op = op
        self.seq = seq
    }
}

/// Usado por `approval.created` e `approval.resolved`.
public struct ApprovalTopicPayload: Codable, Equatable, Sendable {
    public var approval: Approval

    public init(approval: Approval) {
        self.approval = approval
    }
}

public struct MessageDeliveredTopicPayload: Codable, Equatable, Sendable {
    public var de: ULID
    public var para: ULID
    public var texto: String
    public var messageID: ULID

    enum CodingKeys: String, CodingKey {
        case de, para, texto
        case messageID = "message_id"
    }

    public init(de: ULID, para: ULID, texto: String, messageID: ULID) {
        self.de = de
        self.para = para
        self.texto = texto
        self.messageID = messageID
    }
}

public struct NoteAppendedTopicPayload: Codable, Equatable, Sendable {
    public var nodeID: ULID
    public var fonte: Author
    public var resumo: String

    enum CodingKeys: String, CodingKey {
        case fonte, resumo
        case nodeID = "node_id"
    }

    public init(nodeID: ULID, fonte: Author, resumo: String) {
        self.nodeID = nodeID
        self.fonte = fonte
        self.resumo = resumo
    }
}

public struct RoutineFiredTopicPayload: Codable, Equatable, Sendable {
    public var routineID: ULID
    public var resultado: RoutineResultado

    enum CodingKeys: String, CodingKey {
        case resultado
        case routineID = "routine_id"
    }

    public init(routineID: ULID, resultado: RoutineResultado) {
        self.routineID = routineID
        self.resultado = resultado
    }
}

/// Criação/aterrissagem/descarte/orfandade (§6.5).
public struct FloorChangedTopicPayload: Codable, Equatable, Sendable {
    public var floor: Floor

    public init(floor: Floor) {
        self.floor = floor
    }
}

/// Condições de §22 (ex.: aviso antes de desconectar cliente sem backpressure).
public struct EngineWarningTopicPayload: Codable, Equatable, Sendable {
    public var name: String
    public var message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}
