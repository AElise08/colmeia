import Foundation
import Testing
@testable import ColmeiaKit

@Suite("CanvasMath — matemática do drag e conexões")
struct CanvasMathTests {
    @Test func dragEBaseMaisTranslacaoSobreZoom() {
        let destino = CanvasMath.destinoDoDrag(
            base: Ponto(x: 100, y: 200),
            translacaoTela: Ponto(x: 50, y: -30),
            zoom: 1.0
        )
        #expect(destino == Ponto(x: 150, y: 170))
    }

    @Test func dragDivideTranslacaoPeloZoom() {
        let ampliado = CanvasMath.destinoDoDrag(
            base: Ponto(x: 0, y: 0),
            translacaoTela: Ponto(x: 100, y: 100),
            zoom: 2.0
        )
        #expect(ampliado == Ponto(x: 50, y: 50))

        let reduzido = CanvasMath.destinoDoDrag(
            base: Ponto(x: 10, y: 10),
            translacaoTela: Ponto(x: 100, y: -100),
            zoom: 0.5
        )
        #expect(reduzido == Ponto(x: 210, y: -190))
    }

    @Test func dragNaoDependeDaPosicaoCorrente() {
        // A regressão original: translação aplicada sobre posição JÁ atualizada
        // durante o gesto → dupla aplicação → nó teleporta. Com a base fixa,
        // n atualizações da mesma translação dão sempre o mesmo destino.
        let base = Ponto(x: 300, y: 400)
        let translacao = Ponto(x: 42, y: 17)
        let primeira = CanvasMath.destinoDoDrag(base: base, translacaoTela: translacao, zoom: 1.0)
        let repetida = CanvasMath.destinoDoDrag(base: base, translacaoTela: translacao, zoom: 1.0)
        #expect(primeira == repetida)
        #expect(primeira == Ponto(x: 342, y: 417))
    }

    @Test func dragRejeitaZoomInvalido() {
        let p = Ponto(x: 0, y: 0)
        #expect(CanvasMath.destinoDoDrag(base: p, translacaoTela: Ponto(x: 1, y: 1), zoom: 0) == nil)
        #expect(CanvasMath.destinoDoDrag(base: p, translacaoTela: Ponto(x: 1, y: 1), zoom: -1) == nil)
        #expect(CanvasMath.destinoDoDrag(base: p, translacaoTela: Ponto(x: 1, y: 1), zoom: .nan) == nil)
    }

    @Test func dragRejeitaDestinoInsano() {
        let p = Ponto(x: 0, y: 0)
        #expect(CanvasMath.destinoDoDrag(base: p, translacaoTela: Ponto(x: .nan, y: 0), zoom: 1) == nil)
        #expect(CanvasMath.destinoDoDrag(base: p, translacaoTela: Ponto(x: .infinity, y: 0), zoom: 1) == nil)
        #expect(CanvasMath.destinoDoDrag(
            base: Ponto(x: 999_999, y: 0),
            translacaoTela: Ponto(x: 2, y: 0),
            zoom: 1
        ) == nil)
    }

    @Test func posicaoSanaAceitaLimitesERejeitaAlem() {
        #expect(CanvasMath.posicaoSana(Ponto(x: 1_000_000, y: -1_000_000)))
        #expect(!CanvasMath.posicaoSana(Ponto(x: 1_000_001, y: 0)))
        #expect(!CanvasMath.posicaoSana(Ponto(x: 0, y: -1_000_001)))
        #expect(!CanvasMath.posicaoSana(Ponto(x: .nan, y: 0)))
        #expect(!CanvasMath.posicaoSana(Ponto(x: 0, y: .infinity)))
    }

    @Test func telaMundoRoundtrip() {
        let viewport = Viewport(x: 100, y: -50, zoom: 2.0)
        let tela = Ponto(x: 30, y: 40)
        let mundo = CanvasMath.telaParaMundo(tela, viewport: viewport)
        #expect(mundo == Ponto(x: 115, y: -30))
        let volta = CanvasMath.mundoParaTela(mundo, viewport: viewport)
        #expect(abs(volta.x - tela.x) < 1e-9)
        #expect(abs(volta.y - tela.y) < 1e-9)
    }

    @Test func ancorasDeConexaoNasBordas() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 300, y: 0, width: 100, height: 100)
        let (deA, emB) = CanvasMath.ancorasDeConexao(de: a, para: b)
        #expect(deA == CGPoint(x: 100, y: 50))
        #expect(emB == CGPoint(x: 300, y: 50))
    }

    @Test func pontoDeBordaDiagonalELimites() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let diagonal = CanvasMath.pontoDeBorda(rect: rect, em: CGPoint(x: 200, y: 200))
        #expect(abs(diagonal.x - 100) < 1e-9)
        #expect(abs(diagonal.y - 100) < 1e-9)
        let mesmoCentro = CanvasMath.pontoDeBorda(rect: rect, em: CGPoint(x: 50, y: 50))
        #expect(mesmoCentro == CGPoint(x: 50, y: 50))
    }
}
