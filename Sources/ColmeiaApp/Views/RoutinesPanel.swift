import SwiftUI
import ColmeiaKit

/// Editor de rotinas (§17.1): nome, alvo, comando, agenda, início, fim, notificar, habilitada.
struct RoutinesPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var editando: Routine?
    @State private var criandoNova = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Rotinas")
                    .font(.title3.bold())
                Spacer()
                Button("Nova rotina…") { criandoNova = true }
                    .disabled(terminais.isEmpty)
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            if store.routines.isEmpty {
                Text(terminais.isEmpty
                     ? "Crie um terminal antes de agendar rotinas."
                     : "Nenhuma rotina neste workspace.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(store.routines, id: \.id) { routine in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(routine.nome).font(.headline)
                                if !routine.habilitada {
                                    Text("desabilitada")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .background(.gray.opacity(0.3), in: Capsule())
                                }
                            }
                            Text("→ \(store.nodeName(routine.alvo)) · \(descricaoAgenda(routine.agenda))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let proxima = routine.proximaExecucao {
                                Text("próxima: \(proxima.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Rodar agora") {
                            Task {
                                _ = try? await store.connection.call(
                                    .routineRunNow,
                                    params: RoutineRunNowParams(routineID: routine.id)
                                )
                                await store.refreshRoutines()
                            }
                        }
                        .controlSize(.small)
                        Button("Editar") { editando = routine }
                            .controlSize(.small)
                        Button(role: .destructive) {
                            Task {
                                _ = try? await store.connection.call(
                                    .routineDelete,
                                    params: RoutineDeleteParams(id: routine.id)
                                )
                                await store.refreshRoutines()
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 200, maxHeight: 360)
            }
        }
        .frame(width: 560)
        .sheet(isPresented: $criandoNova) {
            RoutineForm(existente: nil)
        }
        .sheet(item: $editando) { routine in
            RoutineForm(existente: routine)
        }
        .task { await store.refreshRoutines() }
    }

    private var terminais: [TerminalNode] {
        store.nodes.values.compactMap {
            if case .terminal(let t) = $0 { return t }
            return nil
        }
    }

    private func descricaoAgenda(_ agenda: Agenda) -> String {
        switch agenda.tipo {
        case .once: return "uma vez em \(agenda.inicio.formatted(date: .abbreviated, time: .shortened))"
        case .intervalo: return "a cada \(agenda.intervaloSeg ?? 0)s"
        case .diaria: return "diária às \(agenda.hora ?? "?")"
        case .semanal: return "semanal (\((agenda.dias ?? []).map(String.init).joined(separator: ","))) às \(agenda.hora ?? "?")"
        }
    }
}

extension Routine: Identifiable {}

private struct RoutineForm: View {
    let existente: Routine?

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var nome = ""
    @State private var alvo: ULID?
    @State private var comando = ""
    @State private var tipo: AgendaTipo = .intervalo
    @State private var intervaloValor = 30
    @State private var intervaloUnidade = 60
    @State private var hora = "09:00"
    @State private var dias: Set<Int> = [1, 2, 3, 4, 5]
    @State private var inicio = Date()
    @State private var temFim = false
    @State private var fim = Date().addingTimeInterval(86400 * 30)
    @State private var notificar = true
    @State private var habilitada = true

