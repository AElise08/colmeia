import SwiftUI
import ColmeiaKit

/// Seletor de workspaces (§18.5): abrir, criar, renomear.
struct WorkspaceSelectorMenu: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var connection: EngineConnection

    @State private var criando = false
    @State private var renomeando = false
    @State private var nomeNovo = ""
    @State private var caminhoNovo = ""
    @State private var atividade: [ULID: WorkspaceActivity] = [:]

    var body: some View {
        Menu {
            ForEach(store.workspaces, id: \.id) { ws in
                Button {
                    Task { await store.open(workspaceID: ws.id) }
                } label: {
                    HStack(spacing: 8) {
                        if ws.id == store.workspace?.id {
                            Image(systemName: "checkmark")
                        }
                        Text(ws.nome)
                        Spacer(minLength: 12)
                        if let counts = atividade[ws.id], !counts.isEmpty {
                            Text(counts.resumo)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityLabel(rotuloAcessivel(workspace: ws))
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
                Task {
                    await store.refreshWorkspaces()
                    await refreshAtividade()
                }
            }
        } label: {
            Label(store.workspace?.nome ?? "Workspaces", systemImage: "square.grid.2x2")
        }
        .accessibilityLabel("Selecionar workspace")
        .onAppear { Task { await refreshAtividade() } }
        .onReceive(NotificationCenter.default.publisher(for: .colmeiaCreateWorkspace)) { _ in
            nomeNovo = ""
            caminhoNovo = ""
            criando = true
        }
        .onChange(of: store.workspaces) { _, _ in
            Task { await refreshAtividade() }
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

    /// `workspace.list` é deliberadamente leve; a contagem por estado vem de
    /// `session.list` para cada workspace. Fazemos em paralelo e só mostramos
    /// sessões vivas — histórico encerrado não deve parecer trabalho ativo.
    private func refreshAtividade() async {
        let workspaces = store.workspaces
        guard connection.isConnected else {
            atividade = [:]
            return
        }
        let pares = await withTaskGroup(of: (ULID, WorkspaceActivity)?.self) { group in
            for ws in workspaces {
                group.addTask {
                    guard let sessions = try? await connection.call(
                        .sessionList,
                        params: SessionListParams(workspaceID: ws.id),
                        expecting: SessionListResult.self
                    ) else { return nil }
                    return (ws.id, WorkspaceActivity(sessions: sessions))
                }
            }
            var result: [(ULID, WorkspaceActivity)] = []
            for await par in group {
                if let par { result.append(par) }
            }
            return result
        }
        // Ignorar respostas de uma lista anterior depois de o engine ressincronizar.
        let idsAtuais = Set(store.workspaces.map(\.id))
        atividade = Dictionary(uniqueKeysWithValues: pares.filter { idsAtuais.contains($0.0) })
    }

    private func rotuloAcessivel(workspace ws: WorkspaceSummary) -> String {
        let estado = atividade[ws.id]?.resumoAcessivel ?? "sem sessões ativas"
        return "Workspace \(ws.nome), \(estado)"
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

/// Valor de apresentação local, separado do DTO: somente sessões vivas contam
/// no panorama de trabalho do seletor (§18.5).
private struct WorkspaceActivity: Equatable {
    private var counts: [SessionEstado: Int] = [:]

    init(sessions: [Session]) {
        for session in sessions where session.estado.isViva {
            counts[session.estado, default: 0] += 1
        }
    }

    var isEmpty: Bool { counts.isEmpty }

    var resumo: String {
        SessionEstado.allCases.compactMap { estado in
            guard let count = counts[estado], count > 0 else { return nil }
            return "\(abreviacao(estado)) \(count)"
        }
        .joined(separator: " · ")
    }

    var resumoAcessivel: String {
        SessionEstado.allCases.compactMap { estado in
            guard let count = counts[estado], count > 0 else { return nil }
            return "\(count) \(estado.rawValue)"
        }
        .joined(separator: ", ")
    }

    private func abreviacao(_ estado: SessionEstado) -> String {
        switch estado {
        case .iniciando: return "iniciando"
        case .rodando: return "rodando"
        case .esperandoHumano: return "aguarda"
        case .aprovacaoPendente: return "aprovação"
        case .ociosa: return "ociosa"
        case .encerrada, .morta: return estado.rawValue
        }
    }
}
