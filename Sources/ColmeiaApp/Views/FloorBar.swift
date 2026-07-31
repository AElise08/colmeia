import SwiftUI
import ColmeiaKit

/// Barra fina de andar no topo do canvas (§18.5): nome + aterrissar/descartar,
/// alternância pelo menu.
struct FloorBar: View {
    @EnvironmentObject private var store: AppStore
    @State private var criando = false
    @State private var nomeNovo = ""
    @State private var branchNova = ""
    @State private var confirmandoDescarte: Floor?
    @State private var erroCriacao: String?
    @State private var criandoEmAndamento = false

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Workspace base") {
                    Task { await store.switchFloor(nil) }
                }
                ForEach(store.floors.filter { $0.estado == .ativo || $0.estado == .orfao }, id: \.id) { floor in
                    Button {
                        Task { await store.switchFloor(floor) }
                    } label: {
                        if floor.estado == .orfao {
                            Label("Readotar \(floor.nome)…", systemImage: "exclamationmark.triangle")
                        } else {
                            Text(floor.nome)
                        }
                    }
                }
                Divider()
                Button("Novo andar…") {
                    nomeNovo = ""
                    branchNova = ""
                    erroCriacao = nil
                    criando = true
                }
            } label: {
                Label(store.activeFloor?.nome ?? "térreo", systemImage: "square.3.layers.3d")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let ativo = store.activeFloor {
                if let branch = ativo.branch {
                    Text(branch)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Aterrissar") {
                    Task { await store.landFloor(ativo) }
                }
                .controlSize(.small)
                .help("Encerra sessões do andar e remove o worktree; falha se houver mudanças não commitadas (§16.3)")
                Button("Descartar", role: .destructive) {
                    confirmandoDescarte = ativo
                }
                .controlSize(.small)
            } else {
                Text("térreo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(store.activeFloor == nil ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(Color.purple.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(store.activeFloor.map { "Andar ativo \($0.nome)" } ?? "Andar térreo")
        .sheet(isPresented: $criando) { formNovoAndar }
        .confirmationDialog(
            "Descartar o andar \(confirmandoDescarte?.nome ?? "")?",
            isPresented: Binding(get: { confirmandoDescarte != nil }, set: { if !$0 { confirmandoDescarte = nil } })
        ) {
            Button("Descartar (perde trabalho não commitado)", role: .destructive) {
                if let floor = confirmandoDescarte {
                    Task { await store.discardFloor(floor) }
                }
                confirmandoDescarte = nil
            }
        } message: {
            Text("Trabalho não commitado no worktree será PERDIDO (§16.4).")
        }
    }

    private var formNovoAndar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Novo andar").font(.headline)
            if let erroCriacao {
                Label(erroCriacao, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("Nome:", text: $nomeNovo, prompt: Text("bugfix-login"))
                TextField("Branch (opcional):", text: $branchNova, prompt: Text("andar/<nome>"))
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancelar") { criando = false }
                    .keyboardShortcut(.cancelAction)
                Button("Criar") {
                    let branch = branchNova.trimmingCharacters(in: .whitespaces)
                    erroCriacao = nil
                    criandoEmAndamento = true
                    Task {
                        let sucesso = await store.createFloor(
                            nome: nomeNovo.trimmingCharacters(in: .whitespaces),
                            branch: branch.isEmpty ? nil : branch
                        )
                        if sucesso { criando = false }
                        else { erroCriacao = store.lastError ?? "Não foi possível criar o andar." }
                        criandoEmAndamento = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nomeNovo.trimmingCharacters(in: .whitespaces).isEmpty || criandoEmAndamento)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
