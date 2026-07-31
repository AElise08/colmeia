import Foundation
import ColmeiaKit

/// Estado reativo de uma sala multiplayer — membros, eventos, presença, room_seq.
/// Atualiza automaticamente quando eventos chegam do Hub.
@MainActor
final class RoomSessionStore: ObservableObject {
    @Published private(set) var members: [Member] = []
    @Published private(set) var events: [CollaborativeSessionEvent] = []
    @Published private(set) var roomSeq: UInt64 = 0
    @Published private(set) var room: Room?
    @Published private(set) var joined = false

    private weak var hub: HubConnection?

    var onRoomReady: ((Room) -> Void)?

    func connect(hub: HubConnection) {
        self.hub = hub
        hub.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event)
            }
        }
    }

    func disconnect() {
        hub?.onEvent = nil
    }

    /// Carrega snapshot inicial ao entrar na sala.
    func joinRoom(roomID: ULID, via hub: HubConnection) async throws {
        let result: RoomSnapshotResult = try await hub.call(.roomSnapshot,
            params: RoomSnapshotParams(roomID: roomID),
            expecting: RoomSnapshotResult.self)
        members = result.members
        room = result.room
        roomSeq = result.roomSeq
        joined = true
        onRoomReady?(result.room)
    }

    func leaveRoom() {
        members = []
        events = []
        roomSeq = 0
        room = nil
        joined = false
    }

    // MARK: - Eventos

    private func handleEvent(_ event: EventMessage) {
        switch event.knownTopic {
        case .memberJoined:
            if let payload = try? event.decodeParams(MemberJoinedTopicPayload.self) {
                if !members.contains(where: { $0.id == payload.member.id }) {
                    members.append(payload.member)
                    members.sort { $0.joinedAt < $1.joinedAt }
                }
                if let seq = payload.roomSeq { roomSeq = seq }
            }
        case .memberLeft:
            if let payload = try? event.decodeParams(MemberLeftTopicPayload.self) {
                members.removeAll { $0.id == payload.memberID }
            }
        case .roomUpdated:
            if let payload = try? event.decodeParams(RoomUpdatedTopicPayload.self) {
                room = payload.room
            }
        case .presenceChanged:
            _ = try? event.decodeParams(PresenceChangedTopicPayload.self)
        case .sessionEventAppended:
            break
        default:
            break
        }
    }
}
