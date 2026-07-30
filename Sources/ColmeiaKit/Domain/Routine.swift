import Foundation

public enum AgendaTipo: String, Codable, CaseIterable, Sendable {
    case once, intervalo, diaria, semanal
}

/// §5.7 — `fim_repeticao (timestamp | nunca)`: no wire, ou uma data ISO-8601 ou a string "nunca".
public enum FimRepeticao: Codable, Equatable, Sendable {
    case nunca
    case em(Date)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let date = try? container.decode(Date.self) {
            self = .em(date)
            return
        }
        let raw = try container.decode(String.self)
        guard raw == "nunca" else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "fim_repeticao deve ser timestamp ou \"nunca\", veio: \(raw)"
            )
        }
        self = .nunca
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .nunca: try container.encode("nunca")
        case .em(let date): try container.encode(date)
        }
    }
}

public struct Agenda: Codable, Equatable, Sendable {
    public var tipo: AgendaTipo
    /// Apenas tipo `intervalo`.
    public var intervaloSeg: Int?
    /// "HH:mm" — tipos `diaria`/`semanal`.
    public var hora: String?
    /// Dias da semana — tipo `semanal`.
    public var dias: [Int]?
    public var inicio: Date
    public var fimRepeticao: FimRepeticao

    enum CodingKeys: String, CodingKey {
        case tipo, hora, dias, inicio
        case intervaloSeg = "intervalo_seg"
        case fimRepeticao = "fim_repeticao"
    }

    public init(
        tipo: AgendaTipo,
        intervaloSeg: Int? = nil,
        hora: String? = nil,
        dias: [Int]? = nil,
        inicio: Date,
        fimRepeticao: FimRepeticao = .nunca
    ) {
        self.tipo = tipo
        self.intervaloSeg = intervaloSeg
        self.hora = hora
        self.dias = dias
        self.inicio = inicio
        self.fimRepeticao = fimRepeticao
    }
}

public enum RoutineResultado: String, Codable, CaseIterable, Sendable {
    case executada
    case puladaOcupado = "pulada_ocupado"
    case puladaAlvoAusente = "pulada_alvo_ausente"
}

/// Estado derivado da agenda, persistido para que um `once` vencido não seja
/// indistinguível de uma rotina sem próxima execução por outro motivo (§17.4).
/// Clientes anteriores ignoram o campo `estado_agenda` conforme §0.
public enum RoutineEstadoAgenda: String, Codable, CaseIterable, Sendable {
    case agendada
    case pendenteAtrasada = "pendente_atrasada"
    case concluida
}

public struct UltimaExecucao: Codable, Equatable, Sendable {
    public var ts: Date
    public var resultado: RoutineResultado

    public init(ts: Date, resultado: RoutineResultado) {
        self.ts = ts
        self.resultado = resultado
    }
}

/// §5.7 — prompt agendado injetado no PTY do alvo (§17).
public struct Routine: Codable, Equatable, Sendable {
    public var id: ULID
    public var nome: String
    public var workspaceID: ULID
    /// TerminalNode alvo.
    public var alvo: ULID
    /// Prompt/linha a injetar no PTY do alvo.
    public var comando: String
    public var agenda: Agenda
    public var notificar: Bool
    public var habilitada: Bool
    /// Derivada; recalculada pelo engine.
    public var proximaExecucao: Date?
    public var ultimaExecucao: UltimaExecucao?
    /// `once` passado e ainda não executado fica pendente para decisão explícita
    /// da usuária; o scheduler nunca o dispara sozinho (§17.4).
    public var estadoAgenda: RoutineEstadoAgenda

    enum CodingKeys: String, CodingKey {
        case id, nome, alvo, comando, agenda, notificar, habilitada
        case workspaceID = "workspace_id"
        case proximaExecucao = "proxima_execucao"
        case ultimaExecucao = "ultima_execucao"
        case estadoAgenda = "estado_agenda"
    }

    public init(
        id: ULID,
        nome: String,
        workspaceID: ULID,
        alvo: ULID,
        comando: String,
        agenda: Agenda,
        notificar: Bool = false,
        habilitada: Bool = true,
        proximaExecucao: Date? = nil,
        ultimaExecucao: UltimaExecucao? = nil,
        estadoAgenda: RoutineEstadoAgenda = .agendada
    ) {
        self.id = id
        self.nome = nome
        self.workspaceID = workspaceID
        self.alvo = alvo
        self.comando = comando
        self.agenda = agenda
        self.notificar = notificar
        self.habilitada = habilitada
        self.proximaExecucao = proximaExecucao
        self.ultimaExecucao = ultimaExecucao
        self.estadoAgenda = estadoAgenda
    }

    /// Conveniência para a UI e para migração de `routines.json` antigos.
    public var pendenteAtrasada: Bool { estadoAgenda == .pendenteAtrasada }

    /// `estado_agenda` foi adicionado depois dos primeiros arquivos persistidos;
    /// ausente significa que o engine deve recalcular durante o boot.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ULID.self, forKey: .id)
        nome = try container.decode(String.self, forKey: .nome)
        workspaceID = try container.decode(ULID.self, forKey: .workspaceID)
        alvo = try container.decode(ULID.self, forKey: .alvo)
        comando = try container.decode(String.self, forKey: .comando)
        agenda = try container.decode(Agenda.self, forKey: .agenda)
        notificar = try container.decode(Bool.self, forKey: .notificar)
        habilitada = try container.decode(Bool.self, forKey: .habilitada)
        proximaExecucao = try container.decodeIfPresent(Date.self, forKey: .proximaExecucao)
        ultimaExecucao = try container.decodeIfPresent(UltimaExecucao.self, forKey: .ultimaExecucao)
        estadoAgenda = try container.decodeIfPresent(RoutineEstadoAgenda.self, forKey: .estadoAgenda) ?? .agendada
    }
}
