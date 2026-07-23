import Foundation

/// Tipos de evento do journal (§5.5 / §8.2).
public enum EventTipo: String, Codable, CaseIterable, Sendable {
    case output, input, resize, state, message, approval, note, system
}

/// `output` — chunk cru do PTY; a UI/emulador interpreta escapes (§8.2).
public struct OutputEventPayload: Codable, Equatable, Sendable {
    public var dataB64: String

    enum CodingKeys: String, CodingKey {
        case dataB64 = "data_b64"
    }

    public init(dataB64: String) {
        self.dataB64 = dataB64
    }
}

/// `input` — tudo que entrou no PTY (teclado, approval.resolve, rotina, mensagem),
/// sempre com `author` correto no Event que o envolve (§8.2).
public struct InputEventPayload: Codable, Equatable, Sendable {
    public var dataB64: String

    enum CodingKeys: String, CodingKey {
        case dataB64 = "data_b64"
    }

    public init(dataB64: String) {
        self.dataB64 = dataB64
    }
}

public struct ResizeEventPayload: Codable, Equatable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// Transições da máquina de estados (§11.2).
public struct StateEventPayload: Codable, Equatable, Sendable {
    public var de: SessionEstado
    public var para: SessionEstado
    public var motivo: String?

    public init(de: SessionEstado, para: SessionEstado, motivo: String? = nil) {
        self.de = de
        self.para = para
        self.motivo = motivo
    }
}

public enum MessageDirecao: String, Codable, CaseIterable, Sendable {
    case enviada, recebida
}

/// §8.2/§14 — gravado nos journals de AMBAS as sessões.
public struct MessageEventPayload: Codable, Equatable, Sendable {
    public var direcao: MessageDirecao
    public var contraparte: ULID
    public var texto: String
    public var messageID: ULID

    enum CodingKeys: String, CodingKey {
        case direcao, contraparte, texto
        case messageID = "message_id"
    }

    public init(direcao: MessageDirecao, contraparte: ULID, texto: String, messageID: ULID) {
        self.direcao = direcao
        self.contraparte = contraparte
        self.texto = texto
        self.messageID = messageID
    }
}

public enum ApprovalAcao: String, Codable, CaseIterable, Sendable {
    case criada, resolvida
}

public struct ApprovalEventPayload: Codable, Equatable, Sendable {
    public var approvalID: ULID
    public var acao: ApprovalAcao
    public var decisao: ApprovalDecisao?

    enum CodingKeys: String, CodingKey {
        case acao, decisao
        case approvalID = "approval_id"
    }

    public init(approvalID: ULID, acao: ApprovalAcao, decisao: ApprovalDecisao? = nil) {
        self.approvalID = approvalID
        self.acao = acao
        self.decisao = decisao
    }
}

/// Escrita via `colmeia note` (§13.3).
public struct NoteEventPayload: Codable, Equatable, Sendable {
    public var notaNodeID: ULID
    public var resumo: String

    enum CodingKeys: String, CodingKey {
        case resumo
        case notaNodeID = "nota_node_id"
    }

    public init(notaNodeID: ULID, resumo: String) {
        self.notaNodeID = notaNodeID
        self.resumo = resumo
    }
}

/// Rotina pulada, adapter degradado, reconexão… (§8.2).
public struct SystemEventPayload: Codable, Equatable, Sendable {
    public var name: String
    public var message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}

public enum EventPayload: Equatable, Sendable {
    case output(OutputEventPayload)
    case input(InputEventPayload)
    case resize(ResizeEventPayload)
    case state(StateEventPayload)
    case message(MessageEventPayload)
    case approval(ApprovalEventPayload)
    case note(NoteEventPayload)
    case system(SystemEventPayload)

    public var tipo: EventTipo {
        switch self {
        case .output: return .output
        case .input: return .input
        case .resize: return .resize
        case .state: return .state
        case .message: return .message
        case .approval: return .approval
        case .note: return .note
        case .system: return .system
        }
    }
}

/// §5.5 — unidade atômica do journal. `seq` é monotônico por sessão, começa em 1,
/// sem buracos; leitores DEVEM tratar buraco como corrupção (§8.1).
public struct Event: Codable, Equatable, Sendable {
    public var seq: UInt64
    public var ts: Date
    public var author: Author
    public var payload: EventPayload

    public var tipo: EventTipo { payload.tipo }

    enum CodingKeys: String, CodingKey {
        case seq, ts, author, tipo, payload
    }

    public init(seq: UInt64, ts: Date, author: Author, payload: EventPayload) {
        self.seq = seq
        self.ts = ts
        self.author = author
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(UInt64.self, forKey: .seq)
        ts = try container.decode(Date.self, forKey: .ts)
        author = try container.decode(Author.self, forKey: .author)
        let tipo = try container.decode(EventTipo.self, forKey: .tipo)
        switch tipo {
        case .output:
            payload = .output(try container.decode(OutputEventPayload.self, forKey: .payload))
        case .input:
            payload = .input(try container.decode(InputEventPayload.self, forKey: .payload))
        case .resize:
            payload = .resize(try container.decode(ResizeEventPayload.self, forKey: .payload))
        case .state:
            payload = .state(try container.decode(StateEventPayload.self, forKey: .payload))
        case .message:
            payload = .message(try container.decode(MessageEventPayload.self, forKey: .payload))
        case .approval:
            payload = .approval(try container.decode(ApprovalEventPayload.self, forKey: .payload))
        case .note:
            payload = .note(try container.decode(NoteEventPayload.self, forKey: .payload))
        case .system:
            payload = .system(try container.decode(SystemEventPayload.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(ts, forKey: .ts)
        try container.encode(author, forKey: .author)
        try container.encode(payload.tipo, forKey: .tipo)
        switch payload {
        case .output(let value): try container.encode(value, forKey: .payload)
        case .input(let value): try container.encode(value, forKey: .payload)
        case .resize(let value): try container.encode(value, forKey: .payload)
        case .state(let value): try container.encode(value, forKey: .payload)
        case .message(let value): try container.encode(value, forKey: .payload)
        case .approval(let value): try container.encode(value, forKey: .payload)
        case .note(let value): try container.encode(value, forKey: .payload)
        case .system(let value): try container.encode(value, forKey: .payload)
        }
    }
}
