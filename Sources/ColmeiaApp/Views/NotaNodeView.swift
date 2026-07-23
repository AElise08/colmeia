import SwiftUI
import ColmeiaKit

/// §15.1 — Markdown renderizado; edição em texto puro ao focar; cores; `ultima_fonte` visível.
struct NotaNodeView<Drag: Gesture>: View {
    let node: NotaNode
    @ObservedObject var controller: NotaController
    let dragGesture: Drag

    @EnvironmentObject private var store: AppStore
    @FocusState private var editorFocado: Bool

    static var cores: [(nome: String, cor: Color)] {
        [
            ("amarelo", Color(red: 1.0, green: 0.92, blue: 0.6)),
            ("rosa", Color(red: 1.0, green: 0.78, blue: 0.85)),
            ("verde", Color(red: 0.78, green: 0.94, blue: 0.75)),
            ("azul", Color(red: 0.74, green: 0.87, blue: 1.0)),
            ("roxo", Color(red: 0.87, green: 0.8, blue: 1.0)),
        ]
    }

    private var corFundo: Color {
        Self.cores.first { $0.nome == node.cor }?.cor ?? Self.cores[0].cor
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            conteudo
            rodape
        }
        .background(corFundo.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(.system(size: 10))
                .foregroundStyle(.black.opacity(0.5))
            Spacer()
            ForEach(Self.cores, id: \.nome) { item in
                Circle()
                    .fill(item.cor)
                    .stroke(.black.opacity(node.cor == item.nome ? 0.5 : 0.1), lineWidth: 1)
                    .frame(width: 11, height: 11)
                    .onTapGesture {
                        store.perform(.nodeUpdate(NodeUpdateOpPayload(
                            id: node.id,
                            campos: .object(["cor": .string(item.nome)])
                        )))
                    }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.06))
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    @ViewBuilder
    private var conteudo: some View {
        if controller.editando {
            TextEditor(text: Binding(
                get: { controller.texto },
                set: { controller.textoEditado($0) }
            ))
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .focused($editorFocado)
            .padding(4)
            .onChange(of: editorFocado) { _, focado in
                if !focado { terminarEdicao() }
            }
        } else {
            ScrollView {
                Text(markdown)
                    .font(.system(size: 12))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                controller.editando = true
                editorFocado = true
            }
        }
    }

    private var markdown: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: controller.texto, options: options))
            ?? AttributedString(controller.texto)
    }

    private var rodape: some View {
        HStack {
            if let fonte = node.ultimaFonte {
                Text("última escrita: \(nomeFonte(fonte))")
                    .font(.system(size: 8))
                    .foregroundStyle(.black.opacity(0.45))
            }
            Spacer()
            if controller.editando {
                Button("Concluir") { terminarEdicao() }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundStyle(.black.opacity(0.6))
            } else {
                Text("2× clique para editar")
                    .font(.system(size: 8))
                    .foregroundStyle(.black.opacity(0.3))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func nomeFonte(_ author: Author) -> String {
        switch author {
        case .humano(let id): return id == "local" ? "você" : id
        case .agente(let nodeID): return ULID(nodeID).map { store.nodeName($0) } ?? nodeID
        case .sistema: return "sistema"
        }
    }

    private func terminarEdicao() {
        guard controller.editando else { return }
        controller.editando = false
        controller.persist()
        store.perform(.nodeUpdate(NodeUpdateOpPayload(
            id: node.id,
            campos: .object(["ultima_fonte": .string(Author.humanoLocal.rawValue)])
        )))
    }
}

/// Renderização dos traços de um DesenhoNode. Ferramentas de desenho (§15.2) ainda
/// não existem — traços vindos do documento são exibidos.
struct DesenhoNodeView<Drag: Gesture>: View {
    let node: DesenhoNode
    let dragGesture: Drag

    @EnvironmentObject private var store: AppStore

    var body: some View {
        Canvas { context, _ in
            for traco in node.tracos {
                desenhar(traco, in: &context)
            }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .contextMenu {
            Button("Apagar último traço") { store.deleteUltimoTraco(nodeID: node.id) }
                .disabled(node.tracos.isEmpty)
            Button("Apagar desenho", role: .destructive) {
                Task { await store.deleteNode(node.id) }
            }
        }
    }

    private func desenhar(_ traco: Traco, in context: inout GraphicsContext) {
        let cor = Color(hexOuNome: traco.cor)
        let pontos = traco.pontos.map { CGPoint(x: $0.x, y: $0.y) }
        var path = Path()
        switch traco.tipo {
        case .livre, .seta:
            guard let primeiro = pontos.first else { return }
            path.move(to: primeiro)
            for ponto in pontos.dropFirst() {
                path.addLine(to: ponto)
            }
            if traco.tipo == .seta, pontos.count >= 2 {
                let ultimo = pontos[pontos.count - 1]
                let penultimo = pontos[pontos.count - 2]
                let angulo = atan2(ultimo.y - penultimo.y, ultimo.x - penultimo.x)
                let tam = 8.0 + traco.espessura * 2
                for delta in [Double.pi * 0.85, -Double.pi * 0.85] {
                    path.move(to: ultimo)
                    path.addLine(to: CGPoint(
                        x: ultimo.x + cos(angulo + delta) * tam,
                        y: ultimo.y + sin(angulo + delta) * tam
                    ))
                }
            }
        case .retangulo:
            guard pontos.count >= 2 else { return }
            path.addRect(CGRect(origin: pontos[0], size: CGSize(
                width: pontos[1].x - pontos[0].x,
                height: pontos[1].y - pontos[0].y
            )))
        case .elipse:
            guard pontos.count >= 2 else { return }
            path.addEllipse(in: CGRect(origin: pontos[0], size: CGSize(
                width: pontos[1].x - pontos[0].x,
                height: pontos[1].y - pontos[0].y
            )))
        case .texto:
            if let origem = pontos.first {
                context.draw(
                    Text(node.texto ?? "").font(.system(size: 14)).foregroundColor(cor),
                    at: origem,
                    anchor: .topLeading
                )
            }
            return
        }
        context.stroke(path, with: .color(cor), style: StrokeStyle(
            lineWidth: traco.espessura,
            lineCap: .round,
            lineJoin: .round
        ))
    }
}

extension Color {
    init(hexOuNome nome: String) {
        switch nome {
        case "preto": self = .primary
        case "vermelho": self = .red
        case "azul": self = .blue
        case "verde": self = .green
        case "amarelo": self = .yellow
        default:
            if nome.hasPrefix("#"), let valor = UInt64(nome.dropFirst(), radix: 16) {
                self = Color(
                    red: Double((valor >> 16) & 0xFF) / 255,
                    green: Double((valor >> 8) & 0xFF) / 255,
                    blue: Double(valor & 0xFF) / 255
                )
            } else {
                self = .primary
            }
        }
    }
}
