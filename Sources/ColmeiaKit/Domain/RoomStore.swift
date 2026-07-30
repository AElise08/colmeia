import Foundation

/// Serviço de sala colaborativa do Hub virtual local. A autoridade fica no
/// engine; `persist`/`load` permitem que o Hub sobreviva ao restart do processo.
public final class RoomStore: @unchecked Sendable {
    public let roomID: ULID

    private let lock = NSLock()
    private var room: Room
    private var members: [String: Member] = [:]
    private var agentSessions: [ULID: AgentSession] = [:]
    private var grants: [ULID: CapabilityGrant] = [:]
    private var leases: [ULID: LeaseRecord] = [:]
    private var events: [CollaborativeSessionEvent] = []
    private var eventCount: UInt64 = 0
    private var eventIDs: Set<ULID> = []
    private var presences: [String: Presence] = [:]
    private var inviteTokens: [String: InviteToken] = [:]

    /// Lease de condução expira em 5 min (300 s) se ausente.
    public static let leaseTTL: TimeInterval = 300
    /// Presença é descartada após TTL de 15 s sem heartbeat (§6.4).
    public static let presenceTTL: TimeInterval = 15
    /// Convites expiram em 24 h por padrão (§7.1).
    public static let inviteTTL: TimeInterval = 86400

    // MARK: - Init

    public init(room: Room) {
        self.roomID = room.id
        self.room = room
    }

    private init(state: PersistedState) {
        self.roomID = state.room.id
        self.room = state.room
        self.members = Dictionary(uniqueKeysWithValues: state.members.map { ($0.id, $0) })
        self.agentSessions = Dictionary(uniqueKeysWithValues: state.agentSessions.map { ($0.id, $0) })
        self.grants = Dictionary(uniqueKeysWithValues: state.grants.map { ($0.id, $0) })
        self.events = state.events
        self.eventCount = state.roomSeq
        self.eventIDs = Set(state.events.map(\.id))
        self.inviteTokens = Dictionary(uniqueKeysWithValues: (state.inviteTokens).map { ($0.token, $0) })
    }

    /// Snapshot atômico do estado durável do Hub local. Leases e presença são
    /// efêmeros e intencionalmente não sobrevivem a um restart.
    public func persist(to paths: ColmeiaPaths) throws {
        lock.lock()
        let state = PersistedState(
            room: room,
            members: Array(members.values),
            agentSessions: Array(agentSessions.values),
            grants: Array(grants.values),
            events: events,
            roomSeq: eventCount,
            inviteTokens: Array(inviteTokens.values))
        lock.unlock()
        try FileManager.default.createDirectory(at: paths.roomDir(roomID), withIntermediateDirectories: true)
        try AtomicJSON.write(state, to: paths.roomSnapshotFile(roomID))
    }

    public static func load(from paths: ColmeiaPaths, roomID: ULID) throws -> RoomStore {
        let state = try AtomicJSON.read(PersistedState.self, from: paths.roomSnapshotFile(roomID))
        guard state.room.id == roomID else {
            throw RoomStoreError.roomNotFound(roomID)
        }
        return RoomStore(state: state)
    }

    // MARK: - Room

    public func getRoom() -> Room {
        lock.lock(); defer { lock.unlock() }
        return room
    }

    public func updateRoom(name: String?, policy: RoomPolicy?) -> Room {
        lock.lock(); defer { lock.unlock() }
        if let name { room.name = name }
        if let policy { room.policy = policy }
        room.updatedAt = Date()
        return room
    }

    public func archiveRoom() -> Room {
        lock.lock(); defer { lock.unlock() }
        room.state = .archived
        room.updatedAt = Date()
        return room
    }

    // MARK: - Members

    public func getMembers(status: MemberStatus? = nil) -> [Member] {
        lock.lock(); defer { lock.unlock() }
        return members.values.filter { status == nil || $0.status == status }
            .sorted { $0.joinedAt < $1.joinedAt }
    }

    public func getMember(id: String) -> Member? {
        lock.lock(); defer { lock.unlock() }
        return members[id]
    }