    private let nomesDias = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existente == nil ? "Nova rotina" : "Editar rotina")
                .font(.title3.bold())

            Form {
                TextField("Nome:", text: $nome)
                Picker("Terminal alvo:", selection: $alvo) {
                    Text("—").tag(ULID?.none)
                    ForEach(terminais, id: \.id) { t in
                        Text(t.nome).tag(ULID?.some(t.id))
                    }
                }
                TextField("Comando (injetado no PTY):", text: $comando, prompt: Text("revise os PRs abertos"))

                Picker("Agenda:", selection: $tipo) {
                    Text("uma vez").tag(AgendaTipo.once)
                    Text("a cada N").tag(AgendaTipo.intervalo)
                    Text("diária").tag(AgendaTipo.diaria)
                    Text("semanal").tag(AgendaTipo.semanal)
                }

                switch tipo {
                case .intervalo:
                    HStack {
                        TextField("A cada:", value: $intervaloValor, format: .number)
                            .frame(width: 120)
                        Picker("", selection: $intervaloUnidade) {
                            Text("segundos").tag(1)
                            Text("minutos").tag(60)
                            Text("horas").tag(3600)
                        }
                        .labelsHidden()
                    }
                case .diaria:
                    TextField("Hora (HH:mm):", text: $hora)
                case .semanal:
                    TextField("Hora (HH:mm):", text: $hora)
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { dia in
                            Toggle(nomesDias[dia], isOn: Binding(
                                get: { dias.contains(dia) },
                                set: { on in
                                    if on { dias.insert(dia) } else { dias.remove(dia) }
                                }
                            ))
                            .toggleStyle(.button)
                            .controlSize(.small)
                        }
                    }
                case .once:
                    EmptyView()
                }

                DatePicker("Início:", selection: $inicio)
                Toggle("Tem fim de repetição", isOn: $temFim)
                if temFim {
                    DatePicker("Fim:", selection: $fim)
                }
                Toggle("Notificar ao rodar", isOn: $notificar)
                Toggle("Habilitada", isOn: $habilitada)
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existente == nil ? "Criar" : "Salvar") { salvar() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nome.isEmpty || comando.isEmpty || alvo == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: preencher)
    }

    private var terminais: [TerminalNode] {
        store.nodes.values.compactMap {
            if case .terminal(let t) = $0 { return t }
            return nil
        }
    }

    private func preencher() {
        guard let r = existente else {
            alvo = terminais.first?.id
            return
        }
        nome = r.nome
        alvo = r.alvo
        comando = r.comando
        tipo = r.agenda.tipo
        if let seg = r.agenda.intervaloSeg {
            if seg % 3600 == 0 { intervaloValor = seg / 3600; intervaloUnidade = 3600 }
            else if seg % 60 == 0 { intervaloValor = seg / 60; intervaloUnidade = 60 }
            else { intervaloValor = seg; intervaloUnidade = 1 }
        }
        hora = r.agenda.hora ?? "09:00"
        dias = Set(r.agenda.dias ?? [])
        inicio = r.agenda.inicio
        if case .em(let data) = r.agenda.fimRepeticao {
            temFim = true
            fim = data
        }
        notificar = r.notificar
        habilitada = r.habilitada
    }

    private func salvar() {
        guard let ws = store.workspace, let alvo else { return }
        let agenda = Agenda(
            tipo: tipo,
            intervaloSeg: tipo == .intervalo ? intervaloValor * intervaloUnidade : nil,
            hora: (tipo == .diaria || tipo == .semanal) ? hora : nil,
            dias: tipo == .semanal ? dias.sorted() : nil,
            inicio: inicio,
            fimRepeticao: temFim ? .em(fim) : .nunca
        )
        Task {
            do {
                if let existente {
                    _ = try await store.connection.call(.routineUpdate, params: RoutineUpdateParams(
                        id: existente.id,
                        nome: nome,
                        alvo: alvo,
                        comando: comando,
                        agenda: agenda,
                        notificar: notificar,
                        habilitada: habilitada
                    ))
                } else {
                    _ = try await store.connection.call(.routineCreate, params: RoutineCreateParams(
                        nome: nome,
                        workspaceID: ws.id,
                        alvo: alvo,
                        comando: comando,
                        agenda: agenda,
                        notificar: notificar,
                        habilitada: habilitada
                    ))
                }
                await store.refreshRoutines()
            } catch {
                store.lastError = "rotina: \(String(describing: error))"
            }
            dismiss()
        }
    }
}
