import Foundation
import ColmeiaKit

@MainActor
final class CollaborationPresenceStore: ObservableObject {
    private static let activeRoomDefaultsKey = "colmeia.activeRoomID"
    private static let pendingDeepLinkKey = "colmeia.pendingDeepLink"

    @Published private(set) var activeRoomID: ULID?
    @Published private(set) var activeWorkspaceID: ULID?
    @Published private(set) var members: [String: Member] = [:]
    @Published private(set) var remotePresences: [String: PresenceChangedTopicPayload] = [:]
    @Published private(set) var lastJoinError: String?

    private let hub: HubConnection
    private let localMemberID = Author.humano(InstallationIdentity.current().string).rawValue
    private var observerID: UUID?
    private var pendingCursor: Ponto?
    private var pendingViewport: Viewport?
    private var pendingSelection: ULID?
    private var sendTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    var onOpenWorkspace: ((ULID) async -> Void)?
    var onFocusNode: ((ULID) -> Void)?

    init(hub: HubConnection) {
        self.hub = hub
        if let raw = UserDefaults.standard.string(forKey: Self.activeRoomDefaultsKey) {
            activeRoomID = ULID(raw)
        }
        observerID = hub.addEventObserver { [weak self] event in
            self?.handle(event)
        }
        hub.onConnected = { [weak self] in
            await self?.onHubConnected()
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.sendNow()
            }
        }
    }

    deinit {
        sendTask?.cancel()
        heartbeatTask?.cancel()
    }

    func activate(roomID: ULID, members: [Member], workspaceID: ULID? = nil) {
        activeRoomID = roomID
        UserDefaults.standard.set(roomID.string, forKey: Self.activeRoomDefaultsKey)
        if let workspaceID {
            activeWorkspaceID = workspaceID
        }
        self.members = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        remotePresences.removeAll()
        scheduleSend(immediate: true)
    }

    func updateMembers(_ members: [Member]) {
        self.members = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
    }

    func updateLocal(cursor: Ponto, viewport: Viewport, selectedNodeID: ULID?) {
        pendingCursor = cursor
        pendingViewport = viewport
        pendingSelection = selectedNodeID
        scheduleSend(immediate: false)
    }

    /// Seleção e viewport precisam viajar mesmo se o cursor ficou parado.
    func updateContext(viewport: Viewport, selectedNodeID: ULID?, immediate: Bool = true) {
        pendingViewport = viewport
        pendingSelection = selectedNodeID
        scheduleSend(immediate: immediate)
    }

    func viewers(for nodeID: ULID) -> [(memberID: String, name: String)] {
        remotePresences.values.compactMap { presence in
            guard presence.connected, presence.selectedNodeID == nodeID else { return nil }
            let name = presence.displayName
                ?? members[presence.memberID]?.displayName
                ?? presence.memberID
            return (presence.memberID, name)
        }
    }

    /// `colmeia://join/<room>/<invite>` or http join URL path.
    func handleDeepLink(_ url: URL) async {
        UserDefaults.standard.set(url.absoluteString, forKey: Self.pendingDeepLinkKey)
        guard hub.isConnected else { return }
        await consumePendingDeepLink()
    }

    func consumePendingDeepLink() async {
        guard let raw = UserDefaults.standard.string(forKey: Self.pendingDeepLinkKey),
              let url = URL(string: raw) else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        // colmeia://join/ROOM/TOKEN → host=join, path=/ROOM/TOKEN
        // http://host/join/ROOM/TOKEN → path=/join/ROOM/TOKEN
        let tokens: [String]
        if url.scheme == "colmeia", url.host == "join" {
            tokens = parts
        } else if let idx = parts.firstIndex(of: "join"), parts.count >= idx + 3 {
            tokens = Array(parts[(idx + 1)...])
        } else {
            tokens = parts
        }
        guard tokens.count >= 2,
              let roomID = ULID(tokens[0]) else { return }
        let invite = tokens[1]
        let focusNode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "node" })?
            .value
            .flatMap(ULID.init)
        do {
            let result: RoomJoinResult = try await hub.call(
                .roomJoin,
                params: RoomJoinParams(roomID: roomID, inviteToken: invite),
                expecting: RoomJoinResult.self
            )
            activate(roomID: roomID, members: result.members, workspaceID: result.room.workspaceID)
            UserDefaults.standard.removeObject(forKey: Self.pendingDeepLinkKey)
            lastJoinError = nil
            if let workspaceID = result.room.workspaceID {
                await onOpenWorkspace?(workspaceID)
            }
            if let focusNode {
                onFocusNode?(focusNode)
            }
            await sendNow()
        } catch {
            lastJoinError = error.localizedDescription
        }
    }

    private func onHubConnected() async {
        await rejoinAndSend()
        await consumePendingDeepLink()
    }

    private func scheduleSend(immediate: Bool) {
        sendTask?.cancel()
        sendTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(70)) }
            await self?.sendNow()
        }
    }

    private func sendNow() async {
        guard let roomID = activeRoomID, hub.isConnected else { return }
        do {
            try await hub.call(.presenceUpdate, params: PresenceUpdateParams(
                roomID: roomID,
                viewport: pendingViewport,
                cursor: pendingCursor,
                selectedNodeID: pendingSelection
            ))
        } catch {
            // Presence is ephemeral; the heartbeat retries after reconnection.
        }
    }

    private func rejoinAndSend() async {
        guard let roomID = activeRoomID else { return }
        if let result = try? await hub.call(
            .roomJoin,
            params: RoomJoinParams(roomID: roomID),
            expecting: RoomJoinResult.self
        ) {
            members = Dictionary(uniqueKeysWithValues: result.members.map { ($0.id, $0) })
            activeWorkspaceID = result.room.workspaceID
            if let workspaceID = result.room.workspaceID {
                await onOpenWorkspace?(workspaceID)
            }
        }
        await sendNow()
    }

    private func handle(_ event: EventMessage) {
        guard event.knownTopic == .presenceChanged,
              let payload = try? event.decodeParams(PresenceChangedTopicPayload.self),
              payload.roomID == activeRoomID,
              payload.memberID != localMemberID else { return }
        if payload.connected {
            remotePresences[payload.memberID] = payload
        } else {
            remotePresences.removeValue(forKey: payload.memberID)
        }
    }
}
