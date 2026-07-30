import Foundation

// §5.7 / §9.4
public enum DeliveryEstado: String, Codable, CaseIterable, Sendable {
    case draft
    case proposed
    case accepted
    case partial
    case blocked
    case failed
    case reopened

    /// Legado pré-SPEC: decodifica como `accepted`.
    public static func decodeLegacy(_ raw: String) -> DeliveryEstado? {
        if raw == "completed" { return .accepted }
        return DeliveryEstado(rawValue: raw)
    }
}

public enum DeliveryEvidenceTipo: String, Codable, CaseIterable, Sendable {
    case file
    case diff
    case commit
    case test
    case note
    case portal
    case outputExcerpt = "output_excerpt"
    case artifact
}

public enum DeliveryTestResultado: String, Codable, CaseIterable, Sendable {
    case passed
    case failed
    case skipped
}

public struct DeliveryEvidence: Codable, Equatable, Sendable {
    public static let maxReferenciaLength = 16_384
    public static let maxDescricaoLength = 1_000

    public var id: ULID
    public var tipo: DeliveryEvidenceTipo
    public var referencia: String
    public var descricao: String?
    public var sha256: String?
    public var resultadoTeste: DeliveryTestResultado?
    public var autor: Author
    public var criadaEm: Date

    enum CodingKeys: String, CodingKey {
        case id, tipo, referencia, descricao, sha256, autor
        case resultadoTeste = "resultado_teste"
        case criadaEm = "criada_em"
    }

    public init(
        id: ULID,
        tipo: DeliveryEvidenceTipo,
        referencia: String,
        descricao: String? = nil,
        sha256: String? = nil,
        resultadoTeste: DeliveryTestResultado? = nil,
        autor: Author,
        criadaEm: Date
    ) {
        self.id = id
        self.tipo = tipo
        self.referencia = referencia
        self.descricao = descricao
        self.sha256 = sha256
        self.resultadoTeste = resultadoTeste
        self.autor = autor
        self.criadaEm = criadaEm
    }

    public func validate() throws {
        let reference = referencia.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, reference.count <= Self.maxReferenciaLength else {
            throw DeliveryValidationError.evidenciaInvalida(id: id, reason: "referência vazia ou longa demais")
        }
        if let descricao, descricao.count > Self.maxDescricaoLength {
            throw DeliveryValidationError.evidenciaInvalida(id: id, reason: "descrição longa demais")
        }
        if let sha256, !Self.isSHA256(sha256) {
            throw DeliveryValidationError.evidenciaInvalida(id: id, reason: "sha256 inválido")
        }

        switch tipo {
        case .file, .artifact:
            guard Self.isRelativePath(reference) else {
                throw DeliveryValidationError.evidenciaInvalida(id: id, reason: "caminho deve ser relativo e contido")
            }
        case .diff:
            guard sha256 != nil else {
                throw DeliveryValidationError.evidenciaInvalida(id: id, reason: "diff exige sha256")
            }
        case .commit:
            guard Self.isCommitHash(reference) else {
                throw DeliveryValidationError.evidenciaInvalida(id: id, reason: "hash de commit inválido")
            }
        case .test:
            guard resultadoTeste != nil, Self.isTestIdentifier(reference) else {
                throw DeliveryValidationError.evidenciaInvalida(id: id, reason: "teste exige identificador e resultado, não comando")
            }
        case .note:
            guard ULID(reference) != nil else {
                throw DeliveryValidationError.evidenciaInvalida(id: id, reason: "referência de nota deve ser ULID")
            }
        case .portal:
            guard let url = URL(string: reference), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host != nil else {
                throw DeliveryValidationError.evidenciaInvalida(id: id, reason: "portal exige URL http(s)")
            }
        case .outputExcerpt:
            guard !reference.contains("\0") else {
                throw DeliveryValidationError.evidenciaInvalida(id: id, reason: "output contém NUL")
            }
        }

        if tipo != .test, resultadoTeste != nil {
            throw DeliveryValidationError.evidenciaInvalida(id: id, reason: "resultado de teste só vale para evidência test")
        }
    }

