import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

@Suite("Rotinas — ciclo de vida (§17.4/§25.6.4–25.6.5)")
struct RoutineLifecycleTests {
    @Test func onceVencidaFicaPendenteENuncaGanhaProximaAutomatica() {
        let agora = Date(timeIntervalSince1970: 1_700_000_000)
        let agenda = Agenda(tipo: .once, inicio: agora.addingTimeInterval(-60))

        let resultado = RoutineScheduling.recalcular(agenda: agenda, agora: agora, jaExecutou: false)
        #expect(resultado.estado == .pendenteAtrasada)
        #expect(resultado.proximaExecucao == nil)

        // Repetir o cálculo depois de um restart não transforma atraso em execução.
        let depoisDoRestart = RoutineScheduling.recalcular(
            agenda: agenda, agora: agora.addingTimeInterval(86_400), jaExecutou: false)
        #expect(depoisDoRestart.estado == .pendenteAtrasada)
        #expect(depoisDoRestart.proximaExecucao == nil)
    }

    @Test func onceExecutadaViraConcluida() {
        let agora = Date(timeIntervalSince1970: 1_700_000_000)
        let agenda = Agenda(tipo: .once, inicio: agora.addingTimeInterval(-1))
        let resultado = RoutineScheduling.recalcular(agenda: agenda, agora: agora, jaExecutou: true)
        #expect(resultado.estado == .concluida)
        #expect(resultado.proximaExecucao == nil)
    }

    @Test func rotinaRepetidaContinuaAgendadaSemRecuperarTicksPerdidos() {
        let agora = Date(timeIntervalSince1970: 1_700_000_000)
        let agenda = Agenda(tipo: .intervalo, intervaloSeg: 60, inicio: agora.addingTimeInterval(-3_600))
        let resultado = RoutineScheduling.recalcular(agenda: agenda, agora: agora, jaExecutou: true)
        #expect(resultado.estado == .agendada)
        #expect(resultado.proximaExecucao == agora.addingTimeInterval(60))
    }

    @Test func jsonAntigoSemEstadoAgendaDecodificaComDefault() throws {
        let routine = Routine(
            id: ULID.generate(), nome: "legada", workspaceID: ULID.generate(), alvo: ULID.generate(),
            comando: "echo oi", agenda: Agenda(tipo: .once, inicio: Date()))
        let encoder = JSONEncoder()
        let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(routine)) as? [String: Any])
        var legacy = object
        legacy.removeValue(forKey: "estadoAgenda")
        legacy.removeValue(forKey: "estado_agenda")
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(Routine.self, from: data)
        #expect(decoded.estadoAgenda == .agendada)
    }
}