    @discardableResult
    public func addMember(id: String, displayName: String, roles: Set<MemberRole>, now: Date = Date()) throws -> Member {
        lock.lock(); defer { lock.unlock() }
        guard members[id] == nil || members[id]?.status == .left else {
            throw RoomStoreError.memberAlreadyExists(id)
        }
        let member = Member(id: id, displayName: displayName, roles: roles, status: .active, joinedAt: now)
        members[id] = member
        return member
    }

    @discardableResult
    public func updateMember(id: String, displayName: String?, roles: Set<MemberRole>?) throws -> Member {
        lock.lock(); defer { lock.unlock() }
        guard var member = members[id], member.status == .active else {
            throw RoomStoreError.memberNotFound(id)
        }
        if let displayName { member.displayName = displayName }
        if let roles { member.roles = roles }
        members[id] = member
        return member
    }

    @discardableResult
    public func removeMember(id: String) throws -> Member {
        lock.lock(); defer { lock.unlock() }
        guard var member = members[id], member.status == .active else {
            throw RoomStoreError.memberNotFound(id)
        }
        member.status = .left
        members[id] = member
        return member
    }

    public func revokeMember(id: String) throws -> Member {
        lock.lock(); defer { lock.unlock() }
        guard var member = members[id] else { throw RoomStoreError.memberNotFound(id) }
        member.status = .revoked
        members[id] = member
        return member
    }

    // MARK: - Invites (§7.1)

    /// Retorna convite sem consumir — para validação no hello.
    public func getInvite(token: String) -> InviteToken? {
        lock.lock(); defer { lock.unlock() }
        return inviteTokens[token]
    }

    /// Cria convite de uso único com TTL configurável.
    public func createInvite(
        displayName: String, roles: Set<MemberRole>,
        ttlSeconds: Int? = nil, now: Date = Date()
    ) -> InviteToken {
        lock.lock(); defer { lock.unlock() }
        let token = ULID.generate().string
        let ttl = TimeInterval(ttlSeconds ?? 0) > 0
            ? TimeInterval(ttlSeconds!)
            : Self.inviteTTL
        let invite = InviteToken(
            token: token, roomID: roomID, displayName: displayName,
            roles: roles, createdAt: now,
            expiresAt: now.addingTimeInterval(ttl))
        inviteTokens[token] = invite
        return invite
    }