    private static func isRelativePath(_ value: String) -> Bool {
        guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("\\") else { return false }
        return !value.split(separator: "/").contains("..")
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character(String($0))) ||
            ("a"..."f").contains(Character(String($0))) ||
            ("A"..."F").contains(Character(String($0)))
        }
    }

    private static func isCommitHash(_ value: String) -> Bool {
        guard (7...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character(String($0))) ||
            ("a"..."f").contains(Character(String($0))) ||
            ("A"..."F").contains(Character(String($0)))
        }
    }

    private static func isTestIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(Character(String(scalar))) ||
            ("A"..."Z").contains(Character(String(scalar))) ||
            ("0"..."9").contains(Character(String(scalar))) ||
            [".", "_", "/", ":", "-"].contains(Character(String(scalar)))
        }
    }
}

public struct DeliverySubmission: Codable, Equatable, Sendable {
    public static let maxResumoLength = 2_000

    public var id: ULID
    public var workspaceID: ULID
    public var sessionID: ULID
    public var nodeID: ULID
    public var missionID: ULID?
    public var workstreamID: ULID?
    public var estado: DeliveryEstado
    public var resumo: String
    public var evidencias: [DeliveryEvidence]

    enum CodingKeys: String, CodingKey {
        case id, estado, resumo, evidencias
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
        case nodeID = "node_id"
        case missionID = "mission_id"
        case workstreamID = "workstream_id"
    }

    public init(
        id: ULID,
        workspaceID: ULID,
        sessionID: ULID,
        nodeID: ULID,
        missionID: ULID? = nil,
        workstreamID: ULID? = nil,
        estado: DeliveryEstado,
        resumo: String,
        evidencias: [DeliveryEvidence]
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.nodeID = nodeID
        self.missionID = missionID
        self.workstreamID = workstreamID
        self.estado = estado
        self.resumo = resumo
        self.evidencias = evidencias
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ULID.self, forKey: .id)
        workspaceID = try c.decode(ULID.self, forKey: .workspaceID)
        sessionID = try c.decode(ULID.self, forKey: .sessionID)
        nodeID = try c.decode(ULID.self, forKey: .nodeID)
        missionID = try c.decodeIfPresent(ULID.self, forKey: .missionID)
        workstreamID = try c.decodeIfPresent(ULID.self, forKey: .workstreamID)
        if let raw = try c.decodeIfPresent(String.self, forKey: .estado),
           let decoded = DeliveryEstado.decodeLegacy(raw) {
            estado = decoded
        } else {
            estado = try c.decode(DeliveryEstado.self, forKey: .estado)
        }
        resumo = try c.decode(String.self, forKey: .resumo)
        evidencias = try c.decodeIfPresent([DeliveryEvidence].self, forKey: .evidencias) ?? []
    }

    public func validate() throws {
        let normalized = resumo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw DeliveryValidationError.resumoObrigatorio }
        guard normalized.count <= Self.maxResumoLength else {
            throw DeliveryValidationError.resumoLongo(maximo: Self.maxResumoLength)
        }
        // §5.7 — accepted/proposed com aceite exigem evidência; proposed exige prova para fluxo de revisão.
        if estado == .accepted || estado == .proposed, evidencias.isEmpty {
            throw DeliveryValidationError.evidenciasObrigatorias
        }
        var ids = Set<ULID>()
        for evidence in evidencias {
            guard ids.insert(evidence.id).inserted else {
                throw DeliveryValidationError.evidenciaDuplicada(evidence.id)
            }
            try evidence.validate()
        }
    }
}

public enum DeliveryHistoryAction: String, Codable, CaseIterable, Sendable {
    case submitted
    case accepted
    case reopened
}

