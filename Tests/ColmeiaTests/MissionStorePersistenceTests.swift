import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

@Suite("MissionStore — persistência e round-trip")
struct MissionStorePersistenceTests {
    @Test func missaoEFrentePersistemEmDiscoEVoltamCarregadas() throws {
        let paths = try tempPaths()
        let roomID = ULID.generate()
        let store = MissionStore(roomID: roomID)
        let mission = try store.createMission(
            title: "Persistência",
            definitionOfDone: "Missão volta do disco",
            ownerID: "humano:local"
        )
        let ws = try store.createWorkstream(
            missionID: mission.id, title: "F", objective: "O", definitionOfDone: "D")
        _ = try store.transitionMission(id: mission.id, to: .active)
        _ = try store.transitionWorkstream(id: ws.id, to: .active)
        let decision = try store.createDecision(
            missionID: mission.id, workstreamID: ws.id,
            question: "Reabrir?", requestedBy: .humanoLocal)
        _ = try store.addRelation(
            fromID: ws.id, toID: mission.id, kind: .produces, author: .humanoLocal)
        try store.persist(to: paths)

        let restored = try MissionStore.load(from: paths, roomID: roomID)
        #expect(restored.getMission(mission.id)?.state == .active)
        #expect(restored.getWorkstream(ws.id)?.state == .active)
        #expect(restored.getDecision(decision.id)?.state == .open)
        #expect(restored.listRelations(kind: .produces).count == 1)
    }

    @Test func rejeitaMissaoSemDoD() {
        let store = MissionStore(roomID: ULID.generate())
        #expect(throws: MissionValidationError.self) {
            _ = try store.createMission(title: "X", definitionOfDone: "  ", ownerID: "o")
        }
    }

    @Test func dependeEmSiMesmoEhRecusado() throws {
        let store = MissionStore(roomID: ULID.generate())
        let mission = try store.createMission(
            title: "X", definitionOfDone: "D", ownerID: "o")
        let a = try store.createWorkstream(
            missionID: mission.id, title: "A", objective: "O", definitionOfDone: "D")
        #expect(throws: WorkstreamValidationError.self) {
            _ = try store.updateWorkstream(id: a.id, dependsOn: [a.id])
        }
    }

    private func tempPaths() throws -> ColmeiaPaths {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("colmeia-mission-\(UUID().uuidString)", isDirectory: true)
        let paths = ColmeiaPaths(root: url)
        try paths.ensureRootLayout()
        return paths
    }
}
