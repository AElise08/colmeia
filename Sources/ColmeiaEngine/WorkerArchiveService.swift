import Foundation
import ColmeiaKit

/// Política aditiva: desligada por padrão para impedir autoarquivamento acidental.
public struct WorkerArchivePolicy: Codable, Equatable, Sendable {
    public var automaticArchivingEnabled: Bool

    public init(automaticArchivingEnabled: Bool = false) {
        self.automaticArchivingEnabled = automaticArchivingEnabled
    }
}

/// Catálogo em memória de tombstones. A futura integração poderá persistir estes
/// registros; esta fundação deliberadamente não move/apaga arquivos nem metadados.
public final class WorkerArchiveService: @unchecked Sendable {
    private let clock: @Sendable () -> Date
    private var records: [ULID: WorkerArchiveTombstone] = [:]

    public init(
        records: [WorkerArchiveTombstone] = [],
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clock = clock
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    public func decide(
        action: WorkerLifecycleAction,
        session: Session,
        evidence: WorkerArchiveEvidence,
        deliveryAccepted: Bool,
        humanConfirmed: Bool = false,
        initiator: WorkerArchiveInitiator = .automatic,
        policy: WorkerArchivePolicy = WorkerArchivePolicy()
    ) -> WorkerArchiveDecision {
        switch action {
        case .terminate:
            // Encerrar é uma intenção distinta; não cria tombstone nem arquiva.
            return .terminateOnly
        case .delete:
            // Sem remoção de dados nesta fundação, mesmo com confirmação humana.
            return .refused(.deletionNotImplemented)
        case .archive:
            guard !session.estado.isViva else { return .refused(.sessionStillLive) }
            if initiator == .automatic && !policy.automaticArchivingEnabled {
                return .refused(.automaticArchiveDisabled)
            }
            guard deliveryAccepted || (initiator == .human && humanConfirmed) else {
                return .refused(.deliveryNotAccepted)
            }
            let tombstone = WorkerArchiveTombstone(
                session: session, evidence: evidence, archivedAt: clock(),
                deliveryAccepted: deliveryAccepted, humanConfirmed: humanConfirmed)
            records[tombstone.id] = tombstone
            return .archived(tombstone)
        }
    }

    /// Restaura somente a referência de replay; não recria processo/sessão viva.
    public func restoreForReplay(tombstoneID: ULID) -> WorkerArchiveDecision? {
        guard var tombstone = records[tombstoneID] else { return nil }
        tombstone.restoredAt = clock()
        records[tombstoneID] = tombstone
        return .restoreReplay(session: tombstone.session, journal: tombstone.evidence.journal)
    }

    public func tombstone(_ id: ULID) -> WorkerArchiveTombstone? { records[id] }

    public func tombstones() -> [WorkerArchiveTombstone] {
        records.values.sorted { $0.archivedAt > $1.archivedAt }
    }
}
