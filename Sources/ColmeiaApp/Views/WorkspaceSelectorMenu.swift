import SwiftUI
import ColmeiaKit

/// Seletor de workspaces (§18.5): abrir, criar, renomear.
struct WorkspaceSelectorMenu: View {
    @EnvironmentObject private var store: AppStore

    @State private var criando = false
    @State private var renomeando = false
    @State private var nomeNovo = ""
    @State private var caminhoNovo = ""

    var body: some View {
        Menu {
            ForEach(store.workspaces, id: \.id) { ws in
                Button {
                    Task { await store.open(workspaceID: ws.id) }
                } label: {
                    if ws.id == store.workspace?.id {
                        Label(ws.nome, systemImage: "checkmark")
                    } else {
                        Text(ws.nome)
                    }
                }
            }
            Divider()
            Button("Novo workspace…") {
                nomeNovo = ""
                caminhoNovo = ""
                criando = true
            }
            if store.workspace != nil {
                Button("Renomear…") {
                    nomeNovo = store.workspace?.nome ?? ""
                    renomeando = true
                }
            }
            Button("Recarregar lista") {
                Task { await store.refreshWorkspaces() }
            }
        } label: {
            Label(store.workspace?.nome ?? "Workspaces", systemImage: "square.grid.2x2")
        }
        .sheet(isPresented: $criando) {
            workspaceForm(titulo: "Novo workspace", confirmar: "Criar") {
                let caminho = caminhoNovo.trimmingCharacters(in: .whitespaces)
                Task {
                    await store.createWorkspace(
                        nome: nomeNovo.trimmingCharacters(in: .whitespaces),
                        caminhoRaiz: caminho.isEmpty ? nil : (caminho as NSString).expandingTildeInPath
                    )
                }
            }
        }
        .sheet(isPresented: $renomeando) {
            workspaceForm(titulo: "Renomear workspace", confirmar: "Renomear", mostrarCaminho: false) {
                store.renameWorkspace(nomeNovo.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    @ViewBuilder
    private func workspaceForm(
        titulo: String,
        confirmar: String,
        mostrarCaminho: Bool = true,
        acao: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(titulo).font(.title3.bold())
            Form {
                TextField("Nome:", text: $nomeNovo)
                if mostrarCaminho {
                    TextField("Pasta do projeto (opcional):", text: $caminhoNovo, prompt: Text("~/app/…"))
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancelar") {
                    criando = false
                    renomeando = false
                }
                .keyboardShortcut(.cancelAction)
                Button(confirmar) {
                    acao()
                    criando = false
                    renomeando = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nomeNovo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