public struct DeliveryHistoryEntry: Codable, Equatable, Sendable {
    public var acao: DeliveryHistoryAction
    public var autor: Author
    public var em: Date
    public var estado: DeliveryEstado

    public init(acao: DeliveryHistoryAction, autor: Author, em: Date, estado: DeliveryEstado) {
        self.acao = acao
        self.autor = autor
        self.em = em
        self.estado = estado
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        acao = try c.decode(DeliveryHistoryAction.self, forKey: .acao)
        autor = try c.decode(Author.self, forKey: .autor)
        em = try c.decode(Date.self, forKey: .em)
        if let raw = try c.decodeIfPresent(String.self, forKey: .estado),
           let decoded = DeliveryEstado.decodeLegacy(raw) {
            estado = decoded
        } else {
            estado = try c.decode(DeliveryEstado.self, forKey: .estado)
        }
    }

    enum CodingKeys: String, CodingKey {
        case acao, autor, em, estado
    }
}

// §5.7
public struct Delivery: Codable, Equatable, Sendable {
    public var id: ULID
    public var workspaceID: ULID
    public var sessionID: ULID
    public var nodeID: ULID
    public var missionID: ULID?
    public var workstreamID: ULID?
    public var estado: DeliveryEstado
    public var resumo: String
    public var evidencias: [DeliveryEvidence]
    public var submetidaPor: Author
    public var reviewedBy: Author?
    public var criadaEm: Date
    public var atualizadaEm: Date
    public var aceitaEm: Date?
    public var historico: [DeliveryHistoryEntry]

    enum CodingKeys: String, CodingKey {
        case id, estado, resumo, evidencias, historico
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
        case nodeID = "node_id"
        case missionID = "mission_id"
        case workstreamID = "workstream_id"
        case submetidaPor = "submetida_por"
        case reviewedBy = "reviewed_by"
        case criadaEm = "criada_em"
        case atualizadaEm = "atualizada_em"
        case aceitaEm = "aceita_em"
        // legado
        case revisao
        case aceitaPor = "aceita_por"
    }

