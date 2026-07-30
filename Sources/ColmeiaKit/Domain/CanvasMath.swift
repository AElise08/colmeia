#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Matemática pura do canvas (drag, conversão tela↔mundo, âncoras de conexão).
/// Vive no Kit para ser testável fora do target SwiftUI; não participa do wire.
public enum CanvasMath {
    /// Posições fora de ±1e6 (ou não-finitas) são rejeitadas — §18.2 e sanidade do documento.
    public static let limitePosicao: Double = 1_000_000

    public static func posicaoSana(_ p: Ponto) -> Bool {
        p.x.isFinite && p.y.isFinite && abs(p.x) <= limitePosicao && abs(p.y) <= limitePosicao
    }

    /// Padrão correto do drag: base capturada no início do gesto + translação de TELA
    /// (espaço fixo do canvas, nunca o espaço local do nó que se move) dividida pelo zoom.
    /// Retorna nil quando o resultado não é são (zoom inválido, NaN, além do limite).
    public static func destinoDoDrag(base: Ponto, translacaoTela: Ponto, zoom: Double) -> Ponto? {
        guard zoom.isFinite, zoom > 0 else { return nil }
        let destino = Ponto(
            x: base.x + translacaoTela.x / zoom,
            y: base.y + translacaoTela.y / zoom
        )
        return posicaoSana(destino) ? destino : nil
    }

    public static func telaParaMundo(_ p: Ponto, viewport: Viewport) -> Ponto {
        Ponto(x: viewport.x + p.x / viewport.zoom, y: viewport.y + p.y / viewport.zoom)
    }

    public static func mundoParaTela(_ p: Ponto, viewport: Viewport) -> Ponto {
        Ponto(x: (p.x - viewport.x) * viewport.zoom, y: (p.y - viewport.y) * viewport.zoom)
    }

    // MARK: - Texto solto (§15.2)

    /// Tamanho inicial deliberadamente compacto para um texto solto. O texto é
    /// um nó de desenho para poder mover/selecionar/redimensionar, mas não deve
    /// nascer como um cartão vazio; estas dimensões formam apenas sua área de
    /// layout/hit-test. A métrica é estável e não depende de AppKit, portanto é
    /// segura para documento e testes.
    public static func tamanhoInicialDeTexto(_ texto: String) -> Tamanho {
        let linhas = texto.split(separator: "\n", omittingEmptySubsequences: false)
        let maiorLinha = linhas.map { $0.count }.max() ?? 0
        return Tamanho(
            w: max(32, min(720, Double(maiorLinha) * 8.2 + 12)),
            h: max(24, min(480, Double(max(linhas.count, 1)) * 19 + 6))
        )
    }

    // MARK: - Zoom ancorado (§18.2 — navegação universal)

    /// Viewport com `zoomAlvo` (clampado a `Viewport.zoomRange`) mantendo o ponto de
    /// MUNDO sob a âncora de TELA no mesmo ponto de tela — estilo Figma: pinch e
    /// ⌘-scroll ancoram no cursor; ⌘+/⌘−/⌘0 ancoram no centro da viewport.
    /// Entrada inválida (alvo/âncora não-finitos, alvo ≤ 0) devolve o viewport intocado.
    public static func zoomAncorado(viewport: Viewport, zoomAlvo: Double, ancoraTela: Ponto) -> Viewport {
        guard zoomAlvo.isFinite, zoomAlvo > 0,
              ancoraTela.x.isFinite, ancoraTela.y.isFinite else { return viewport }
        let zoom = min(max(zoomAlvo, Viewport.zoomRange.lowerBound), Viewport.zoomRange.upperBound)
        let ancoraMundo = telaParaMundo(ancoraTela, viewport: viewport)
        return Viewport(
            x: ancoraMundo.x - ancoraTela.x / zoom,
            y: ancoraMundo.y - ancoraTela.y / zoom,
            zoom: zoom
        )
    }

    /// Idem, por FATOR multiplicativo (pinch: `1 + magnification`; scroll-zoom: `exp2(Δ/k)`).
    public static func zoomAncorado(viewport: Viewport, fator: Double, ancoraTela: Ponto) -> Viewport {
        guard fator.isFinite, fator > 0 else { return viewport }
        return zoomAncorado(viewport: viewport, zoomAlvo: viewport.zoom * fator, ancoraTela: ancoraTela)
    }

#if canImport(CoreGraphics)
    /// Ponto onde o segmento centro→`direcao` sai do retângulo — âncora de conexão na borda.
    public static func pontoDeBorda(rect: CGRect, em direcao: CGPoint) -> CGPoint {
        let centro = CGPoint(x: rect.midX, y: rect.midY)
        let dx = direcao.x - centro.x
        let dy = direcao.y - centro.y
        guard dx != 0 || dy != 0 else { return centro }
        let tx = dx == 0 ? Double.infinity : (rect.width / 2) / abs(dx)
        let ty = dy == 0 ? Double.infinity : (rect.height / 2) / abs(dy)
        let t = min(tx, ty)
        guard t.isFinite else { return centro }
        return CGPoint(x: centro.x + dx * t, y: centro.y + dy * t)
    }

    /// Âncoras borda-a-borda entre dois nós (coordenadas de mundo).
    public static func ancorasDeConexao(de a: CGRect, para b: CGRect) -> (CGPoint, CGPoint) {
        let centroA = CGPoint(x: a.midX, y: a.midY)
        let centroB = CGPoint(x: b.midX, y: b.midY)
        return (pontoDeBorda(rect: a, em: centroB), pontoDeBorda(rect: b, em: centroA))
    }
#endif
}
