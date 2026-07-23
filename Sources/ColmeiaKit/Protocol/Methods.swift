import Foundation

/// Inventário completo de métodos (§6.4).
public enum ColmeiaMethod: String, Codable, CaseIterable, Sendable {
    case hello
    case workspaceList = "workspace.list"
    case workspaceCreate = "workspace.create"
    case workspaceOpen = "workspace.open"
    case workspaceClose = "workspace.close"
    case workspaceDelete = "workspace.delete"
    case workspaceUpdate = "workspace.update"
    case docApply = "doc.apply"
    case docSnapshot = "doc.snapshot"
    case docHistory = "doc.history"
    case sessionStart = "session.start"
    case sessionAttach = "session.attach"
    case sessionInput = "session.input"
    case sessionResize = "session.resize"
    case sessionKill = "session.kill"
    case sessionList = "session.list"
    case sessionReplay = "session.replay"
    case approvalList = "approval.list"
    case approvalResolve = "approval.resolve"
    case messageSend = "message.send"
    case noteAppend = "note.append"
    case routineCreate = "routine.create"
    case routineUpdate = "routine.update"
    case routineDelete = "routine.delete"
    case routineList = "routine.list"
    case routineRunNow = "routine.run_now"
    case floorCreate = "floor.create"
    case floorSwitch = "floor.switch"
    case floorLand = "floor.land"
    case floorDiscard = "floor.discard"
    case floorList = "floor.list"
    case subscribe
    case unsubscribe
    case engineStatus = "engine.status"
    case engineShutdown = "engine.shutdown"
}

/// Resultado `{}`.
public struct EmptyResult: Codable, Equatable, Sendable {
    public init() {}
}

// MARK: - hello (§6.3)

/// CLI dentro de terminal gerenciado DEVE usar `author: agente:<node-id>` (env COLMEIA_NODE_ID).
public struct HelloParams: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// "canvas-ui" | "cli" | "test".
    public var client: String
    public var author: Author

    enum CodingKeys: String, CodingKey {
        case client, author
        case protocolVersion = "protocol_version"
    }

    public init(protocolVersion: Int = ColmeiaVersion.protocolVersion, client: String, author: Author) {
        self.protocolVersion = protocolVersion
        self.client = client
        self.author = author
    }
}

public struct HelloResult: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var engineVersion: String
    public var engineStartedEm: Date

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case engineVersion = "engine_version"
        case engineStartedEm = "engine_started_em"
    }

    public init(protocolVersion: Int, engineVersion: String, engineStartedEm: Date) {
        self.protocolVersion = protocolVersion
        self.engineVersion = engineVersion
        self.engineStartedEm = engineStartedEm
    }
}

// MARK: - workspace.*

public struct WorkspaceSummary: Codable, Equatable, Sendable {
    public var id: ULID
    public var nome: String
    public var caminhoRaiz: String?
    public var atualizadoEm: Date

    enum CodingKeys: String, CodingKey {
        case id, nome
        case caminhoRaiz = "caminho_raiz"
        case atualizadoEm = "atualizado_em"
    }

    public init(id: ULID, nome: String, caminhoRaiz: String? = nil, atualizadoEm: Date) {
        self.id = id
        self.nome = nome
        self.caminhoRaiz = caminhoRaiz
        self.atualizadoEm = atualizadoEm
    }
}

public typealias WorkspaceListResult = [WorkspaceSummary]

public struct WorkspaceCreateParams: Codable, Equatable, Sendable {
    public var nome: String
    public var caminhoRaiz: String?

    enum CodingKeys: String, CodingKey {
        case nome
        case caminhoRaiz = "caminho_raiz"
    }

    public init(nome: String, caminhoRaiz: String? = nil) {
        self.nome = nome
        self.caminhoRaiz = caminhoRaiz
    }
}

public struct WorkspaceResult: Codable, Equatable, Sendable {
    public var workspace: Workspace

    public init(workspace: Workspace) {
        self.workspace = workspace
    }
}

public struct WorkspaceOpenParams: Codable, Equatable, Sendable {
    public var id: ULID

    public init(id: ULID) {
        self.id = id
    }
}

public struct WorkspaceOpenResult: Codable, Equatable, Sendable {
    public var workspace: Workspace
    public var documentSnapshot: DocumentSnapshot

    enum CodingKeys: String, CodingKey {
        case workspace
        case documentSnapshot = "document_snapshot"
    }

    public init(workspace: Workspace, documentSnapshot: DocumentSnapshot) {
        self.workspace = workspace
        self.documentSnapshot = documentSnapshot
    }
}

/// Sessões continuam vivas (§6.4).
public struct WorkspaceCloseParams: Codable, Equatable, Sendable {
    public var id: ULID