    public init(submission: DeliverySubmission, author: Author, at: Date) {
        id = submission.id
        workspaceID = submission.workspaceID
        sessionID = submission.sessionID
        nodeID = submission.nodeID
        missionID = submission.missionID
        workstreamID = submission.workstreamID
        // submit cria proposed se veio completed/accepted legado; draft permanece draft
        switch submission.estado {
        case .draft: estado = .draft
        case .accepted: estado = .proposed
        default: estado = submission.estado == .proposed ? .proposed : submission.estado
        }
        if estado == .accepted { estado = .proposed }
        resumo = submission.resumo.trimmingCharacters(in: .whitespacesAndNewlines)
        evidencias = submission.evidencias
        submetidaPor = author
        reviewedBy = nil
        criadaEm = at
        atualizadaEm = at
        aceitaEm = nil
        historico = [DeliveryHistoryEntry(acao: .submitted, autor: author, em: at, estado: estado)]
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ULID.self, forKey: .id)
        workspaceID = try c.decode(ULID.self, forKey: .workspaceID)
        sessionID = try c.decode(ULID.self, forKey: .sessionID)
        nodeID = try c.decode(ULID.self, forKey: .nodeID)
        missionID = try c.decodeIfPresent(ULID.self, forKey: .missionID)
        workstreamID = try c.decodeIfPresent(ULID.self, forKey: .workstreamID)
        if let raw = try c.decodeIfPresent(String.self, forKey: .estado),
           let decoded = DeliveryEstado.decodeLegacy(raw) {
            estado = decoded
        } else {
            estado = try c.decodeIfPresent(DeliveryEstado.self, forKey: .estado) ?? .proposed
        }
        // legado: revisao aceita + completed → accepted
        if let revisao = try c.decodeIfPresent(String.self, forKey: .revisao), revisao == "aceita" {
            estado = .accepted
        }
        resumo = try c.decode(String.self, forKey: .resumo)
        evidencias = try c.decodeIfPresent([DeliveryEvidence].self, forKey: .evidencias) ?? []
        submetidaPor = try c.decode(Author.self, forKey: .submetidaPor)
        if let reviewed = try c.decodeIfPresent(Author.self, forKey: .reviewedBy) {
            reviewedBy = reviewed
        } else {
            reviewedBy = try c.decodeIfPresent(Author.self, forKey: .aceitaPor)
        }
        criadaEm = try c.decodeIfPresent(Date.self, forKey: .criadaEm) ?? Date()
        atualizadaEm = try c.decodeIfPresent(Date.self, forKey: .atualizadaEm) ?? Date()
        aceitaEm = try c.decodeIfPresent(Date.self, forKey: .aceitaEm)
        historico = try c.decodeIfPresent([DeliveryHistoryEntry].self, forKey: .historico) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workspaceID, forKey: .workspaceID)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(nodeID, forKey: .nodeID)
        try c.encodeIfPresent(missionID, forKey: .missionID)
        try c.encodeIfPresent(workstreamID, forKey: .workstreamID)
        try c.encode(estado, forKey: .estado)
        try c.encode(resumo, forKey: .resumo)
        try c.encode(evidencias, forKey: .evidencias)
        try c.encode(submetidaPor, forKey: .submetidaPor)
        try c.encodeIfPresent(reviewedBy, forKey: .reviewedBy)
        try c.encode(criadaEm, forKey: .criadaEm)
        try c.encode(atualizadaEm, forKey: .atualizadaEm)
        try c.encodeIfPresent(aceitaEm, forKey: .aceitaEm)
        try c.encode(historico, forKey: .historico)
    }

    public var aceita: Bool { estado == .accepted }

    public func matches(_ submission: DeliverySubmission, author: Author) -> Bool {
        let expectedEstado: DeliveryEstado = {
            switch submission.estado {
            case .draft: return .draft
            case .accepted: return .proposed
            default: return submission.estado == .proposed ? .proposed : submission.estado
            }
        }()
        return id == submission.id && workspaceID == submission.workspaceID && sessionID == submission.sessionID &&
            nodeID == submission.nodeID && estado == expectedEstado &&
            missionID == submission.missionID && workstreamID == submission.workstreamID &&
            resumo == submission.resumo.trimmingCharacters(in: .whitespacesAndNewlines) &&
            evidencias == submission.evidencias && submetidaPor == author
    }

    // §9.4
    public static func canTransition(from: DeliveryEstado, to: DeliveryEstado) -> Bool {
        if from == to { return true }
        switch (from, to) {
        case (.draft, .proposed):
            return true
        case (.proposed, .accepted), (.proposed, .partial), (.proposed, .blocked), (.proposed, .failed):
            return true
        case (.accepted, .reopened):
            return true
        case (.reopened, .proposed), (.reopened, .accepted), (.reopened, .partial), (.reopened, .blocked), (.reopened, .failed):
            return true
        case (.partial, .proposed), (.partial, .accepted), (.blocked, .proposed), (.failed, .proposed):
            return true
        default:
            return false
        }
    }
}

public enum DeliveryValidationError: Error, Equatable, Sendable, LocalizedError {
    case resumoObrigatorio
    case resumoLongo(maximo: Int)
    case evidenciasObrigatorias
    case evidenciaDuplicada(ULID)
    case evidenciaInvalida(id: ULID, reason: String)

    public var errorDescription: String? {
        switch self {
        case .resumoObrigatorio: return "resumo da entrega é obrigatório"
        case .resumoLongo(let maximo): return "resumo excede \(maximo) caracteres"
        case .evidenciasObrigatorias: return "entrega proposed/accepted exige ao menos uma evidência"
        case .evidenciaDuplicada: return "id de evidência duplicado"
        case .evidenciaInvalida(_, let reason): return "evidência inválida: \(reason)"
        }
    }
}
