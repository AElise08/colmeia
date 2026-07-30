import Foundation
import ColmeiaKit

/// Máquina de estados puramente observacional. Quem integrar este serviço decide
/// como mostrar um nudge/escalonamento; este tipo nunca toca PTY, sessão ou storage.
public final class WorkerWatchdogService: @unchecked Sendable {
    private struct Episode {
        var number: Int
        var lastActivityAt: Date
        var nudges: Int
        var lastNudgeAt: Date?
        var escalated: Bool
    }

    private let clock: @Sendable () -> Date
    private var episodes: [ULID: Episode] = [:]

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Avalia uma sessão no instante do relógio injetado. Uma atividade mais nova
    /// inaugura episódio novo e zera o contador anti-storm.
    public func evaluate(
        _ snapshot: WorkerActivitySnapshot, configuration: WorkerWatchdogConfiguration
    ) -> WorkerWatchdogAction {
        let policy = configuration.policy(for: snapshot.sessionID)
        guard policy.enabled, snapshot.isWatchable else {
            episodes.removeValue(forKey: snapshot.sessionID)
            return .none
        }
        let now = clock()
        var episode = episodes[snapshot.sessionID] ?? Episode(
            number: 1, lastActivityAt: snapshot.lastActivityAt, nudges: 0, lastNudgeAt: nil, escalated: false)
        if snapshot.lastActivityAt > episode.lastActivityAt {
            episode = Episode(
                number: episode.number + 1, lastActivityAt: snapshot.lastActivityAt,
                nudges: 0, lastNudgeAt: nil, escalated: false)
        }
        guard now.timeIntervalSince(snapshot.lastActivityAt) >= policy.staleAfter else {
            episodes[snapshot.sessionID] = episode
            return .none
        }
        if episode.nudges < policy.maxNudgesPerEpisode {
            if let lastNudgeAt = episode.lastNudgeAt,
               now.timeIntervalSince(lastNudgeAt) < policy.nudgeInterval {
                episodes[snapshot.sessionID] = episode
                return .none
            }
            episode.nudges += 1
            episode.lastNudgeAt = now
            episodes[snapshot.sessionID] = episode
            return .nudge(sessionID: snapshot.sessionID, episode: episode.number)
        }
        guard !episode.escalated else {
            episodes[snapshot.sessionID] = episode
            return .none
        }
        episode.escalated = true
        episodes[snapshot.sessionID] = episode
        return .escalate(sessionID: snapshot.sessionID, episode: episode.number)
    }

    /// Limpeza explícita quando a sessão deixa o runtime; não dispara ação alguma.
    public func forget(sessionID: ULID) { episodes.removeValue(forKey: sessionID) }
}
