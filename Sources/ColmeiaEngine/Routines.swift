import Foundation
import ColmeiaKit

/// Forma de `routines.json` (§17.4): rotinas + contador de falhas consecutivas
/// (campo do engine, não do schema §5.7 — leitores ignoram campos extras, §0).
struct RoutinesFile: Codable {
    var routines: [Routine]
    var falhas: [String: Int]

    init(routines: [Routine] = [], falhas: [String: Int] = [:]) {
        self.routines = routines
        self.falhas = falhas
    }
}

public enum RoutineScheduling {
    /// Recalcula o estado de agenda sem produzir execuções retroativas (§17.4).
    /// O único caso que precisa de intervenção humana é `once` vencida e ainda
    /// não executada; ela não recebe `proxima_execucao` e jamais entra no tick.
    public static func estadoAgenda(
        agenda: Agenda, agora: Date, jaExecutou: Bool
    ) -> RoutineEstadoAgenda {
        guard agenda.tipo == .once else { return .agendada }
        if jaExecutou { return .concluida }
        return agenda.inicio <= agora ? .pendenteAtrasada : .agendada
    }

    /// Resultado único da religada/criação para manter `estado_agenda` e
    /// `proxima_execucao` coerentes.
    public static func recalcular(
        agenda: Agenda, agora: Date, jaExecutou: Bool, calendar: Calendar = .current
    ) -> (estado: RoutineEstadoAgenda, proximaExecucao: Date?) {
        let estado = estadoAgenda(agenda: agenda, agora: agora, jaExecutou: jaExecutou)
        return (
            estado,
            estado == .pendenteAtrasada || estado == .concluida
                ? nil
                : proximaExecucao(agenda: agenda, agora: agora, jaExecutou: jaExecutou, calendar: calendar)
        )
    }

    /// §17.4 — nunca retroativo: recalcula a próxima a partir de `agora`.
    /// `jaExecutou`: para `once`, execução única já feita → nil.
    public static func proximaExecucao(
        agenda: Agenda, agora: Date, jaExecutou: Bool, calendar: Calendar = .current
    ) -> Date? {
        var next: Date?
        switch agenda.tipo {
        case .once:
            if jaExecutou { return nil }
            // `once` no passado não executada: fica sem agenda automática
            // (pendente_atrasada é decisão da UI, §17.4 — nunca dispara sozinha).
            next = agenda.inicio > agora ? agenda.inicio : nil
        case .intervalo:
            guard let intervalo = agenda.intervaloSeg, intervalo > 0 else { return nil }
            if agenda.inicio > agora {
                next = agenda.inicio
            } else {
                next = agora.addingTimeInterval(Double(intervalo))
            }
        case .diaria:
            next = proximaHora(agenda: agenda, agora: agora, dias: nil, calendar: calendar)
        case .semanal:
            guard let dias = agenda.dias, !dias.isEmpty else { return nil }
            next = proximaHora(agenda: agenda, agora: agora, dias: Set(dias), calendar: calendar)
        }
        if case .em(let fim) = agenda.fimRepeticao, let candidate = next, candidate > fim {
            return nil
        }
        return next
    }

    /// `hora` "HH:mm" local; `dias` (semanal) usa a convenção do Calendar: 1 = domingo … 7 = sábado.
    private static func proximaHora(
        agenda: Agenda, agora: Date, dias: Set<Int>?, calendar: Calendar
    ) -> Date? {
        guard let hora = agenda.hora else { return nil }
        let parts = hora.split(separator: ":")
        guard parts.count == 2, let hh = Int(parts[0]), let mm = Int(parts[1]),
              (0...23).contains(hh), (0...59).contains(mm)
        else { return nil }
        let base = max(agora, agenda.inicio)
        for offset in 0..<15 {
            guard let dia = calendar.date(byAdding: .day, value: offset, to: base),
                  let candidate = calendar.date(bySettingHour: hh, minute: mm, second: 0, of: dia)
            else { continue }
            if candidate <= base { continue }
            if let dias {
                let weekday = calendar.component(.weekday, from: candidate)
                guard dias.contains(weekday) else { continue }
            }
            return candidate
        }
        return nil
    }

    /// §17.3 — elegibilidade no disparo.
    public static func elegibilidade(
        alvoExiste: Bool, sessaoViva: Bool, estado: SessionEstado?
    ) -> RoutineResultado {
        guard alvoExiste, sessaoViva, let estado, estado.isViva else {
            return .puladaAlvoAusente
        }
        switch estado {
        case .esperandoHumano, .ociosa:
            return .executada
        default:
            return .puladaOcupado
        }
    }

    /// §17.3 — após M falhas consecutivas (DEVERIA ser 3) a rotina DEVE ser desabilitada.
    public static let maxFalhasConsecutivas = 3
}