    /// Lista todos os convites da sala (ativos, usados e expirados).
    public func listInvites() -> [InviteToken] {
        lock.lock(); defer { lock.unlock() }
        return Array(inviteTokens.values)
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Revoga um convite — marca como usado para impedir reuso.
    public func revokeInvite(token: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard var invite = inviteTokens[token] else {
            throw RoomStoreError.inviteInvalid
        }
        invite.used = true
        inviteTokens[token] = invite
    }

    /// Resgata convite válido para entrada na sala. Uso único; expirado ou já
    /// usado lança erro.
    public func redeemInvite(token: String, memberID: String, now: Date = Date()) throws -> InviteToken {
        lock.lock(); defer { lock.unlock() }
        guard var invite = inviteTokens[token] else {
            throw RoomStoreError.inviteInvalid
        }
        guard invite.isValid else {
            if invite.used { throw RoomStoreError.inviteInvalid }
            throw RoomStoreError.inviteExpired
        }
        invite.used = true
        invite.usedByMemberID = memberID
        inviteTokens[token] = invite
        return invite
    }

    // MARK: - Agent Sessions

    public func getAgentSessions(state: AgentSessionState? = nil) -> [AgentSession] {
        lock.lock(); defer { lock.unlock() }
        return agentSessions.values.filter { state == nil || $0.state == state }
            .sorted { ($0.lastActivityAt ?? Date.distantPast) < ($1.lastActivityAt ?? Date.distantPast) }
    }

    public func getAgentSession(id: ULID) -> AgentSession? {
        lock.lock(); defer { lock.unlock() }
        return agentSessions[id]
    }

    @discardableResult
    public func createAgentSession(_ params: AgentSessionCreateParams, now: Date = Date()) -> AgentSession {
        lock.lock(); defer { lock.unlock() }
        let session = AgentSession(
            id: ULID.generate(), roomID: roomID, workspaceID: params.workspaceID,
            nodeID: params.nodeID, objective: params.objective,
            state: .draft, lastActivityAt: now)
        agentSessions[session.id] = session
        return session
    }

    @discardableResult
    public func updateAgentSession(
        id: ULID, objective: String?, state: AgentSessionState?,
        conductorID: String?, summary: String?, now: Date = Date()
    ) throws -> AgentSession {
        lock.lock(); defer { lock.unlock() }
        guard var session = agentSessions[id] else { throw RoomStoreError.agentSessionNotFound(id) }
        if session.state.isArchived && state != nil && state != .archived {
            throw RoomStoreError.agentSessionArchived(id)
        }
        if let objective { session.objective = objective }
        if let state { session.state = state }
        if let conductorID { session.conductorID = conductorID }
        if let summary { session.summary = summary }
        session.lastActivityAt = now
        agentSessions[id] = session
        return session
    }

    // MARK: - Events (§4.1.4, §6.2)

    /// Append-only com deduplicação por `eventID`. Se o ID já existe com payload
    /// idêntico, retorna o evento original (idempotente). Se o ID existe com
    /// payload diferente, lança `idempotencyConflict`.
    public func appendEvent(
        sessionID: ULID, kind: CollaborativeEventKind,
        payload: CollaborativeEventPayload, author: Author,
        eventID: ULID? = nil, now: Date = Date()
    ) throws -> (CollaborativeSessionEvent, UInt64, Bool) {
        lock.lock(); defer { lock.unlock() }
        let eid = eventID ?? ULID.generate()

        // Deduplicação (§6.2): mesmo ID → mesma resposta se idêntico
        if eventIDs.contains(eid) {
            guard let existing = events.first(where: { $0.id == eid }) else {
                throw RoomStoreError.idempotencyConflict
            }
            let sameAuthor = existing.author == author
            let sameKind = existing.kind == kind
            let samePayload = existing.payload == payload
            if sameAuthor && sameKind && samePayload {
                return (existing, eventCount, true)
            }
            throw RoomStoreError.idempotencyConflict
        }

        guard let session = agentSessions[sessionID] else {
            throw RoomStoreError.agentSessionNotFound(sessionID)
        }
        guard !session.state.isArchived else {
            throw RoomStoreError.agentSessionArchived(sessionID)
        }
        eventCount += 1
        var updatedSession = session
        updatedSession.lastActivityAt = now
        switch kind {
        case .stateChanged:
            if let newState = payload.newState { updatedSession.state = newState }
        case .conductorChanged:
            if let newID = payload.toMemberID { updatedSession.conductorID = newID }
        case .summaryUpdated:
            if let summary = payload.summary { updatedSession.summary = summary }
        default: break
        }
        agentSessions[sessionID] = updatedSession

        let event = CollaborativeSessionEvent(
            id: eid, roomID: roomID, sessionID: sessionID,
            author: author, kind: kind, payload: payload,
            createdAt: now, logicalClock: eventCount)
        events.append(event)
        eventIDs.insert(eid)
        return (event, eventCount, false)
    }

    public func getEvents(sinceSeq: UInt64? = nil) -> [CollaborativeSessionEvent] {
        lock.lock(); defer { lock.unlock() }
        if let since = sinceSeq { return events.filter { $0.logicalClock > since } }
        return events
    }

    /// Delta incremental: eventos após `sinceSeq` + sessões de agente atualizadas (§6.2).
    public func buildDelta(sinceRoomSeq: UInt64) -> RoomDeltaResult {
        lock.lock(); defer { lock.unlock() }
        let deltaEvents = events.filter { $0.logicalClock > sinceRoomSeq }
        return RoomDeltaResult(
            events: deltaEvents,
            agentSessions: Array(agentSessions.values)
                .sorted { ($0.lastActivityAt ?? Date.distantPast) < ($1.lastActivityAt ?? Date.distantPast) },
            roomSeq: eventCount,
            roomUpdatedAt: room.updatedAt)
    }

    /// Sequência atual da sala (número de eventos).
    public func currentSeq() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return eventCount
    }

    public func snapshot() -> RoomSnapshotResult {
        lock.lock(); defer { lock.unlock() }
        return RoomSnapshotResult(
            room: room,
            members: Array(members.values).sorted { $0.joinedAt < $1.joinedAt },
            agentSessions: Array(agentSessions.values).sorted { ($0.lastActivityAt ?? Date.distantPast) < ($1.lastActivityAt ?? Date.distantPast) },
            events: events,
            roomSeq: eventCount)
    }

