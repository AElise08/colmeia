import Foundation
import AppKit
import WebKit
import ColmeiaKit

/// Normalização de URL digitada no portal: sem esquema ganha https://; about:blank
/// passa; espaço ou lixo → nil (o campo volta ao valor anterior).
enum PortalURL {
    static func normalizar(_ bruto: String) -> String? {
        let aparado = bruto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !aparado.isEmpty else { return nil }
        if aparado == "about:blank" { return aparado }
        let lower = aparado.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: aparado) != nil ? aparado : nil
        }
        guard !aparado.contains(" ") else { return nil }
        let candidata = "https://" + aparado
        return URL(string: candidata) != nil ? candidata : nil
    }
}

/// Um por PortalNode. Dono do WKWebView (retido enquanto o nó existir — navegação e
/// scroll sobrevivem a re-renders) e da ponte documento ⟷ navegador:
/// - documento → webview: `navigateIfNeeded` com guarda anti-loop (só navega se a URL
///   do eco difere da atual/em voo do webview);
/// - webview → documento: navegação interna (link, redirect) e título viram
///   `node.update` via callbacks.
///
/// NOTA: é um navegador EMBUTIDO (WKWebView), sem o perfil/logins do Chrome da
/// usuária. `WKWebsiteDataStore.default()` persiste cookies/logins DO portal entre
/// sessões do app.
@MainActor
final class PortalController: NSObject, ObservableObject {
    let nodeID: ULID

    @Published private(set) var tituloDaPagina: String?
    @Published private(set) var urlAtual: String?
    @Published private(set) var podeVoltar = false
    @Published private(set) var podeAvancar = false
    @Published private(set) var carregando = false

    /// Navegação que partiu do próprio webview (link clicado, redirect) → node.update {url}.
    var onURLNavegada: ((String) -> Void)?
    /// Título da página disponível → node.update {titulo}.
    var onTitulo: ((String) -> Void)?

    private(set) lazy var webView: WKWebView = makeWebView()
    private var observers: [NSKeyValueObservation] = []
    /// Última URL pedida por nós (documento → webview) — o eco dela não re-navega.
    private var navegacaoPedida: String?

    init(nodeID: ULID) {
        self.nodeID = nodeID
        super.init()
    }

    deinit {
        for observer in observers { observer.invalidate() }
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // Cookies/logins do portal persistem entre sessões do app (não é o Chrome).
        config.websiteDataStore = .default()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 480), configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        observers = [
            view.observe(\.title, options: [.new]) { [weak self] webView, _ in
                let titulo = webView.title
                Task { @MainActor in self?.tituloMudou(titulo) }
            },
            view.observe(\.url, options: [.new]) { [weak self] webView, _ in
                let url = webView.url?.absoluteString
                Task { @MainActor in self?.urlMudou(url) }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                let pode = webView.canGoBack
                Task { @MainActor in self?.podeVoltar = pode }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                let pode = webView.canGoForward
                Task { @MainActor in self?.podeAvancar = pode }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                let esta = webView.isLoading
                Task { @MainActor in self?.carregando = esta }
            },
        ]
        return view
    }

    // MARK: - Documento → webview (anti-loop)

    /// Navega apenas se a URL difere da atual do webview E não é a que já pedimos
    /// (navegação em voo) — o eco do próprio `node.update {url}` cai aqui e é no-op.
    func navigateIfNeeded(to urlString: String) {
        guard !urlString.isEmpty else { return }
        if webView.url?.absoluteString == urlString {
            navegacaoPedida = nil
            return
        }
        if navegacaoPedida == urlString { return }
        guard let url = URL(string: urlString) else { return }
        navegacaoPedida = urlString
        webView.load(URLRequest(url: url))
    }

    func voltar() { webView.goBack() }
    func avancar() { webView.goForward() }

    func recarregar() {
        if carregando {
            webView.stopLoading()
        } else if webView.url != nil {
            webView.reload()
        }
    }

    // MARK: - Webview → documento

    private func urlMudou(_ nova: String?) {
        urlAtual = nova
        guard let nova, !nova.isEmpty else { return }
        if nova == navegacaoPedida {
            // navegação que o documento pediu — a URL já está no nó
            navegacaoPedida = nil
            return
        }
        onURLNavegada?(nova)
    }

    private func tituloMudou(_ novo: String?) {
        tituloDaPagina = novo
        guard let novo, !novo.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onTitulo?(novo)
    }
}