    public init(id: ULID) {
        self.id = id
    }
}

/// DEVE falhar com sessões ativas; sem `confirmar: true` → `confirmation_required`.
public struct WorkspaceDeleteParams: Codable, Equatable, Sendable {
    public var id: ULID
    public var confirmar: Bool

    public init(id: ULID, confirmar: Bool) {
        self.id = id
        self.confirmar = confirmar
    }
}

public struct WorkspaceUpdateParams: Codable, Equatable, Sendable {
    public var id: ULID
    public var nome: String?
    public var caminhoRaiz: String?
    public var viewport: Viewport?

    enum CodingKeys: String, CodingKey {
        case id, nome, viewport
        case caminhoRaiz = "caminho_raiz"
    }

    public init(id: ULID, nome: String? = nil, caminhoRaiz: String? = nil, viewport: Viewport? = nil) {
        self.id = id
        self.nome = nome
        self.caminhoRaiz = caminhoRaiz
        self.viewport = viewport
    }
}

// MARK: - doc.*

public struct DocApplyParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var ops: [DocOp]

    enum CodingKeys: String, CodingKey {
        case ops
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID, ops: [DocOp]) {
        self.workspaceID = workspaceID
        self.ops = ops
    }
}

public struct DocApplyResult: Codable, Equatable, Sendable {
    public var seqFinal: UInt64

    enum CodingKeys: String, CodingKey {
        case seqFinal = "seq_final"
    }

    public init(seqFinal: UInt64) {
        self.seqFinal = seqFinal
    }
}

public struct DocSnapshotParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID) {
        self.workspaceID = workspaceID
    }
}

public struct DocSnapshotResult: Codable, Equatable, Sendable {
    public var documentSnapshot: DocumentSnapshot

    enum CodingKeys: String, CodingKey {
        case documentSnapshot = "document_snapshot"
    }

    public init(documentSnapshot: DocumentSnapshot) {
        self.documentSnapshot = documentSnapshot
    }
}

public struct DocHistoryParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var desdeSeq: UInt64
    public var ateSeq: UInt64?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case desdeSeq = "desde_seq"
        case ateSeq = "ate_seq"
    }

    public init(workspaceID: ULID, desdeSeq: UInt64, ateSeq: UInt64? = nil) {
        self.workspaceID = workspaceID
        self.desdeSeq = desdeSeq
        self.ateSeq = ateSeq
    }
}

public struct DocHistoryResult: Codable, Equatable, Sendable {
    public var ops: [DocOp]

    public init(ops: [DocOp]) {
        self.ops = ops
    }
}

// MARK: - session.*

public struct SessionStartParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
    }

    public init(workspaceID: ULID, nodeID: ULID) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
    }
}

public struct SessionResult: Codable, Equatable, Sendable {
    public var session: Session

    public init(session: Session) {
        self.session = session
    }
}

/// Replay + stream ao vivo emendados sem buraco nem duplicata (§8.4).
public struct SessionAttachParams: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var desdeSeq: UInt64?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case desdeSeq = "desde_seq"
    }

    public init(sessionID: ULID, desdeSeq: UInt64? = nil) {
        self.sessionID = sessionID
        self.desdeSeq = desdeSeq
    }
}

public struct SessionAttachResult: Codable, Equatable, Sendable {
    public var session: Session
    public var replay: [Event]

    public init(session: Session, replay: [Event]) {
        self.session = session
        self.replay = replay
    }
}

public struct SessionInputParams: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var dataB64: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case dataB64 = "data_b64"
    }

    public init(sessionID: ULID, dataB64: String) {
        self.sessionID = sessionID
        self.dataB64 = dataB64
    }
}

public struct SessionResizeParams: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var cols: Int
    public var rows: Int

    enum CodingKeys: String, CodingKey {
        case cols, rows
        case sessionID = "session_id"
    }

    public init(sessionID: ULID, cols: Int, rows: Int) {
        self.sessionID = sessionID
        self.cols = cols
        self.rows = rows
    }
}

public enum KillSinal: String, Codable, CaseIterable, Sendable {
    case term, kill
}

public struct SessionKillParams: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var sinal: KillSinal?

    enum CodingKeys: String, CodingKey {
        case sinal
        case sessionID = "session_id"
    }

    public init(sessionID: ULID, sinal: KillSinal? = nil) {
        self.sessionID = sessionID
        self.sinal = sinal
    }
}

public struct SessionListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID? = nil) {
        self.workspaceID = workspaceID
    }
}

public typealias SessionListResult = [Session]

