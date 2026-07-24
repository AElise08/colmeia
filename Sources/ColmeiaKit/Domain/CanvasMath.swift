import Foundation
import CoreGraphics

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
}
