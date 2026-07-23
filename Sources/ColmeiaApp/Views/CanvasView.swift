import SwiftUI
import AppKit
import SwiftTerm
import ColmeiaKit

struct CanvasView: View {
    @EnvironmentObject private var store: AppStore

    @State private var panStart: Viewport?
    @State private var magStartZoom: Double?
    @State private var scrollMonitor: Any?
    @State private var keyMonitor: Any?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                GridBackground(viewport: store.viewport)
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture {
                        store.selection = nil
                        store.returnFocusToCanvas()
                    }
                nodeLayer
                if store.ferramentaDesenho != nil {
                    DrawingLayer()
                }
                MinimapView()
                    .frame(width: 180, height: 120)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .clipped()
            .simultaneousGesture(magnificationGesture)
            .onAppear {
                store.canvasSize = geo.size
                installScrollMonitor()
                installKeyMonitor()
            }
            .onDisappear(perform: removeMonitors)
            .onChange(of: geo.size) { _, novo in
                store.canvasSize = novo
            }
        }
    }

    private var visibleWorldRect: CGRect {
        let v = store.viewport
        return CGRect(
            x: v.x, y: v.y,
            width: Double(store.canvasSize.width) / v.zoom,
            height: Double(store.canvasSize.height) / v.zoom
        )
    }

    private var nodeLayer: some View {
        let zoom = store.viewport.zoom
        let visible = visibleWorldRect.insetBy(dx: -80, dy: -80)
        let ordered = store.nodes.values.sorted { ($0.z, $0.id.string) < ($1.z, $1.id.string) }
        return ForEach(ordered, id: \.id) { node in
            let worldFrame = CGRect(x: node.posicao.x, y: node.posicao.y, width: node.tamanho.w, height: node.tamanho.h)
            NodeContainerView(
                node: node,
                zoom: zoom,
                conteudoVisivel: visible.intersects(worldFrame)
            )
            .frame(width: node.tamanho.w, height: node.tamanho.h)
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(
                x: (node.posicao.x - store.viewport.x) * zoom,
                y: (node.posicao.y - store.viewport.y) * zoom
            )
        }
    }

    // MARK: - Gestos

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if panStart == nil { panStart = store.viewport }
                guard var v = panStart else { return }
                v.x -= Double(value.translation.width) / v.zoom
                v.y -= Double(value.translation.height) / v.zoom
                store.setViewport(v)
            }
            .onEnded { _ in panStart = nil }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magStartZoom == nil { magStartZoom = store.viewport.zoom }
                guard let start = magStartZoom else { return }
                let alvo = start * Double(value)
                store.zoom(by: alvo / store.viewport.zoom)
            }
            .onEnded { _ in magStartZoom = nil }
    }

    /// Scroll do trackpad/mouse faz pan; eventos sobre um terminal ficam com o
    /// scrollback do SwiftTerm. O objeto `store` é capturado aqui (não `self`):
    /// @EnvironmentObject não pode ser lido fora do ciclo do body.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        let store = self.store
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window, window.isKeyWindow,
                  let content = window.contentView else { return event }
            let point = content.convert(event.locationInWindow, from: nil)
            if let hit = content.hitTest(point), terminalAncestral(of: hit) != nil {
                return event
            }
            var v = store.viewport
            v.x -= Double(event.scrollingDeltaX) / v.zoom
            v.y -= Double(event.scrollingDeltaY) / v.zoom
            store.setViewport(v)
            return nil
        }
    }

    /// Esc duplo com um terminal focado devolve o foco ao canvas (Apêndice B).
    /// O primeiro Esc segue para o PTY (agentes usam Esc); keyDown do SwiftTerm
    /// não é `open`, então a interceptação é por monitor local.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let store = self.store
        let lastEscBox = LastEscBox()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53,
                  let window = event.window,
                  let responder = window.firstResponder as? NSView,
                  terminalAncestral(of: responder) != nil else {
                return event
            }
            if let last = lastEscBox.value, Date().timeIntervalSince(last) < 0.5 {
                lastEscBox.value = nil
                window.makeFirstResponder(nil)
                store.returnFocusToCanvas()
                return nil
            }
            lastEscBox.value = Date()
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

private final class LastEscBox {
    var value: Date?
}

private func terminalAncestral(of view: NSView) -> TerminalView? {
    var atual: NSView? = view
    while let v = atual {
        if let terminal = v as? TerminalView { return terminal }
        atual = v.superview
    }
    return nil
}

/// Grade sutil indicando escala (§18.2).
struct GridBackground: View {
    let viewport: Viewport