/// Funciona para sessões encerradas (§6.4).
public struct SessionReplayParams: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var desdeSeq: UInt64?
    public var ateSeq: UInt64?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case desdeSeq = "desde_seq"
        case ateSeq = "ate_seq"
    }

    public init(sessionID: ULID, desdeSeq: UInt64? = nil, ateSeq: UInt64? = nil) {
        self.sessionID = sessionID
        self.desdeSeq = desdeSeq
        self.ateSeq = ateSeq
    }
}

public struct SessionReplayResult: Codable, Equatable, Sendable {
    public var events: [Event]

    public init(events: [Event]) {
        self.events = events
    }
}

// MARK: - approval.*

public struct ApprovalListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID?
    public var estado: ApprovalEstado?

    enum CodingKeys: String, CodingKey {
        case estado
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID? = nil, estado: ApprovalEstado? = nil) {
        self.workspaceID = workspaceID
        self.estado = estado
    }
}

public typealias ApprovalListResult = [Approval]

public struct ApprovalResolveParams: Codable, Equatable, Sendable {
    public var approvalID: ULID
    public var decisao: ApprovalDecisao
    public var opcaoIndex: Int?

    enum CodingKeys: String, CodingKey {
        case decisao
        case approvalID = "approval_id"
        case opcaoIndex = "opcao_index"
    }

    public init(approvalID: ULID, decisao: ApprovalDecisao, opcaoIndex: Int? = nil) {
        self.approvalID = approvalID
        self.decisao = decisao
        self.opcaoIndex = opcaoIndex
    }
}

public struct ApprovalResult: Codable, Equatable, Sendable {
    public var approval: Approval

    public init(approval: Approval) {
        self.approval = approval
    }
}

// MARK: - message.send (§14)

public struct MessageSendParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var deNode: ULID
    /// Endereçamento por NOME do nó (único case-insensitive no workspace, §5.2.1).
    public var paraNome: String
    public var texto: String
    public var timeoutSeg: Int?

    enum CodingKeys: String, CodingKey {
        case texto
        case workspaceID = "workspace_id"
        case deNode = "de_node"
        case paraNome = "para_nome"
        case timeoutSeg = "timeout_seg"
    }

    public init(workspaceID: ULID, deNode: ULID, paraNome: String, texto: String, timeoutSeg: Int? = nil) {
        self.workspaceID = workspaceID
        self.deNode = deNode
        self.paraNome = paraNome
        self.texto = texto
        self.timeoutSeg = timeoutSeg
    }
}

public struct MessageSendResult: Codable, Equatable, Sendable {
    public var messageID: ULID

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }

    public init(messageID: ULID) {
        self.messageID = messageID
    }
}

// MARK: - note.append (§13.3)

/// Sem conexão `escrita-de-nota`, o engine DEVE criar NotaNode adjacente e conectá-la.
public struct NoteAppendParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeIDOrigem: ULID
    public var texto: String

    enum CodingKeys: String, CodingKey {
        case texto
        case workspaceID = "workspace_id"
        case nodeIDOrigem = "node_id_origem"
    }

    public init(workspaceID: ULID, nodeIDOrigem: ULID, texto: String) {
        self.workspaceID = workspaceID
        self.nodeIDOrigem = nodeIDOrigem
        self.texto = texto
    }
}

public struct NoteAppendResult: Codable, Equatable, Sendable {
    public var notaNodeID: ULID

    enum CodingKeys: String, CodingKey {
        case notaNodeID = "nota_node_id"
    }

    public init(notaNodeID: ULID) {
        self.notaNodeID = notaNodeID
    }
}

// MARK: - routine.* (§5.7/§17)

public struct RoutineCreateParams: Codable, Equatable, Sendable {
    public var nome: String
    public var workspaceID: ULID
    public var alvo: ULID
    public var comando: String
    public var agenda: Agenda
    public var notificar: Bool
    public var habilitada: Bool

    enum CodingKeys: String, CodingKey {
        case nome, alvo, comando, agenda, notificar, habilitada
        case workspaceID = "workspace_id"
    }

    public init(
        nome: String,
        workspaceID: ULID,
        alvo: ULID,
        comando: String,
        agenda: Agenda,
        notificar: Bool = false,
        habilitada: Bool = true
    ) {
        self.nome = nome
        self.workspaceID = workspaceID
        self.alvo = alvo
        self.comando = comando
        self.agenda = agenda
        self.notificar = notificar
        self.habilitada = habilitada
    }
}

public struct RoutineUpdateParams: Codable, Equatable, Sendable {
    public var id: ULID
    public var nome: String?
    public var alvo: ULID?
    public var comando: String?
    public var agenda: Agenda?
    public var notificar: Bool?
    public var habilitada: Bool?