    // MARK: - State Machine (§4.2)

    /// Transições válidas entre estados. Rejeita transições inválidas.
    public func transitionSession(id: ULID, to newState: AgentSessionState, now: Date = Date()) throws -> AgentSession {
        lock.lock(); defer { lock.unlock() }
        guard var session = agentSessions[id] else { throw RoomStoreError.agentSessionNotFound(id) }
        guard !session.state.isArchived else { throw RoomStoreError.agentSessionArchived(id) }
        guard isValidTransition(from: session.state, to: newState) else {
            throw RoomStoreError.invalidTransition(session.state, newState)
        }
        session.state = newState
        session.lastActivityAt = now
        if newState == .completed || newState == .failed {
            session.handoff = nil
        }
        agentSessions[id] = session
        return session
    }

    private func isValidTransition(from: AgentSessionState, to: AgentSessionState) -> Bool {
        if from == to { return true }
        let allowed: Set<AgentSessionState>
        switch from {
        case .draft:    allowed = [.ready]
        case .ready:    allowed = [.running, .draft]
        case .running:  allowed = [.waitingForDirection, .waitingForApproval, .paused, .completed, .failed, .handoffPending]
        case .waitingForDirection: allowed = [.running, .handoffPending]
        case .waitingForApproval:  allowed = [.running, .handoffPending, .failed]
        case .handoffPending: allowed = [.running, .completed, .failed, .draft]
        case .paused:    allowed = [.running, .completed, .failed]
        case .completed: allowed = [.archived]
        case .failed:    allowed = [.draft, .archived]
        case .archived:  return false
        }
        return allowed.contains(to)
    }

    // MARK: - Handoff (§5.2)

    public func requestHandoff(sessionID: ULID, fromMemberID: String, toMemberID: String, scope: HandoffScope, now: Date = Date()) throws -> AgentSession {
        lock.lock(); defer { lock.unlock() }
        guard var session = agentSessions[sessionID] else { throw RoomStoreError.agentSessionNotFound(sessionID) }
        guard !session.state.isArchived else { throw RoomStoreError.agentSessionArchived(sessionID) }
        guard session.handoff == nil else { throw RoomStoreError.handoffAlreadyPending }
        guard members[toMemberID]?.isActive == true else { throw RoomStoreError.memberNotFound(toMemberID) }

        session.handoff = AgentSessionHandoff(
            fromMemberID: fromMemberID, toMemberID: toMemberID, scope: scope, requestedAt: now)
        session.state = .handoffPending
        session.lastActivityAt = now
        agentSessions[sessionID] = session
        return session
    }

    public func acceptHandoff(sessionID: ULID, by memberID: String, now: Date = Date()) throws -> AgentSession {
        lock.lock(); defer { lock.unlock() }
        guard var session = agentSessions[sessionID] else { throw RoomStoreError.agentSessionNotFound(sessionID) }
        guard let handoff = session.handoff, session.state == .handoffPending else {
            throw RoomStoreError.handoffInvalid
        }
        guard handoff.toMemberID == memberID else {
            throw RoomStoreError.insufficientPermissions
        }
        session.handoff = nil
        session.state = .running
        session.lastActivityAt = now
        switch handoff.scope {
        case .conductor, .both:
            session.conductorID = memberID
        case .executor: break
        }
        if handoff.scope == .executor || handoff.scope == .both {
            session.executorID = memberID
        }
        agentSessions[sessionID] = session
        return session
    }

    public func rejectHandoff(sessionID: ULID, by memberID: String, now: Date = Date()) throws -> AgentSession {
        lock.lock(); defer { lock.unlock() }
        guard var session = agentSessions[sessionID] else { throw RoomStoreError.agentSessionNotFound(sessionID) }
        guard let handoff = session.handoff, session.state == .handoffPending else {
            throw RoomStoreError.handoffInvalid
        }
        guard handoff.toMemberID == memberID else {
            throw RoomStoreError.insufficientPermissions
        }
        session.handoff = nil
        session.state = .running
        session.lastActivityAt = now
        agentSessions[sessionID] = session
        return session
    }

    // MARK: - Conductor (§5.1)

