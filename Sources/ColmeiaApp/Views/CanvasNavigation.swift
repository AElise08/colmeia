import SwiftUI
import AppKit
import WebKit
import SwiftTerm
import ColmeiaKit

/// Navegação universal do canvas, estilo Figma (§18.2).
///
/// O problema real: WKWebView (portal) e SwiftTerm engolem scroll/pinch/drag —
/// gestos SwiftUI no fundo só funcionam sobre área vazia; com um portal grande
/// aberto a usuária não consegue nem pan nem zoom. A saída é interceptar NSEvents
/// com local monitors ANTES do dispatch aos NSViews:
///
/// - pinch (.magnify) em QUALQUER lugar do canvas → zoom ancorado no cursor
///   (consumido: o `allowsMagnification` do WKWebView não rouba o gesto);
/// - ⌥-scroll em qualquer lugar → pan; ⌘-scroll → zoom ancorado no cursor;
/// - scroll PURO sobre página/terminal/nota → segue NATIVO (não consumimos);
///   sobre o fundo → pan (comportamento clássico do canvas mantido);
/// - Espaço segurado (fora de digitação) → modo mão: cursor openHand, qualquer
///   drag vira pan; o mouseDown é consumido para o clique não vazar (não foca
///   nem seleciona o nó por baixo).
///
/// A view AppKit é invisível ao hit-testing (`hitTest → nil`) e existe para:
/// (1) instalar/remover os monitors exatamente uma vez por janela
///     (`viewDidMoveToWindow`);
/// (2) converter janela→canvas com `convert(_:from:)` numa view FLIPPED — mesmo
///     topo-esquerda do CanvasSpace/scaleEffect do SwiftUI (ver CanvasMath).
struct CanvasEventBridge: NSViewRepresentable {
    let store: AppStore
    let onPointerMove: (Ponto) -> Void

    func makeNSView(context: Context) -> NavegacaoMonitorView {
        let view = NavegacaoMonitorView()
        view.store = store
        view.onPointerMove = onPointerMove
        return view
    }

    func updateNSView(_ nsView: NavegacaoMonitorView, context: Context) {
        nsView.store = store
        nsView.onPointerMove = onPointerMove
    }
}

final class NavegacaoMonitorView: NSView {
    weak var store: AppStore?
    var onPointerMove: ((Ponto) -> Void)?

    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?

    /// Modo mão (Espaço segurado) e o drag de pan em curso.
    private var modoMao = false
    private var maoArrastando = false
    private var maoBase: Viewport?
    private var maoOrigemTela: CGPoint = .zero
    private var cursorForcado = false

    private static let teclaEspaco: UInt16 = 49
    /// COLMEIA_NAV_DEBUG=1 → traça decisões de scroll/tecla no stderr (smoke/diagnóstico).
    private static let debug = ProcessInfo.processInfo.environment["COLMEIA_NAV_DEBUG"] == "1"

    private static func trace(_ msg: @autoclosure () -> String) {
        guard debug else { return }
        FileHandle.standardError.write(Data(("nav: " + msg() + "\n").utf8))
    }

