import Foundation

/// Política local de observação. Ela nunca autoriza criar, matar, reiniciar ou
/// arquivar workers: os únicos resultados possíveis são aviso ou escalonamento.
public struct WorkerWatchdogPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var staleAfter: TimeInterval
    public var nudgeInterval: TimeInterval
    public var maxNudgesPerEpisode: Int

    public init(
        enabled: Bool = false,
        staleAfter: TimeInterval = 300,
        nudgeInterval: TimeInterval = 120,
        maxNudgesPerEpisode: Int = 2
    ) {
        self.enabled = enabled
        self.staleAfter = max(1, staleAfter)
        self.nudgeInterval = max(1, nudgeInterval)
        self.maxNudgesPerEpisode = min(2, max(0, maxNudgesPerEpisode))
    }
}

/// Configuração preparada para persistência por workspace, com exceções de sessão.
/// A integração com storage fica intencionalmente fora desta fundação.
public struct WorkerWatchdogConfiguration: Codable, Equatable, Sendable {
    public var workspacePolicy: WorkerWatchdogPolicy
    public var sessionOverrides: [ULID: WorkerWatchdogPolicy]

    public init(
        workspacePolicy: WorkerWatchdogPolicy = WorkerWatchdogPolicy(),
        sessionOverrides: [ULID: WorkerWatchdogPolicy] = [:]
    ) {
        self.workspacePolicy = workspacePolicy
        self.sessionOverrides = sessionOverrides
    }

    public func policy(for sessionID: ULID) -> WorkerWatchdogPolicy {
        sessionOverrides[sessionID] ?? workspacePolicy
    }
}

/// Snapshot mínimo fornecido pelo runtime. `lastActivityAt` é a única fonte de
/// stale; estados de espera humana/aprovação não são elegíveis para nudges.
public struct WorkerActivitySnapshot: Equatable, Sendable {
    public var sessionID: ULID
    public var workspaceID: ULID
    public var state: SessionEstado
    public var lastActivityAt: Date

    public init(sessionID: ULID, workspaceID: ULID, state: SessionEstado, lastActivityAt: Date) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.state = state
        self.lastActivityAt = lastActivityAt
    }

    public var isWatchable: Bool {
        state.isViva && state != .esperandoHumano && state != .aprovacaoPendente
    }
}

public enum WorkerWatchdogAction: Equatable, Sendable {
    case none
    case nudge(sessionID: ULID, episode: Int)
    case escalate(sessionID: ULID, episode: Int)
}