    public func canSendDirection(to sessionID: ULID, memberID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let session = agentSessions[sessionID] else { return false }
        return session.conductorID == memberID
    }

    public func canPostMessage(to sessionID: ULID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let session = agentSessions[sessionID] else { return false }
        return !session.state.isArchived
    }

    // MARK: - Briefing (§9.2)

    /// Brief de entrada determinístico a partir de eventos e estado publicados.
    /// NÃO é transcrição de terminal nem síntese de raciocínio oculto.
    public func buildBriefing(for sessionID: ULID, newMemberName: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let session = agentSessions[sessionID] else { return nil }
        var lines: [String] = []
        let obj = session.objective ?? "(sem objetivo)"
        lines.append("## 1. Objetivo e estado atual")
        lines.append("**Objetivo:** \(obj)")
        lines.append("**Estado:** \(session.state.rawValue)")
        if let cond = session.conductorID, let member = members[cond] {
            lines.append("**Condutor:** \(member.displayName)")
        } else if session.conductorID != nil {
            lines.append("**Condutor:** \(session.conductorID!) (externo)")
        } else {
            lines.append("**Condutor:** não definido")
        }
        if let exec = session.executorID, let member = members[exec] {
            lines.append("**Executor:** \(member.displayName)")
        } else if session.executorID != nil {
            lines.append("**Executor:** \(session.executorID!) (externo)")
        } else {
            lines.append("**Executor:** não definido")
        }
        lines.append("")

        // 2. O que mudou desde a última atividade relevante
        let relevant = events.filter { $0.sessionID == sessionID }
        let recent = relevant.suffix(10)
        lines.append("## 2. Últimas mudanças (até 10 eventos)")
        if recent.isEmpty {
            lines.append("(nenhum evento registrado)")
        } else {
            for e in recent {
                let kind = e.kind.rawValue
                let authorName = members[e.author.rawValue]?.displayName ?? e.author.description
                let detail = e.payload.texto
                    ?? e.payload.direction
                    ?? e.payload.decision
                    ?? e.payload.summary
                    ?? e.payload.newState?.rawValue
                    ?? ""
                let time = e.createdAt.formatted(date: .omitted, time: .shortened)
                lines.append("- [\(time)] **\(kind)** por \(authorName): \(detail)")
            }
        }
        lines.append("")

        // 3. Quem conduz e quem executa
        lines.append("## 3. Responsabilidades atuais")
        if session.conductorID != nil {
            lines.append("A direção TAMBÉM pertence ao condutor. Mensagens de outros membros entram como proposta.")
        } else {
            lines.append("Não há condutor. Qualquer membro pode propor direção, mas ela não é aplicada automaticamente.")
        }
        if session.executorID != nil {
            lines.append("A execução está alocada. Handoff é necessário para trocar o executor.")
        } else {
            lines.append("Não há executor alocado. A sessão aguarda um Worker para executar.")
        }
        lines.append("")

        // 4. Qual decisão, aprovação ou ação vem a seguir
        lines.append("## 4. Próxima ação")
        switch session.state {
        case .draft:
            lines.append("A sessão ainda está em rascunho. É necessário definir executor e iniciar.")
        case .ready:
            lines.append("A sessão está pronta para execução. Aguardando início do Worker.")
        case .running:
            lines.append("Trabalho em curso. Acompanhe a thread ou proponha direção se necessário.")
        case .waitingForDirection:
            lines.append("O agente está aguardando direção do condutor. Se for você, responda na thread.")
        case .waitingForApproval:
            lines.append("Há uma aprovação pendente. Revise a proposta e aprove ou rejeite.")
        case .handoffPending:
            if let h = session.handoff {
                let from = members[h.fromMemberID]?.displayName ?? h.fromMemberID
                let to = members[h.toMemberID]?.displayName ?? h.toMemberID
                lines.append("Handoff pendente de \(from) para \(to) (escopo: \(h.scope.rawValue)). O destinatário precisa aceitar.")
            }
        case .paused:
            lines.append("Sessão pausada. Retome ou transfira a condução para continuar.")
        case .completed:
            lines.append("Sessão concluída. A entrega ou resultado já foi publicado.")
        case .failed:
            lines.append("A execução falhou. Verifique o motivo e decida se reabre ou arquiva.")
        case .archived:
            lines.append("Sessão arquivada. Somente leitura; reabrir cria nova sessão.")
        }
        lines.append("")

        // 5. Onde a pessoa pode ajudar sem assumir controle indevidamente
        lines.append("## 5. Como ajudar")
        lines.append("- Comente na thread com ideias, perguntas ou sugestões.")
        if session.conductorID != nil {
            lines.append("- Use o composer \"Direcionar\" para propor uma direção — ela será revisada pelo condutor.")
        }
        if session.state == .handoffPending, let h = session.handoff, h.toMemberID != newMemberName {
            lines.append("- Você pode pedir handoff se precisar assumir a condução ou execução.")
        }
        if session.state == .waitingForApproval {
            lines.append("- Resolva a aprovação pendente se tiver papel de reviewer na sala.")
        }
        lines.append("- O terminal do executor e suas credenciais permanecem privados; você só vê o que foi publicado.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Grants

    public func issueGrant(
        subjectID: String, resource: String, actions: Set<CapabilityAction>,
        issuedBy: Author, expiresAt: Date?, contextHash: String?, now: Date = Date()
    ) -> CapabilityGrant {
        lock.lock(); defer { lock.unlock() }
        let grant = CapabilityGrant(
            id: ULID.generate(), roomID: roomID, subjectID: subjectID,
            resource: resource, actions: actions, issuedBy: issuedBy,
            expiresAt: expiresAt ?? now.addingTimeInterval(3600), contextHash: contextHash)
        grants[grant.id] = grant
        return grant
    }

    public func revokeGrant(id: ULID) throws -> CapabilityGrant {
        lock.lock(); defer { lock.unlock() }
        guard var grant = grants[id] else { throw RoomStoreError.grantNotFound(id) }
        guard grant.isActive else { throw RoomStoreError.grantAlreadyRevoked(id) }
        grant.revokedAt = Date()
        grants[id] = grant
        return grant
    }

    public func getGrants(subjectID: String? = nil, activeOnly: Bool = false) -> [CapabilityGrant] {
        lock.lock(); defer { lock.unlock() }
        var result = Array(grants.values)
        if let subjectID { result = result.filter { $0.subjectID == subjectID } }
        if activeOnly { result = result.filter { $0.isActive } }
        return result.sorted { $0.expiresAt < $1.expiresAt }
    }

    // MARK: - Leases

    public func acquireLease(sessionID: ULID, scope: HandoffScope, memberID: String, now: Date = Date()) -> LeaseResult {
        lock.lock(); defer { lock.unlock() }
        let lease = LeaseResult(leaseID: ULID.generate(), sessionID: sessionID,
                               scope: scope, expiresAt: now.addingTimeInterval(Self.leaseTTL))
        leases[lease.leaseID] = LeaseRecord(lease: lease, memberID: memberID, acquiredAt: now)
        return lease
    }

    public func heartbeatLease(leaseID: ULID, now: Date = Date()) throws -> LeaseResult {
        lock.lock(); defer { lock.unlock() }
        guard var record = leases[leaseID] else { throw RoomStoreError.leaseExpired }
        guard record.lease.expiresAt > now else { leases.removeValue(forKey: leaseID); throw RoomStoreError.leaseExpired }
        record.lease = LeaseResult(leaseID: record.lease.leaseID, sessionID: record.lease.sessionID,
                                    scope: record.lease.scope, expiresAt: now.addingTimeInterval(Self.leaseTTL))
        record.lastHeartbeat = now
        record.heartbeatCount += 1
        leases[leaseID] = record
        return record.lease
    }

    public func releaseLease(leaseID: ULID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return leases.removeValue(forKey: leaseID) != nil
    }

    @discardableResult
    public func expireLeases(now: Date = Date()) -> [ULID] {
        lock.lock(); defer { lock.unlock() }
        let expired = leases.filter { $0.value.lease.expiresAt <= now }.map { $0.key }
        for id in expired { leases.removeValue(forKey: id) }
        return expired
    }

    // MARK: - Presence (§4.1.6, efêmero)

    public func updatePresence(
        memberID: String, connected: Bool = true,
        viewport: Viewport?, cursor: Ponto? = nil, selectedNodeID: ULID?,
        viewingSessionID: ULID?, now: Date = Date()
    ) -> Presence {
        lock.lock(); defer { lock.unlock() }
        var presence = presences[memberID] ?? Presence(
            roomID: roomID, memberID: memberID,
            connected: true, lastSeen: now)
        presence.connected = connected
        presence.viewport = viewport
        presence.cursor = cursor
        presence.selectedNodeID = selectedNodeID
        presence.viewingSessionID = viewingSessionID
        presence.lastSeen = now
        presences[memberID] = presence
        return presence
    }

    public func getPresences(activeOnly: Bool = false, now: Date = Date()) -> [Presence] {
        lock.lock(); defer { lock.unlock() }
        if activeOnly {
            return presences.values.filter { $0.lastSeen > now.addingTimeInterval(-Self.presenceTTL) }
                .sorted { ($0.lastSeen) < ($1.lastSeen) }
        }
        return presences.values.sorted { ($0.lastSeen) < ($1.lastSeen) }
    }

    @discardableResult
    public func expirePresence(now: Date = Date()) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let threshold = now.addingTimeInterval(-Self.presenceTTL)
        let expired = presences.filter { $0.value.lastSeen <= threshold }.map { $0.key }
        for id in expired { presences.removeValue(forKey: id) }
        return expired
    }
}

private struct PersistedState: Codable {
    var room: Room
    var members: [Member]
    var agentSessions: [AgentSession]
    var grants: [CapabilityGrant]
    var events: [CollaborativeSessionEvent]
    var roomSeq: UInt64
    var inviteTokens: [InviteToken]