    /// Coordenadas já em topo-esquerda: `convert(_:from:)` devolve direto o espaço
    /// do canvas (o mesmo do CanvasSpace do SwiftUI).
    override var isFlipped: Bool { true }
    /// Transparente a eventos AppKit — a view não participa do hit-testing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            teardown()
        } else {
            install()
        }
    }

    deinit {
        // Teardown normal acontece em viewDidMoveToWindow(nil); rede de segurança.
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Instalação (uma vez por janela; remoção no teardown)

    private func install() {
        guard monitors.isEmpty else { return }
        window?.acceptsMouseMovedEvents = true
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.publishPointer(event)
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                self?.handleMagnify(event) ?? event
            },
            NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event) ?? event
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event) ?? event
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                self?.handleKeyUp(event) ?? event
            },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handleMouseDown(event) ?? event
            },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
                self?.handleMouseDragged(event) ?? event
            },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.handleMouseUp(event) ?? event
            },
            NSEvent.addLocalMonitorForEvents(matching: .cursorUpdate) { [weak self] event in
                self?.handleCursorUpdate(event) ?? event
            },
        ].compactMap { $0 }
        // Perder o foco da janela com Espaço segurado (⌘Tab…) não pode deixar o
        // modo mão preso: o keyUp iria para outro app.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sairDoModoMao() }
        }
    }

    private func teardown() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        sairDoModoMao()
    }

    /// Ponto do evento em coordenadas da NOSSA janela; nil quando o evento
    /// pertence a OUTRA janela (sheet/popover — não é nosso). Evento sem janela
    /// (app inativo / sintético) traz locationInWindow em coordenadas de TELA.
    private func pontoNaJanela(_ event: NSEvent) -> CGPoint? {
        guard let janela = window else { return nil }
        if let evWindow = event.window {
            guard evWindow === janela else { return nil }
            return event.locationInWindow
        }
        return janela.convertPoint(fromScreen: event.locationInWindow)
    }

    /// Ponto do evento em coordenadas do canvas (topo-esquerda), ou nil quando o
    /// evento não é desta janela / cai fora do canvas (toolbar, floor bar, sheets).
    private func pontoNoCanvas(_ event: NSEvent) -> CGPoint? {
        guard let pontoJanela = pontoNaJanela(event) else { return nil }
        let p = convert(pontoJanela, from: nil)
        guard bounds.contains(p) else { return nil }
        return p
    }

    private func publishPointer(_ event: NSEvent) {
        guard let p = pontoNoCanvas(event) else { return }
        onPointerMove?(Ponto(x: p.x, y: p.y))
    }

    // MARK: - Pinch → zoom ancorado no cursor

    private func handleMagnify(_ event: NSEvent) -> NSEvent? {
        guard let store, let p = pontoNoCanvas(event) else { return event }
        let fator = 1 + Double(event.magnification)
        if fator > 0 {
            store.zoom(by: fator, ancoraTela: Ponto(x: p.x, y: p.y))
        }
        return nil // consumido — o ponto sob o cursor permanece sob o cursor
    }

    // MARK: - Scroll: ⌥ = pan, ⌘ = zoom no cursor, puro = nativo nos nós / pan no fundo

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard let store, let janela = window, let p = pontoNoCanvas(event) else {
            Self.trace("scroll fora do canvas (window=\(event.window != nil))")
            return event
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        Self.trace("scroll p=\(Int(p.x)),\(Int(p.y)) d=\(event.scrollingDeltaX),\(event.scrollingDeltaY) mods=\(mods.rawValue)")
        if mods.contains(.command) {
            // ⌘-scroll = zoom ancorado no cursor; scroll-up (deltaY > 0) amplia.
            let delta = event.hasPreciseScrollingDeltas
                ? Double(event.scrollingDeltaY)
                : Double(event.scrollingDeltaY) * 10
            if delta != 0 {
                store.zoom(by: exp2(delta / 250), ancoraTela: Ponto(x: p.x, y: p.y))
            }
            return nil
        }
        if mods.contains(.option) {
            store.panBy(telaDX: Double(event.scrollingDeltaX), telaDY: Double(event.scrollingDeltaY))
            return nil
        }
        // Sem modificador dentro de página/terminal/nota: o scroll é DELES — a
        // página rola, o scrollback do terminal rola. Não roubar.
        if let content = janela.contentView, let pontoJanela = pontoNaJanela(event),
           let hit = content.hitTest(content.convert(pontoJanela, from: nil)),
           Self.consomeScroll(hit) {
            Self.trace("scroll nativo: hit=\(Self.cadeia(hit))")
            return event
        }
        // Fundo vazio: two-finger scroll = pan (comportamento clássico mantido).
        store.panBy(telaDX: Double(event.scrollingDeltaX), telaDY: Double(event.scrollingDeltaY))
        return nil
    }

    /// Views cujo scroll nativo não deve ser roubado: terminal (scrollback do
    /// SwiftTerm), webview (página do portal), NSScrollView/NSTextView (nota).
    private static func consomeScroll(_ view: NSView) -> Bool {
        var atual: NSView? = view
        while let v = atual {
            if v is TerminalView || v is WKWebView || v is NSScrollView || v is NSTextView {
                return true
            }
            atual = v.superview
        }
        return false
    }

    private static func cadeia(_ view: NSView) -> String {
        var nomes: [String] = []
        var atual: NSView? = view
        while let v = atual, nomes.count < 6 {
            nomes.append(String(describing: type(of: v)))
            atual = v.superview
        }
        return nomes.joined(separator: "<")
    }

    // MARK: - Espaço segurado = modo mão

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // `event.window == nil` acontece com o app inativo (eventos sintéticos /
        // reentrada); tratar como "nossa janela" é inofensivo — o pan em si ainda
        // exige mouse dentro do canvas. Janela DIFERENTE (sheet/popover) passa.
        guard event.keyCode == Self.teclaEspaco, let janela = window,
              event.window == nil || event.window === janela else { return event }
        if modoMao { return nil } // repeats do Espaço enquanto o modo está ativo
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty, !Self.focoEstaDigitando(janela) else { return event }
        // Espaço com nó selecionado pertence ao atalho "zoom no nó" do bridge
        // tmux. Devolver o evento impede que a ordem dos monitors transforme o
        // mesmo keyDown em modo mão antes que o bridge o consuma.
        if store?.selection != nil { return event }
        modoMao = true
        aplicarCursor()
        return nil
    }

    private func handleKeyUp(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == Self.teclaEspaco, modoMao else { return event }
        modoMao = false
        // Um drag em curso segue até o mouseUp (como no Figma); só o cursor volta.
        aplicarCursor()
        return nil
    }

    /// Não interferir em quem digita Espaço: field editor (NSText/NSTextView —
    /// TextField/TextEditor), terminal focado (agentes usam Espaço!) e webview
    /// focado (formulários; Espaço também rola a página, como num browser).
    private static func focoEstaDigitando(_ janela: NSWindow) -> Bool {
        guard let responder = janela.firstResponder else { return false }
        if responder is NSText || responder is NSTextView { return true }
        guard let view = responder as? NSView else { return false }
        var atual: NSView? = view
        while let v = atual {
            if v is TerminalView || v is WKWebView || v is NSTextView { return true }
            atual = v.superview
        }
        return false
    }

    private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        publishPointer(event)
        guard modoMao, let store, let p = pontoNoCanvas(event) else { return event }
        maoArrastando = true
        maoBase = store.viewport
        maoOrigemTela = p
        aplicarCursor()
        return nil // o clique não chega ao nó por baixo (não foca, não seleciona)
    }

    private func handleMouseDragged(_ event: NSEvent) -> NSEvent? {
        publishPointer(event)
        guard maoArrastando, let store, let base = maoBase,
              let pontoJanela = pontoNaJanela(event) else { return event }
        // Sem clamp ao bounds: o drag pode sair do canvas e continuar valendo.
        let p = convert(pontoJanela, from: nil)
        var v = base
        v.x = base.x - Double(p.x - maoOrigemTela.x) / base.zoom
        v.y = base.y - Double(p.y - maoOrigemTela.y) / base.zoom
        store.setViewport(v)
        return nil
    }

    private func handleMouseUp(_ event: NSEvent) -> NSEvent? {
        guard maoArrastando else { return event }
        maoArrastando = false
        maoBase = nil
        aplicarCursor()
        return nil
    }

    // MARK: - Cursor do modo mão

    /// Consumir cursorUpdate enquanto o modo mão está ativo impede a view por
    /// baixo (webview/campo de texto) de repor pointer/I-beam.
    private func handleCursorUpdate(_ event: NSEvent) -> NSEvent? {
        guard modoMao || maoArrastando else { return event }
        aplicarCursor()
        return nil
    }

    private func aplicarCursor() {
        if maoArrastando {
            NSCursor.closedHand.set()
            cursorForcado = true
        } else if modoMao {
            NSCursor.openHand.set()
            cursorForcado = true
        } else if cursorForcado {
            NSCursor.arrow.set()
            cursorForcado = false
        }
    }

    private func sairDoModoMao() {
        modoMao = false
        maoArrastando = false
        maoBase = nil
        aplicarCursor()
    }
}