    public init(
        id: ULID,
        nome: String? = nil,
        alvo: ULID? = nil,
        comando: String? = nil,
        agenda: Agenda? = nil,
        notificar: Bool? = nil,
        habilitada: Bool? = nil
    ) {
        self.id = id
        self.nome = nome
        self.alvo = alvo
        self.comando = comando
        self.agenda = agenda
        self.notificar = notificar
        self.habilitada = habilitada
    }
}

public struct RoutineDeleteParams: Codable, Equatable, Sendable {
    public var id: ULID

    public init(id: ULID) {
        self.id = id
    }
}

public struct RoutineResult: Codable, Equatable, Sendable {
    public var routine: Routine

    public init(routine: Routine) {
        self.routine = routine
    }
}

public struct RoutineListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID) {
        self.workspaceID = workspaceID
    }
}

public typealias RoutineListResult = [Routine]

public struct RoutineRunNowParams: Codable, Equatable, Sendable {
    public var routineID: ULID

    enum CodingKeys: String, CodingKey {
        case routineID = "routine_id"
    }

    public init(routineID: ULID) {
        self.routineID = routineID
    }
}

public struct RoutineRunNowResult: Codable, Equatable, Sendable {
    public var resultado: RoutineResultado

    public init(resultado: RoutineResultado) {
        self.resultado = resultado
    }
}

// MARK: - floor.* (§16)

public struct FloorCreateParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nome: String
    public var branch: String?

    enum CodingKeys: String, CodingKey {
        case nome, branch
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID, nome: String, branch: String? = nil) {
        self.workspaceID = workspaceID
        self.nome = nome
        self.branch = branch
    }
}

public struct FloorResult: Codable, Equatable, Sendable {
    public var floor: Floor

    public init(floor: Floor) {
        self.floor = floor
    }
}

public struct FloorSwitchParams: Codable, Equatable, Sendable {
    public var floorID: ULID

    enum CodingKeys: String, CodingKey {
        case floorID = "floor_id"
    }

    public init(floorID: ULID) {
        self.floorID = floorID
    }
}

/// A spec (§6.4) não fixa a forma de `nos`; fica genérico até a implementação de §16.
public struct FloorSwitchResult: Codable, Equatable, Sendable {
    public var floor: Floor
    public var nos: JSONValue

    public init(floor: Floor, nos: JSONValue) {
        self.floor = floor
        self.nos = nos
    }
}

public struct FloorLandParams: Codable, Equatable, Sendable {
    public var floorID: ULID
    public var confirmar: Bool

    enum CodingKeys: String, CodingKey {
        case confirmar
        case floorID = "floor_id"
    }

    public init(floorID: ULID, confirmar: Bool) {
        self.floorID = floorID
        self.confirmar = confirmar
    }
}

public struct FloorDiscardParams: Codable, Equatable, Sendable {
    public var floorID: ULID
    public var confirmar: Bool

    enum CodingKeys: String, CodingKey {
        case confirmar
        case floorID = "floor_id"
    }

    public init(floorID: ULID, confirmar: Bool) {
        self.floorID = floorID
        self.confirmar = confirmar
    }
}

public struct FloorListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID) {
        self.workspaceID = workspaceID
    }
}

public typealias FloorListResult = [Floor]

// MARK: - subscribe / unsubscribe

public struct SubscribeParams: Codable, Equatable, Sendable {
    public var topics: [ColmeiaTopic]
    public var workspaceID: ULID?

    enum CodingKeys: String, CodingKey {
        case topics
        case workspaceID = "workspace_id"
    }

    public init(topics: [ColmeiaTopic], workspaceID: ULID? = nil) {
        self.topics = topics
        self.workspaceID = workspaceID
    }
}

public struct UnsubscribeParams: Codable, Equatable, Sendable {
    public var topics: [ColmeiaTopic]

    public init(topics: [ColmeiaTopic]) {
        self.topics = topics
    }
}

// MARK: - engine.*

public struct EngineStatusResult: Codable, Equatable, Sendable {
    public var sessionsAtivas: Int
    public var workspacesAbertos: Int
    /// Segundos desde o start do engine.
    public var uptime: Double
    public var versao: String

    enum CodingKeys: String, CodingKey {
        case uptime, versao
        case sessionsAtivas = "sessions_ativas"
        case workspacesAbertos = "workspaces_abertos"
    }

    public init(sessionsAtivas: Int, workspacesAbertos: Int, uptime: Double, versao: String) {
        self.sessionsAtivas = sessionsAtivas
        self.workspacesAbertos = workspacesAbertos
        self.uptime = uptime
        self.versao = versao
    }
}

/// DEVE fazer flush e encerrar sessões graciosamente (§6.4).
public struct EngineShutdownParams: Codable, Equatable, Sendable {
    public var confirmar: Bool

    public init(confirmar: Bool) {
        self.confirmar = confirmar
    }
}
