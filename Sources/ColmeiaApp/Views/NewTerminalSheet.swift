import SwiftUI
import ColmeiaKit

/// Opções avançadas do "Novo Terminal" (§5.2.1): o caminho de um passo é o menu
/// quick-start da toolbar; este diálogo cobre nome/papel/comando/cwd/monitorar.
struct NewTerminalSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    struct QuickStart: Identifiable {
        let id: String
        let nome: String
        let icone: String
    }

    static let quickStarts: [QuickStart] = [
        QuickStart(id: KnownAdapter.claudeCode.rawValue, nome: "Claude Code", icone: "sparkles"),
        QuickStart(id: KnownAdapter.codex.rawValue, nome: "Codex", icone: "chevron.left.forwardslash.chevron.right"),
        QuickStart(id: KnownAdapter.geminiCli.rawValue, nome: "Gemini CLI", icone: "diamond"),
        QuickStart(id: KnownAdapter.opencode.rawValue, nome: "OpenCode", icone: "curlybraces"),
        QuickStart(id: KnownAdapter.shell.rawValue, nome: "Shell", icone: "terminal"),
    ]

    @State private var adapter: String = KnownAdapter.claudeCode.rawValue
    @State private var nome = ""
    @State private var nomeAuto = ""
    @State private var papel = ""
    @State private var comandoOverride = ""
    @State private var cwd = ""
    @State private var monitorar = true
    @State private var criando = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Novo Terminal")
                .font(.title3.bold())

            HStack(spacing: 8) {
                ForEach(Self.quickStarts) { qs in
                    Button {
                        adapter = qs.id
                        if nome.isEmpty || nome == nomeAuto {
                            nome = store.nomeAutomatico(adapter: qs.id)
                            nomeAuto = nome
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: qs.icone)
                                .font(.system(size: 16))
                            Text(qs.nome)
                                .font(.caption2)
                        }
                        .frame(width: 76, height: 52)
                        .background(
                            adapter == qs.id ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(adapter == qs.id ? Color.accentColor : .clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Form {
                TextField("Nome (único no workspace):", text: $nome, prompt: Text("Claudio"))
                TextField("Papel (badge):", text: $papel, prompt: Text("Lead, Coder, Reviewer…"))
                TextField("Comando (override):", text: $comandoOverride, prompt: Text("padrão do adapter"))
                TextField("Diretório (cwd):", text: $cwd, prompt: Text(cwdPadrao))
                Toggle("Monitorar atividade (estados e aprovações)", isOn: $monitorar)
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Criar e lançar") {
                    criar()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nome.trimmingCharacters(in: .whitespaces).isEmpty || nomeDuplicado || criando)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if nome.isEmpty {
                nome = store.nomeAutomatico(adapter: adapter)
                nomeAuto = nome
            }
        }
    }

    private var cwdPadrao: String {
        store.workspace?.caminhoRaiz ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// `nome` é único case-insensitive no workspace (§5.2.1) — validação local
    /// antes de o engine rejeitar com `duplicate_node_name`.
    private var nomeDuplicado: Bool {
        let alvo = nome.trimmingCharacters(in: .whitespaces).lowercased()
        return store.nodes.values.contains {
            if case .terminal(let t) = $0 { return t.nome.lowercased() == alvo }
            return false
        }
    }

    private func criar() {
        criando = true
        let cwdFinal = cwd.trimmingCharacters(in: .whitespaces).isEmpty ? cwdPadrao : cwd
        Task {
            await store.addTerminal(
                nome: nome.trimmingCharacters(in: .whitespaces),
                papel: papel.trimmingCharacters(in: .whitespaces),
                adapter: adapter,
                comandoOverride: comandoOverride,
                cwd: (cwdFinal as NSString).expandingTildeInPath,
                monitorarAtividade: monitorar
            )
            dismiss()
        }
    }
}
