import Foundation
import ColmeiaKit

/// Erros de ciclo de vida que não são erros de validação do conteúdo da entrega.
public enum DeliveryStoreError: Error, Equatable, Sendable, LocalizedError {
    case deliveryNotFound(ULID)
    case idempotencyConflict(ULID)
    case humanReviewRequired
    case alreadyAccepted(ULID)
    case notAccepted(ULID)

    public var errorDescription: String? {
        switch self {
        case .deliveryNotFound(let id): return "entrega não encontrada: \(id.string)"
        case .idempotencyConflict(let id): return "delivery_id já foi usado com outro conteúdo: \(id.string)"
        case .humanReviewRequired: return "somente humano pode aceitar ou reabrir entrega"
        case .alreadyAccepted(let id): return "entrega já aceita: \(id.string)"
        case .notAccepted(let id): return "entrega não está aceita: \(id.string)"
        }
    }
}

/// Repositório local, isolado de protocolo/UI. O diretório é recebido pelo
/// chamador para que cada workspace/instalação possa decidir sua política de
/// localização. O único arquivo escrito é `deliveries.json`, sempre por rename
/// atômico; nenhuma evidência aciona shell ou é executada.
public final class DeliveryStore: @unchecked Sendable {
    private struct Snapshot: Codable {
        var schemaVersion: Int
        var deliveries: [Delivery]

        enum CodingKeys: String, CodingKey {
            case deliveries
            case schemaVersion = "schema_version"
        }
    }

    public let directory: URL
    public let fileURL: URL

    private let lock = NSLock()
    private var byID: [ULID: Delivery]

    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        fileURL = self.directory.appendingPathComponent("deliveries.json", isDirectory: false)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let snapshot = try AtomicJSON.read(Snapshot.self, from: fileURL)
            var loaded = [ULID: Delivery]()
            for delivery in snapshot.deliveries {
                guard loaded[delivery.id] == nil else {
                    throw DeliveryStoreError.idempotencyConflict(delivery.id)
                }
                loaded[delivery.id] = delivery
            }
            byID = loaded
        } else {
            byID = [:]
        }
    }

    /// Submeter é idempotente por `delivery.id`: mesma solicitação e autor
    /// devolvem o registro original; conteúdo diferente com o mesmo ID falha.
    @discardableResult
    public func submit(_ submission: DeliverySubmission, author: Author, at: Date = Date()) throws -> Delivery {
        try submission.validate()
        lock.lock()
        defer { lock.unlock() }
        if let existing = byID[submission.id] {
            guard existing.matches(submission, author: author) else {
                throw DeliveryStoreError.idempotencyConflict(submission.id)
            }
            return existing
        }
        let delivery = Delivery(submission: submission, author: author, at: at)
        try persist(replacing: delivery)
        return delivery
    }

    /// Aceitação humana é uma transição explícita. A chamada repetida pelo mesmo
    /// humano é segura e não recria histórico; outro revisor recebe erro claro.
    @discardableResult
    public func accept(_ id: ULID, by author: Author, at: Date = Date()) throws -> Delivery {
        try requireHuman(author)
        lock.lock()
        defer { lock.unlock() }
        guard var delivery = byID[id] else { throw DeliveryStoreError.deliveryNotFound(id) }
        if delivery.aceita {
            if delivery.reviewedBy == author { return delivery }
            throw DeliveryStoreError.alreadyAccepted(id)
        }
        // §5.7 / §9.4 — accepted exige evidência válida
        if delivery.evidencias.isEmpty {
            throw DeliveryValidationError.evidenciasObrigatorias
        }
        delivery.estado = .accepted
        delivery.reviewedBy = author
        delivery.aceitaEm = at
        delivery.atualizadaEm = at
        delivery.historico.append(DeliveryHistoryEntry(acao: .accepted, autor: author, em: at, estado: .accepted))
        try persist(replacing: delivery)
        return delivery
    }

    /// Reabrir remove apenas a aceitação corrente; o evento de aceite anterior
    /// permanece no histórico para auditoria.
    @discardableResult
    public func reopen(_ id: ULID, by author: Author, at: Date = Date()) throws -> Delivery {
        try requireHuman(author)
        lock.lock()
        defer { lock.unlock() }
        guard var delivery = byID[id] else { throw DeliveryStoreError.deliveryNotFound(id) }
        guard delivery.aceita else { throw DeliveryStoreError.notAccepted(id) }
        delivery.estado = .reopened
        delivery.reviewedBy = nil
        delivery.aceitaEm = nil
        delivery.atualizadaEm = at
        delivery.historico.append(DeliveryHistoryEntry(acao: .reopened, autor: author, em: at, estado: .reopened))
        try persist(replacing: delivery)
        return delivery
    }

    public func delivery(id: ULID) -> Delivery? {
        lock.lock()
        defer { lock.unlock() }
        return byID[id]
    }

    public func deliveries(workspaceID: ULID? = nil) -> [Delivery] {
        lock.lock()
        defer { lock.unlock() }
        return byID.values
            .filter { delivery in
                guard let workspaceID else { return true }
                return delivery.workspaceID == workspaceID
            }
            .sorted { lhs, rhs in
                lhs.criadaEm == rhs.criadaEm ? lhs.id < rhs.id : lhs.criadaEm < rhs.criadaEm
            }
    }

    private func persist(replacing delivery: Delivery) throws {
        var next = byID
        next[delivery.id] = delivery
        let snapshot = Snapshot(
            schemaVersion: 1,
            deliveries: next.values.sorted { lhs, rhs in lhs.id < rhs.id }
        )
        try AtomicJSON.write(snapshot, to: fileURL)
        byID = next
    }

    private func requireHuman(_ author: Author) throws {
        guard case .humano = author else { throw DeliveryStoreError.humanReviewRequired }
    }
}
