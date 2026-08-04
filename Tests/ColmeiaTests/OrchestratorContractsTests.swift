import Foundation
import Testing
import ColmeiaKit

@Suite("Contratos estruturados do orquestrador")
struct OrchestratorContractsTests {
    @Test func planoExigeObjetivoProximoPassoEFrentesAcessiveis() throws {
        let front = OrchestratorFront(
            title: "Canvas",
            objective: "Reduzir custo de pan",
            definitionOfDone: ["pan sem congelar"])
        let plan = OrchestratorPlan(
            objective: "Melhorar a operação",
            fronts: [front],
            nextStep: "medir")

        try plan.validate()
        #expect(OrchestratorPhase.canTransition(from: .plan, to: .delegate))
        #expect(!OrchestratorPhase.canTransition(from: .plan, to: .deliver))
    }

    @Test func planoRejeitaCicloDeDependencias() {
        let a = ULID.generate()
        let b = ULID.generate()
        let frontA = OrchestratorFront(id: a, title: "A", objective: "a", definitionOfDone: ["ok"], dependencies: [b])
        let frontB = OrchestratorFront(id: b, title: "B", objective: "b", definitionOfDone: ["ok"], dependencies: [a])
        let plan = OrchestratorPlan(objective: "x", fronts: [frontA, frontB], nextStep: "y")

        #expect(throws: OrchestratorValidationError.dependencyCycle) {
            try plan.validate()
        }
    }

    @Test func delegacaoEdecisaoNaoAceitamFormatoAmbiguo() {
        let delegation = OrchestratorDelegation(task: "", definitionOfDone: [])
        #expect(throws: OrchestratorValidationError.taskRequired) {
            try delegation.validate()
        }

        let decision = OrchestratorDecisionRequest(
            title: "Instalar?", question: "Posso instalar?", options: ["sim"], risk: "medium")
        #expect(throws: OrchestratorValidationError.decisionNeedsOptions) {
            try decision.validate()
        }
    }

    @Test func politicasDeRenderizacaoReduzemDetalhesDuranteInteracao() {
        #expect(CanvasPerformancePolicy.detailLevel(zoom: 1, interacting: false) == .full)
        #expect(CanvasPerformancePolicy.detailLevel(zoom: 0.6, interacting: false) == .compact)
        #expect(CanvasPerformancePolicy.detailLevel(zoom: 1, interacting: true) == .minimal)
        #expect(!CanvasPerformancePolicy.shouldAnimateConnections(interacting: true, reduceMotion: false))
    }
}