    enum CodingKeys: String, CodingKey {
        case room, members, grants, events
        case agentSessions = "agent_sessions"
        case roomSeq = "room_seq"
        case inviteTokens = "invite_tokens"
    }
}

// MARK: - Internal types

private struct LeaseRecord {
    var lease: LeaseResult
    var memberID: String
    var acquiredAt: Date
    var lastHeartbeat: Date?
    var heartbeatCount: Int = 0
}

// MARK: - Errors

public enum RoomStoreError: Error, Equatable, Sendable, LocalizedError {
    case roomNotFound(ULID)
    case roomAlreadyExists(ULID)
    case memberNotFound(String)
    case memberAlreadyExists(String)
    case memberRevoked(String)
    case inviteInvalid
    case inviteExpired
    case agentSessionNotFound(ULID)
    case agentSessionArchived(ULID)
    case handoffInvalid
    case handoffAlreadyPending
    case conductorRequired
    case grantNotFound(ULID)
    case grantExpired(ULID)
    case grantAlreadyRevoked(ULID)
    case insufficientPermissions
    case idempotencyConflict
    case leaseInvalid
    case leaseExpired
    case invalidTransition(AgentSessionState, AgentSessionState)

    public var errorDescription: String? {
        switch self {
        case .roomNotFound(let id): return "sala não encontrada: \(id.string)"
        case .roomAlreadyExists(let id): return "sala já existe: \(id.string)"
        case .memberNotFound(let id): return "membro não encontrado: \(id)"
        case .memberAlreadyExists(let id): return "membro já existe: \(id)"
        case .memberRevoked(let id): return "membro revogado: \(id)"
        case .inviteInvalid: return "convite inválido"
        case .inviteExpired: return "convite expirado"
        case .agentSessionNotFound(let id): return "sessão de agente não encontrada: \(id.string)"
        case .agentSessionArchived(let id): return "sessão de agente arquivada: \(id.string)"
        case .handoffInvalid: return "handoff inválido"
        case .handoffAlreadyPending: return "handoff já pendente"
        case .conductorRequired: return "condutor obrigatório"
        case .grantNotFound(let id): return "grant não encontrado: \(id.string)"
        case .grantExpired(let id): return "grant expirado: \(id.string)"
        case .grantAlreadyRevoked(let id): return "grant já revogado: \(id.string)"
        case .insufficientPermissions: return "permissões insuficientes"
        case .idempotencyConflict: return "conflito de idempotência"
        case .leaseInvalid: return "lease inválido"
        case .leaseExpired: return "lease expirado"
        case .invalidTransition(let from, let to): return "transição inválida: \(from.rawValue) → \(to.rawValue)"
        }
    }
}
