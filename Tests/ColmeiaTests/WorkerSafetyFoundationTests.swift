import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

private final class WorkerSafetyClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private func workerSafetySession(_ state: SessionEstado = .rodando) -> Session {
    Session(
        id: ULID.generate(), workspaceID: ULID.generate(), nodeID: ULID.generate(), adapter: "shell",
        estado: state, journal: "sessions/evidence.jsonl", iniciadaEm: Date(timeIntervalSince1970: 1),
        encerradaEm: state.isViva ? nil : Date(timeIntervalSince1970: 2), cols: 120, rows: 32)
}

@Suite("Fundação segura — watchdog limitado e arquivo de workers")
struct WorkerSafetyFoundationTests {
    @Test func watchdogLimitaNudgesEscalaUmaVezEResetaComProgresso() {
        let clock = WorkerSafetyClock(Date(timeIntervalSince1970: 1_000))
        let service = WorkerWatchdogService(clock: { clock.now })
        let session = workerSafetySession()
        var activity = WorkerActivitySnapshot(
            sessionID: session.id, workspaceID: session.workspaceID, state: .rodando,
            lastActivityAt: clock.now.addingTimeInterval(-100))
        let config = WorkerWatchdogConfiguration(workspacePolicy: WorkerWatchdogPolicy(
            enabled: true, staleAfter: 60, nudgeInterval: 20, maxNudgesPerEpisode: 99))

        #expect(service.evaluate(activity, configuration: config) == .nudge(sessionID: session.id, episode: 1))
        clock.advance(19)
        #expect(service.evaluate(activity, configuration: config) == .none)
        clock.advance(1)
        #expect(service.evaluate(activity, configuration: config) == .nudge(sessionID: session.id, episode: 1))
        clock.advance(20)
        #expect(service.evaluate(activity, configuration: config) == .escalate(sessionID: session.id, episode: 1))
        clock.advance(60)
        #expect(service.evaluate(activity, configuration: config) == .none)

        // Novo output/progresso cria episódio 2, sem respawn ou ação implícita.
        activity.lastActivityAt = clock.now
        #expect(service.evaluate(activity, configuration: config) == .none)
        clock.advance(60)
        #expect(service.evaluate(activity, configuration: config) == .nudge(sessionID: session.id, episode: 2))
    }

    @Test func watchdogExcluiEsperaHumanaAprovacaoEDesligamentoPorSessao() {
        let clock = WorkerSafetyClock(Date(timeIntervalSince1970: 2_000))
        let service = WorkerWatchdogService(clock: { clock.now })
        let session = workerSafetySession()
        let policy = WorkerWatchdogPolicy(enabled: true, staleAfter: 1, nudgeInterval: 1)
        for state in [SessionEstado.esperandoHumano, .aprovacaoPendente, .encerrada, .morta] {
            let snapshot = WorkerActivitySnapshot(
                sessionID: session.id, workspaceID: session.workspaceID, state: state,
                lastActivityAt: clock.now.addingTimeInterval(-100))
            #expect(service.evaluate(snapshot, configuration: WorkerWatchdogConfiguration(workspacePolicy: policy)) == .none)
        }
        let running = WorkerActivitySnapshot(
            sessionID: session.id, workspaceID: session.workspaceID, state: .rodando,
            lastActivityAt: clock.now.addingTimeInterval(-100))
        let disabledForSession = WorkerWatchdogConfiguration(
            workspacePolicy: policy, sessionOverrides: [session.id: WorkerWatchdogPolicy(enabled: false)])
        #expect(service.evaluate(running, configuration: disabledForSession) == .none)
    }

    @Test func arquivoNuncaEAumentaEncerrarOuExcluirEPreservaEvidenciaNoReplay() {
        let clock = WorkerSafetyClock(Date(timeIntervalSince1970: 3_000))
        let service = WorkerArchiveService(clock: { clock.now })
        let closed = workerSafetySession(.encerrada)
        let evidence = WorkerArchiveEvidence(
            journal: closed.journal, deliveryIDs: [ULID.generate()], messageIDs: [ULID.generate()],
            approvalIDs: [ULID.generate()], relatedNodeIDs: [closed.nodeID])

        #expect(service.decide(
            action: .terminate, session: closed, evidence: evidence, deliveryAccepted: true) == .terminateOnly)
        #expect(service.decide(
            action: .delete, session: closed, evidence: evidence, deliveryAccepted: true,
            initiator: .human, policy: WorkerArchivePolicy(automaticArchivingEnabled: true)) == .refused(.deletionNotImplemented))
        #expect(service.decide(
            action: .archive, session: closed, evidence: evidence, deliveryAccepted: true) == .refused(.automaticArchiveDisabled))

        let archived = service.decide(
            action: .archive, session: closed, evidence: evidence, deliveryAccepted: true,
            policy: WorkerArchivePolicy(automaticArchivingEnabled: true))
        guard case .archived(let tombstone) = archived else {
            Issue.record("sessão encerrada e delivery aceito deveria gerar tombstone")
            return
        }
        #expect(tombstone.session == closed)
        #expect(tombstone.evidence == evidence)
        #expect(tombstone.restoredAt == nil)
        clock.advance(1)
        #expect(service.restoreForReplay(tombstoneID: tombstone.id) == .restoreReplay(
            session: closed, journal: closed.journal))
        #expect(service.tombstone(tombstone.id)?.evidence == evidence)
        #expect(service.tombstone(tombstone.id)?.restoredAt == clock.now)
    }

    @Test func arquivoRecusaSessaoVivaEAceitaConfirmacaoHumanaExplicita() {
        let service = WorkerArchiveService(clock: { Date(timeIntervalSince1970: 4_000) })
        let evidence = WorkerArchiveEvidence(journal: "sessions/a.jsonl")
        #expect(service.decide(
            action: .archive, session: workerSafetySession(.rodando), evidence: evidence,
            deliveryAccepted: true, initiator: .human, policy: WorkerArchivePolicy(automaticArchivingEnabled: true))
            == .refused(.sessionStillLive))
        let humanArchive = service.decide(
            action: .archive, session: workerSafetySession(.morta), evidence: evidence,
            deliveryAccepted: false, humanConfirmed: true, initiator: .human)
        guard case .archived(let tombstone) = humanArchive else {
            Issue.record("confirmação humana explícita deve permitir sessão não-viva")
            return
        }
        #expect(tombstone.humanConfirmed && !tombstone.deliveryAccepted)
    }
}
