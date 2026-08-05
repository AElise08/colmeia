import SwiftUI
import WebKit
import ColmeiaKit

/// [v1.5 antecipado] — nó portal: WKWebView + barra fina (voltar/avançar/recarregar,
/// campo de URL editável, título da página quando disponível). A URL do documento é a
/// fonte da verdade: digitar → `node.update {url}` → eco → `navigateIfNeeded` (guarda
/// anti-loop no controller). Navegação interna do webview volta como `node.update`.
struct PortalNodeView<Drag: Gesture>: View {
    let node: PortalNode
    @ObservedObject var controller: PortalController
    let dragGesture: Drag

    @EnvironmentObject private var store: AppStore
    @FocusState private var urlFocada: Bool
    @State private var urlDigitada = ""
    @State private var confirmandoDelete = false

    var body: some View {
        VStack(spacing: 0) {
            barra
            if let titulo = tituloVisivel {
                linhaTitulo(titulo)
            }
            PortalWebView(webView: controller.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !portalTimelineEvents.isEmpty {
                portalTimeline
            }
        }
        .background(ColmeiaCanvasTheme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(ColmeiaCanvasTheme.cyan.opacity(0.32), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Recarregar") { controller.recarregar() }
            Button("Apagar portal", role: .destructive) { confirmandoDelete = true }
        }
        .onAppear {
            urlDigitada = node.url == "about:blank" ? "" : node.url
            controller.navigateIfNeeded(to: node.url)
            if node.url == "about:blank" {
                urlFocada = true // criado em branco: foco direto na barra
            }
        }
        // Eco de node.update {url} (deste ou de outro cliente) navega o webview;
        // a guarda anti-loop no controller evita re-navegação da própria navegação.
        .onChange(of: node.url) { _, nova in
            if !urlFocada {
                urlDigitada = nova == "about:blank" ? "" : nova
            }
            controller.navigateIfNeeded(to: nova)
        }
        // Navegação interna (link/redirect): reflete no campo quando não está em edição.
        .onChange(of: controller.urlAtual) { _, nova in
            if let nova, !urlFocada, nova != "about:blank" {
                urlDigitada = nova
            }
        }
        .confirmationDialog("Apagar este portal?", isPresented: $confirmandoDelete) {
            Button("Apagar portal", role: .destructive) { Task { await store.deleteNode(node.id) } }
        } message: {
            Text("A página será removida do canvas.")
        }
    }

    // MARK: - Barra

    private var barra: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .help("Arraste para mover o portal")

            Button { controller.voltar() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(controller.podeVoltar ? ColmeiaCanvasTheme.ink : ColmeiaCanvasTheme.mutedInk.opacity(0.4))
            .disabled(!controller.podeVoltar)

            Button { controller.avancar() } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(controller.podeAvancar ? ColmeiaCanvasTheme.ink : ColmeiaCanvasTheme.mutedInk.opacity(0.4))
            .disabled(!controller.podeAvancar)

            Button { controller.recarregar() } label: {
                Image(systemName: controller.carregando ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
            .help(controller.carregando ? "Parar" : "Recarregar")

            TextField("https://…", text: $urlDigitada)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ColmeiaCanvasTheme.ink)
                .focused($urlFocada)
                .onSubmit(navegarDigitada)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(ColmeiaCanvasTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Button { confirmandoDelete = true } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
            .help("Apagar portal")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(ColmeiaCanvasTheme.surfaceRaised)
    }

    /// Título da página quando disponível (o controller já o persistiu via node.update).
    private var tituloVisivel: String? {
        let titulo = node.titulo ?? controller.tituloDaPagina
        guard let titulo, !titulo.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return titulo
    }

    private var portalTimelineEvents: [PortalActivityEvent] {
        Array(store.portalActivities.filter { $0.nodeID == node.id }.suffix(4).reversed())
    }

    private var portalTimeline: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
            ForEach(portalTimelineEvents) { event in
                HStack(spacing: 3) {
                    Text(event.action.rawValue)
                    Text(event.status == "succeeded" ? "✓" : "!")
                            .foregroundStyle(event.status == "succeeded" ? Color.green : Color.red)
                    if let duration = event.durationMs {
                        Text("\(duration)ms")
                            .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(ColmeiaCanvasTheme.surfaceRaised)
        .help("Ações CDP recentes deste portal")
    }

    private func linhaTitulo(_ titulo: String) -> some View {
        Text(titulo)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.bottom, 3)
            .background(ColmeiaCanvasTheme.surfaceRaised)
            .contentShape(Rectangle())
            .gesture(dragGesture)
    }

    private func navegarDigitada() {
        urlFocada = false
        guard let normalizada = PortalURL.normalizar(urlDigitada) else {
            urlDigitada = node.url == "about:blank" ? "" : node.url
            return
        }
        urlDigitada = normalizada
        if normalizada != node.url {
            // navegar portal existente = node.update {url} comum
            store.perform(.nodeUpdate(NodeUpdateOpPayload(
                id: node.id,
                campos: .object(["url": .string(normalizada)])
            )))
        } else {
            controller.recarregar()
        }
    }
}

/// Ponte AppKit: o WKWebView pertence ao PortalController (estado sobrevive a re-renders).
private struct PortalWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Popover simples do "Novo Portal": pede a URL; vazio abre about:blank com foco na barra.
struct NewPortalPopover: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Novo Portal")
                .font(.headline)
            TextField("URL ou busca (vazio = DuckDuckGo)", text: $url)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 320)
                .onSubmit(abrir)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Abrir") { abrir() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func abrir() {
        store.addPortal(url: url)
        dismiss()
    }
}
