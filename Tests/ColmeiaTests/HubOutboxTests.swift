import Foundation
import Testing
import ColmeiaKit

@Suite("Outbox durável §11.4")
struct HubOutboxTests {
    @Test func enqueuePersisteEmDiscoEVoltaDoReload() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("colmeia-outbox-\(UUID().uuidString)", isDirectory: true)
        let paths = ColmeiaPaths(root: url)
        try paths.ensureRootLayout()
        let roomID = ULID.generate()

        let params = try ColmeiaJSON.encoder().encode(MissionCreateParams(
            roomID: roomID, title: "X", definitionOfDone: "D"
        ))
        let outbox = HubOutbox(roomID: roomID, paths: paths)
        let entry = try outbox.enqueue(method: .missionCreate, paramsJSON: params)
        #expect(outbox.pendingCount == 1)
        #expect(outbox.pending().first?.method == .missionCreate)

        let restored = HubOutbox(roomID: roomID, paths: paths)
        #expect(restored.pendingCount == 1)
        #expect(restored.pending().first?.id == entry.id)

        try restored.remove(id: entry.id)
        #expect(restored.pendingCount == 0)
    }

    @Test func falhaIncrementaTentativas() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("colmeia-outbox-\(UUID().uuidString)", isDirectory: true)
        let paths = ColmeiaPaths(root: url)
        try paths.ensureRootLayout()
        let outbox = HubOutbox(roomID: ULID.generate(), paths: paths)
        let params = Data([1, 2, 3])
        let entry = try outbox.enqueue(method: .workstreamCreate, paramsJSON: params)
        try outbox.markFailure(id: entry.id, error: "offline")
        try outbox.markFailure(id: entry.id, error: "timeout")
        let pending = outbox.pending()
        #expect(pending.first?.tentativas == 2)
        #expect(pending.first?.ultimoErro == "timeout")
    }
}
