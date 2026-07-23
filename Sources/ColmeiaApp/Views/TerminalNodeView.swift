import SwiftUI
import AppKit
import ColmeiaKit

struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var controller: TerminalController

    func makeNSView(context: Context) -> ColmeiaTerminalView {
        controller.terminalView
    }

    func updateNSView(_ nsView: ColmeiaTerminalView, context: Context) {}
}

struct TerminalNodeView<Drag: Gesture>: View {
    let node: TerminalNode
    @ObservedObject var controller: TerminalController
    let zoom: Double
    let conteudoVisivel: Bool
    let dragGesture: Drag

    @EnvironmentObject private var store: AppStore
    @State private var pulsando = false
    @State private var confirmandoDelete = false

    private var estado: SessionEstado? { controller.estado }
    private var morto: Bool {
        if let estado { return !estado.isViva }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if zoom < 0.4 {
                cartaoSemantico
            } else if conteudoVisivel {
                corpo
            } else {
                moldura
            }
            footer
        }
        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(bordaCor, lineWidth: 1))
        .opacity(morto && estado != nil ? 0.75 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Cabeçalho (§18.3)

    private var header: some View {
        HStack(spacing: 6) {
            indicadorEstado
            Text(node.nome)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let papel = node.papel {
                Text(papel)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(papelCor(papel).opacity(0.25), in: Capsule())
            }
            badgeAprovacoes
            Spacer(minLength: 4)
            Text(EstadoStyle.rotulo(estado))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Menu {
                if controller.viva {
                    Button("Matar sessão") {
                        Task { await controller.kill() }
                    }
                } else {
                    Button("Relançar") {
                        Task { await store.relaunch(nodeID: node.id) }
                    }
                }
                if let session = controller.session {
                    Button("Replay") { store.replaySession = session }
                }
                Button("Abrir no editor") { EditorOpener.abrir(caminho: node.cwd) }
                Divider()
                Button("Apagar nó", role: .destructive) { confirmandoDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(headerFundo)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .confirmationDialog(
            "Apagar o nó \(node.nome)?",
            isPresented: $confirmandoDelete
        ) {
            Button(controller.viva ? "Matar sessão e apagar" : "Apagar", role: .destructive) {
                Task { await store.deleteNode(node.id) }
            }
        } message: {
            if controller.viva {
                Text("A sessão ativa será encerrada primeiro (§7.2).")
            }
        }
    }

    private var headerFundo: some ShapeStyle {
        if estado == .esperandoHumano {
            return AnyShapeStyle(Color.orange.opacity(0.22))
        }
        if morto && estado != nil {
            return AnyShapeStyle(Color.gray.opacity(0.18))
        }
        return AnyShapeStyle(.thinMaterial)
    }

    private var indicadorEstado: some View {
        Circle()
            .fill(EstadoStyle.cor(estado))
            .frame(width: 8, height: 8)
            .opacity(estado == .rodando ? (pulsando ? 0.35 : 1) : 1)
            .animation(
                estado == .rodando
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: pulsando
            )
            .onAppear { pulsando = true }
    }

    @ViewBuilder
    private var badgeAprovacoes: some View {
        let pendentes = store.pendingApprovals(nodeID: node.id)
        if let maisAntiga = pendentes.first {
            Label("\(pendentes.count) · \(idade(maisAntiga.criadaEm))", systemImage: "exclamationmark.shield.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red, in: Capsule())
                .onTapGesture { store.showApprovals = true }
        }
    }

    private var bordaCor: Color {
        switch estado {
        case .aprovacaoPendente: return .red
        case .esperandoHumano: return .orange
        default: return Color.primary.opacity(0.15)
        }
    }

    private func papelCor(_ papel: String) -> Color {
        let paleta: [Color] = [.blue, .purple, .pink, .teal, .indigo, .mint]
        let hash = abs(papel.lowercased().hashValue)
        return paleta[hash % paleta.count]
    }

    // MARK: - Corpo

    @ViewBuilder
    private var corpo: some View {
        if controller.session == nil && estado == nil {
            VStack(spacing: 8) {
                Text("sem sessão")
                    .foregroundStyle(.secondary)
                Button("Lançar") {
                    Task { await store.relaunch(nodeID: node.id) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Nó morto mantém o último frame do emulador (§18.3); o overlay oferece relançar.
            TerminalHostView(controller: controller)
                .overlay(alignment: .bottom) {
                    if morto && estado != nil {
                        HStack(spacing: 10) {
                            Text(estado == .encerrada ? "sessão encerrada" : "sessão morta")
                                .font(.caption)
                            if let motivo = controller.motivoEstado {
                                Text(motivo)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Relançar") {
                                Task { await store.relaunch(nodeID: node.id) }
                            }
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 10)
                    }
                }
        }
    }

    /// Fora do viewport: só moldura, sem renderizar conteúdo (§18.2).
    private var moldura: some View {
        Rectangle()
            .fill(Color.black.opacity(0.15))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Zoom semântico: abaixo de ~40% o terminal vira cartão (§18.2).
    private var cartaoSemantico: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(node.nome)
                .font(.system(size: 26, weight: .bold))
                .lineLimit(1)
            HStack(spacing: 10) {
                Circle().fill(EstadoStyle.cor(estado)).frame(width: 18, height: 18)
                Text(EstadoStyle.rotulo(estado))
                    .font(.system(size: 20))
                if let papel = node.papel {
                    Text(papel)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if !controller.ultimaLinha.isEmpty {
                Text(controller.ultimaLinha)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Rodapé (§18.3)

    private var footer: some View {
        HStack(spacing: 8) {
            Text(cwdAbreviado)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(node.adapter)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Button {
                EditorOpener.abrir(caminho: node.cwd)
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .help("Abrir cwd no editor (⌘E)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial)
    }

    private var cwdAbreviado: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if node.cwd.hasPrefix(home) {
            return "~" + node.cwd.dropFirst(home.count)
        }
        return node.cwd
    }

    private func idade(_ data: Date) -> String {
        let s = Int(Date().timeIntervalSince(data))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}
