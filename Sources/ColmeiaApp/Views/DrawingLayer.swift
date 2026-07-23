import SwiftUI
import ColmeiaKit

/// Camada por cima dos nós enquanto uma ferramenta de desenho está ativa (§15.2).
/// Cada traço completo vira uma op `traco.add` — participa de undo/redo (§7.2).
struct DrawingLayer: View {
    @EnvironmentObject private var store: AppStore
    @State private var pontosTela: [CGPoint] = []

    var body: some View {
        Canvas { context, _ in
            guard let tipo = store.ferramentaDesenho, pontosTela.count >= 2 else { return }
            var path = Path()
            switch tipo {
            case .livre:
                path.move(to: pontosTela[0])
                for p in pontosTela.dropFirst() { path.addLine(to: p) }
            case .seta:
                path.move(to: pontosTela[0])
                path.addLine(to: pontosTela[pontosTela.count - 1])
            case .retangulo:
                path.addRect(rect(pontosTela[0], pontosTela[pontosTela.count - 1]))
            case .elipse:
                path.addEllipse(in: rect(pontosTela[0], pontosTela[pontosTela.count - 1]))
            case .texto:
                return
            }
            context.stroke(
                path,
                with: .color(Color(hexOuNome: store.corTraco).opacity(0.8)),
                style: StrokeStyle(
                    lineWidth: store.espessuraTraco * store.viewport.zoom,
                    lineCap: .round, lineJoin: .round
                )
            )
        }
        .contentShape(Rectangle())
        .gesture(drawGesture)
        .onTapGesture { location in
            if store.ferramentaDesenho == .texto {
                store.textoPendentePonto = toWorld(location)
            }
        }
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard store.ferramentaDesenho != .texto else { return }
                if pontosTela.isEmpty { pontosTela.append(value.startLocation) }
                pontosTela.append(value.location)
            }
            .onEnded { _ in
                defer { pontosTela = [] }
                guard let tipo = store.ferramentaDesenho, tipo != .texto else { return }
                store.finishStroke(worldPoints: pontosTela.map(toWorld), tipo: tipo)
            }
    }

    private func toWorld(_ p: CGPoint) -> Ponto {
        Ponto(
            x: store.viewport.x + Double(p.x) / store.viewport.zoom,
            y: store.viewport.y + Double(p.y) / store.viewport.zoom
        )
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

/// Espessuras/cores mínimas: 3 espessuras, paleta pequena (§15.2).
struct DrawingToolbar: View {
    @EnvironmentObject private var store: AppStore

    private static let ferramentas: [(TracoTipo?, String, String)] = [
        (nil, "cursorarrow", "Cursor"),
        (.livre, "scribble", "Traço livre"),
        (.seta, "arrow.up.right", "Seta"),
        (.retangulo, "rectangle", "Retângulo"),
        (.elipse, "circle", "Elipse"),
        (.texto, "textformat", "Texto"),
    ]

    private static let cores = ["preto", "vermelho", "azul", "verde", "amarelo"]
    private static let espessuras: [Double] = [1.5, 3, 6]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.ferramentas, id: \.1) { tipo, icone, ajuda in
                Button {
                    store.ferramentaDesenho = tipo
                } label: {
                    Image(systemName: icone)
                        .frame(width: 22, height: 22)
                        .background(
                            store.ferramentaDesenho == tipo ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                }
                .buttonStyle(.plain)
                .help(ajuda)
            }
            if store.ferramentaDesenho != nil {
                Divider().frame(height: 16)
                ForEach(Self.cores, id: \.self) { cor in
                    Circle()
                        .fill(Color(hexOuNome: cor))
                        .stroke(.primary.opacity(store.corTraco == cor ? 0.8 : 0.1), lineWidth: 1.5)
                        .frame(width: 13, height: 13)
                        .onTapGesture { store.corTraco = cor }
                }
                Divider().frame(height: 16)
                ForEach(Self.espessuras, id: \.self) { espessura in
                    Circle()
                        .fill(.primary.opacity(store.espessuraTraco == espessura ? 0.9 : 0.35))
                        .frame(width: espessura + 4, height: espessura + 4)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .onTapGesture { store.espessuraTraco = espessura }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}

/// Sheet do texto solto (ferramenta texto).
struct TextoSoltoSheet: View {
    let ponto: Ponto
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var texto = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Texto solto").font(.headline)
            TextField("Texto:", text: $texto)
                .frame(width: 300)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Adicionar") {
                    store.finishStroke(worldPoints: [ponto], tipo: .texto, texto: texto)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(texto.isEmpty)
            }
        }
        .padding(16)
    }
}