    var body: some View {
        Canvas { context, size in
            let step = 100.0 * viewport.zoom
            guard step > 8 else { return }
            let offsetX = step - (viewport.x * viewport.zoom).truncatingRemainder(dividingBy: step)
            let offsetY = step - (viewport.y * viewport.zoom).truncatingRemainder(dividingBy: step)
            var path = Path()
            var x = offsetX.truncatingRemainder(dividingBy: step)
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y = offsetY.truncatingRemainder(dividingBy: step)
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(.primary.opacity(0.06)), lineWidth: 1)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Chrome comum: arrasto (node.move), redimensionamento (node.resize), seleção.
struct NodeContainerView: View {
    let node: Node
    let zoom: Double
    let conteudoVisivel: Bool

    @EnvironmentObject private var store: AppStore
    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: CGSize = .zero

    var body: some View {
        content
            .overlay(alignment: .bottomTrailing) { resizeHandle }
            .overlay {
                if store.selection == node.id {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor, lineWidth: 2 / zoom)
                }
            }
            .offset(dragOffset)
            .onTapGesture {
                store.selection = node.id
            }
    }

    @ViewBuilder
    private var content: some View {
        switch node {
        case .terminal(let terminal):
            TerminalNodeView(
                node: terminal,
                controller: store.terminalController(for: terminal.id),
                zoom: zoom,
                conteudoVisivel: conteudoVisivel,
                dragGesture: moveGesture
            )
        case .nota(let nota):
            NotaNodeView(node: nota, controller: store.notaController(for: nota), dragGesture: moveGesture)
        case .desenho(let desenho):
            DesenhoNodeView(node: desenho, dragGesture: moveGesture)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                store.selection = node.id
                dragOffset = CGSize(
                    width: value.translation.width / zoom,
                    height: value.translation.height / zoom
                )
            }
            .onEnded { value in
                dragOffset = .zero
                let destino = Ponto(
                    x: node.posicao.x + Double(value.translation.width) / zoom,
                    y: node.posicao.y + Double(value.translation.height) / zoom
                )
                store.moveNode(node.id, to: destino)
            }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        resizeDelta = value.translation
                    }
                    .onEnded { value in
                        resizeDelta = .zero
                        let tamanho = Tamanho(
                            w: max(160, node.tamanho.w + Double(value.translation.width) / zoom),
                            h: max(100, node.tamanho.h + Double(value.translation.height) / zoom)
                        )
                        store.resizeNode(node.id, to: tamanho)
                    }
            )
    }
}

/// Minimapa com indicador de viewport e pontos coloridos por estado (§18.2, PODE).
struct MinimapView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Canvas { context, size in
            let nodes = Array(store.nodes.values)
            guard !nodes.isEmpty else { return }
            var world = nodes.reduce(CGRect.null) { acc, node in
                acc.union(CGRect(x: node.posicao.x, y: node.posicao.y, width: node.tamanho.w, height: node.tamanho.h))
            }
            let viewRect = CGRect(
                x: store.viewport.x, y: store.viewport.y,
                width: Double(store.canvasSize.width) / store.viewport.zoom,
                height: Double(store.canvasSize.height) / store.viewport.zoom
            )
            world = world.union(viewRect).insetBy(dx: -200, dy: -200)
            let scale = min(size.width / world.width, size.height / world.height)
            func map(_ rect: CGRect) -> CGRect {
                CGRect(
                    x: (rect.minX - world.minX) * scale,
                    y: (rect.minY - world.minY) * scale,
                    width: max(2, rect.width * scale),
                    height: max(2, rect.height * scale)
                )
            }
            for node in nodes {
                let rect = map(CGRect(x: node.posicao.x, y: node.posicao.y, width: node.tamanho.w, height: node.tamanho.h))
                let cor: SwiftUI.Color
                if case .terminal = node, let estado = store.terminalControllers[node.id]?.estado {
                    cor = EstadoStyle.cor(estado)
                } else {
                    cor = .secondary
                }
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(cor.opacity(0.8)))
            }
            context.stroke(Path(map(viewRect)), with: .color(.accentColor), lineWidth: 1)
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .opacity(0.9)
        .allowsHitTesting(false)
    }
}

/// Cores por estado (§18.3).
enum EstadoStyle {
    static func cor(_ estado: SessionEstado?) -> SwiftUI.Color {
        switch estado {
        case .rodando: return .green
        case .iniciando: return .teal
        case .esperandoHumano: return .orange
        case .aprovacaoPendente: return .red
        case .ociosa: return .secondary
        case .encerrada, .morta, .none: return .gray
        }
    }

    static func rotulo(_ estado: SessionEstado?) -> String {
        estado?.rawValue ?? "sem sessão"
    }
}
