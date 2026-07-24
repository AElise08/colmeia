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

    var body: some View {
        VStack(spacing: 0) {
            barra
            if let titulo = tituloVisivel {
                linhaTitulo(titulo)
            }
            PortalWebView(webView: controller.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Recarregar") { controller.recarregar() }
            Button("Apagar portal", role: .destructive) {
                Task { await store.deleteNode(node.id) }
            }
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
    }

    // MARK: - Barra

    private var barra: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .help("Arraste para mover o portal")

            Button { controller.voltar() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(controller.podeVoltar ? Color.primary : Color.secondary.opacity(0.4))
            .disabled(!controller.podeVoltar)

            Button { controller.avancar() } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(controller.podeAvancar ? Color.primary : Color.secondary.opacity(0.4))
            .disabled(!controller.podeAvancar)

            Button { controller.recarregar() } label: {
                Image(systemName: controller.carregando ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .help(controller.carregando ? "Parar" : "Recarregar")

            TextField("https://…", text: $urlDigitada)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .focused($urlFocada)
                .onSubmit(navegarDigitada)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.thinMaterial)
    }

    /// Título da página quando disponível (o controller já o persistiu via node.update).
    private var tituloVisivel: String? {
        let titulo = node.titulo ?? controller.tituloDaPagina
        guard let titulo, !titulo.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return titulo
    }

    private func linhaTitulo(_ titulo: String) -> some View {
        Text(titulo)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.bottom, 3)
            .background(.thinMaterial)
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
            TextField("https://…  (vazio = página em branco)", text: $url)
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
