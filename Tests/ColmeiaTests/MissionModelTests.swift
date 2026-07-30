import Foundation
import Testing
import ColmeiaKit

@Suite("Modelo de Missão §5.2–5.8 / §9")
struct MissionModelTests {
    @Test func fsmMissaoSegueSpec() {
        #expect(Mission.canTransition(from: .draft, to: .active))
        #expect(Mission.canTransition(from: .active, to: .blocked))
        #expect(Mission.canTransition(from: .blocked, to: .active))
        #expect(Mission.canTransition(from: .active, to: .inReview))
        #expect(Mission.canTransition(from: .inReview, to: .completed))
        #expect(Mission.canTransition(from: .completed, to: .active))
        #expect(Mission.canTransition(from: .draft, to: .archived))
        #expect(!Mission.canTransition(from: .draft, to: .completed))
        #expect(!Mission.canTransition(from: .blocked, to: .completed))
    }

    @Test func fsmFrenteSegueSpec() {
        #expect(Workstream.canTransition(from: .notStarted, to: .active))
        #expect(Workstream.canTransition(from: .active, to: .blocked))
        #expect(Workstream.canTransition(from: .blocked, to: .active))
        #expect(Workstream.canTransition(from: .active, to: .waitingForReview))
        #expect(Workstream.canTransition(from: .waitingForReview, to: .completed))
        #expect(Workstream.canTransition(from: .active, to: .canceled))
        #expect(!Workstream.canTransition(from: .completed, to: .active))
        #expect(!Workstream.canTransition(from: .blocked, to: .waitingForReview))
    }

    @Test func fsmDecisaoSegueSpec() {
        #expect(Decision.canTransition(from: .open, to: .decided))
        #expect(Decision.canTransition(from: .open, to: .canceled))
        #expect(Decision.canTransition(from: .decided, to: .superseded))
        #expect(!Decision.canTransition(from: .decided, to: .open))
        #expect(!Decision.canTransition(from: .canceled, to: .open))
    }

    @Test func memberRolesSaoOwnerEditorViewer() {
        #expect(MemberRole.allCases == [.owner, .editor, .viewer])
        let editor = Member(
            id: "e", displayName: "Ed", roles: [.editor], joinedAt: Date())
        #expect(editor.canEdit)
        #expect(!editor.canAdminister)
        let viewer = Member(
            id: "v", displayName: "Vi", roles: [.viewer], joinedAt: Date())
        #expect(!viewer.canEdit)
        #expect(!viewer.canAdminister)
        let owner = Member(
            id: "o", displayName: "Ow", roles: [.owner], joinedAt: Date())
        #expect(owner.canEdit && owner.canAdminister)
    }

    @Test func storeMissaoFrenteDecisaoRelacaoEBriefing() throws {
        let roomID = ULID.generate()
        let store = MissionStore(roomID: roomID)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let mission = try store.createMission(
            title: "Lançar canvas",
            context: "SPEC.md é a fonte",
            definitionOfDone: "Missão ativa com frentes e entrega aceita",
            ownerID: "humano:local",
            at: now
        )
        #expect(mission.state == .draft)
        #expect(throws: MissionValidationError.self) {
            try store.transitionMission(id: mission.id, to: .active, at: now)
        }

        let ws = try store.createWorkstream(
            missionID: mission.id,
            title: "Pesquisa",
            objective: "Mapear lacunas",
            definitionOfDone: "Lista de gaps priorizada",
            at: now
        )
        let active = try store.transitionMission(id: mission.id, to: .active, at: now)
        #expect(active.state == .active)

        let decision = try store.createDecision(
            missionID: mission.id,
            workstreamID: ws.id,
            question: "Usar Metal ou CoreAnimation?",
            requestedBy: .humanoLocal,
            at: now
        )
        #expect(decision.state == .open)
        let decided = try store.decide(
            id: decision.id,
            decisionText: "Metal para backdrop",
            rationale: "performance",
            deciderID: "humano:local",
            at: now
        )
        #expect(decided.state == .decided)

        let rel = try store.addRelation(
            fromID: ws.id, toID: mission.id, kind: .informs,
            author: .humanoLocal, at: now
        )
        #expect(rel.kind == .informs)
        #expect(throws: RelationValidationError.self) {
            try store.addRelation(
                fromID: ws.id, toID: ws.id, kind: .dependsOn,
                author: .humanoLocal, at: now
            )
        }

        let briefing = try store.buildWorkstreamBriefing(
            workstreamID: ws.id,
            agentName: "pesquisador",
            agentRole: "discovery",
            capabilities: ["read", "note"],
            allowedArtifacts: ["notes/*.md"]
        )
        #expect(briefing.contains("Lançar canvas"))
        #expect(briefing.contains("Mapear lacunas"))
        #expect(briefing.contains("Publique progresso"))
    }

    @Test func dependsOnDetectaCiclo() throws {
        let store = MissionStore(roomID: ULID.generate())
        let mission = try store.createMission(
            title: "M", definitionOfDone: "D", ownerID: "o")
        let a = try store.createWorkstream(
            missionID: mission.id, title: "A", objective: "oa", definitionOfDone: "da")
        let b = try store.createWorkstream(
            missionID: mission.id, title: "B", objective: "ob", definitionOfDone: "db",
            dependsOn: [a.id])
        #expect(throws: WorkstreamValidationError.self) {
            try store.updateWorkstream(id: a.id, dependsOn: [b.id])
        }
    }

    @Test func relationGraphDetectaCiclo() {
        let a = ULID.generate(), b = ULID.generate(), c = ULID.generate()
        #expect(RelationGraph.hasCycle(edges: [
            (from: a, to: b), (from: b, to: c), (from: c, to: a)
        ]))
        #expect(!RelationGraph.hasCycle(edges: [
            (from: a, to: b), (from: b, to: c)
        ]))
    }

    @Test func deliveryEstadosDaSpec() {
        #expect(DeliveryEstado.allCases.contains(.draft))
        #expect(DeliveryEstado.allCases.contains(.proposed))
        #expect(DeliveryEstado.allCases.contains(.accepted))
        #expect(DeliveryEstado.allCases.contains(.reopened))
        #expect(DeliveryEstado.decodeLegacy("completed") == .accepted)
        #expect(Delivery.canTransition(from: .proposed, to: .accepted))
        #expect(Delivery.canTransition(from: .accepted, to: .reopened))
    }

    @Test func briefingIncompletoFalha() throws {
        let store = MissionStore(roomID: ULID.generate())
        let mission = try store.createMission(
            title: "T", definitionOfDone: "D", ownerID: "o")
        let ws = try store.createWorkstream(
            missionID: mission.id, title: "F", objective: "O", definitionOfDone: "D")
        #expect(throws: MissionStoreError.self) {
            try store.buildWorkstreamBriefing(workstreamID: ws.id, agentName: "  ")
        }
    }
}
