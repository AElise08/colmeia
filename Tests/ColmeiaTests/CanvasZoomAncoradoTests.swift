import Foundation
import Testing
@testable import ColmeiaKit

/// §18.2 navegação universal — a invariante do zoom ancorado: o ponto de MUNDO
/// sob a âncora de TELA permanece no mesmo ponto de tela após o zoom.
@Suite("CanvasMath — zoom ancorado")
struct CanvasZoomAncoradoTests {
    private func telaDaAncoraAposZoom(_ antes: Viewport, _ depois: Viewport, ancora: Ponto) -> Ponto {
        let mundo = CanvasMath.telaParaMundo(ancora, viewport: antes)
        return CanvasMath.mundoParaTela(mundo, viewport: depois)
    }

    @Test func ancoraPermaneceNoMesmoPontoDeTelaPorFator() {
        let antes = Viewport(x: 120, y: -40, zoom: 1.0)
        let ancora = Ponto(x: 300, y: 220) // cursor em tela
        let depois = CanvasMath.zoomAncorado(viewport: antes, fator: 1.6, ancoraTela: ancora)
        #expect(abs(depois.zoom - 1.6) < 1e-12)
        let tela = telaDaAncoraAposZoom(antes, depois, ancora: ancora)
        #expect(abs(tela.x - ancora.x) < 1e-9)
        #expect(abs(tela.y - ancora.y) < 1e-9)
    }

    @Test func ancoraPermaneceNoMesmoPontoDeTelaPorAlvoAbsoluto() {
        let antes = Viewport(x: -350, y: 900, zoom: 2.5)
        let ancora = Ponto(x: 17, y: 583)
        let depois = CanvasMath.zoomAncorado(viewport: antes, zoomAlvo: 0.75, ancoraTela: ancora)
        #expect(abs(depois.zoom - 0.75) < 1e-12)
        let tela = telaDaAncoraAposZoom(antes, depois, ancora: ancora)
        #expect(abs(tela.x - ancora.x) < 1e-9)
        #expect(abs(tela.y - ancora.y) < 1e-9)
    }

    @Test func roundtripFatorInversoVoltaAoViewportOriginal() {
        let original = Viewport(x: -35, y: 80, zoom: 1.25)
        let ancora = Ponto(x: 512, y: 384)
        let ida = CanvasMath.zoomAncorado(viewport: original, fator: 2.0, ancoraTela: ancora)
        let volta = CanvasMath.zoomAncorado(viewport: ida, fator: 0.5, ancoraTela: ancora)
        #expect(abs(volta.x - original.x) < 1e-9)
        #expect(abs(volta.y - original.y) < 1e-9)
        #expect(abs(volta.zoom - original.zoom) < 1e-12)
    }

    @Test func clampNoLimiteAindaAncora() {
        let antes = Viewport(x: 0, y: 0, zoom: 2.0)
        let ancora = Ponto(x: 100, y: 50)
        let ampliado = CanvasMath.zoomAncorado(viewport: antes, fator: 100, ancoraTela: ancora)
        #expect(ampliado.zoom == Viewport.zoomRange.upperBound)
        let telaMax = telaDaAncoraAposZoom(antes, ampliado, ancora: ancora)
        #expect(abs(telaMax.x - ancora.x) < 1e-9)
        #expect(abs(telaMax.y - ancora.y) < 1e-9)

        let reduzido = CanvasMath.zoomAncorado(viewport: antes, fator: 0.001, ancoraTela: ancora)
        #expect(reduzido.zoom == Viewport.zoomRange.lowerBound)
        let telaMin = telaDaAncoraAposZoom(antes, reduzido, ancora: ancora)
        #expect(abs(telaMin.x - ancora.x) < 1e-9)
        #expect(abs(telaMin.y - ancora.y) < 1e-9)
    }

    @Test func entradaInvalidaDevolveViewportIntocado() {
        let v = Viewport(x: 10, y: 20, zoom: 1.5)
        let ancora = Ponto(x: 50, y: 50)
        #expect(CanvasMath.zoomAncorado(viewport: v, fator: 0, ancoraTela: ancora) == v)
        #expect(CanvasMath.zoomAncorado(viewport: v, fator: -1, ancoraTela: ancora) == v)
        #expect(CanvasMath.zoomAncorado(viewport: v, fator: .nan, ancoraTela: ancora) == v)
        #expect(CanvasMath.zoomAncorado(viewport: v, zoomAlvo: .infinity, ancoraTela: ancora) == v)
        #expect(CanvasMath.zoomAncorado(viewport: v, zoomAlvo: 2, ancoraTela: Ponto(x: .nan, y: 0)) == v)
    }

    /// ⌘+/⌘−/⌘0: âncora no CENTRO da viewport — o ponto de mundo no centro não muda.
    @Test func ancoraNoCentroMantemOCentroDoMundo() {
        let antes = Viewport(x: 200, y: -100, zoom: 0.8)
        let centroTela = Ponto(x: 1200.0 / 2, y: 800.0 / 2)
        let centroMundoAntes = CanvasMath.telaParaMundo(centroTela, viewport: antes)
        let depois = CanvasMath.zoomAncorado(viewport: antes, zoomAlvo: 1.0, ancoraTela: centroTela)
        let centroMundoDepois = CanvasMath.telaParaMundo(centroTela, viewport: depois)
        #expect(abs(centroMundoDepois.x - centroMundoAntes.x) < 1e-9)
        #expect(abs(centroMundoDepois.y - centroMundoAntes.y) < 1e-9)
        #expect(depois.zoom == 1.0)
    }
}
