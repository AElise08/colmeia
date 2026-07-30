import SwiftUI
import ColmeiaKit

/// Papel claro + tinta escura derivada da cor — legível nos DOIS modos do sistema.
enum NotaPaleta {
    static let base: [(nome: String, r: Double, g: Double, b: Double)] = [
        ("amarelo", 1.0, 0.92, 0.6),
        ("rosa", 1.0, 0.78, 0.85),
        ("verde", 0.78, 0.94, 0.75),
        ("azul", 0.74, 0.87, 1.0),
        ("roxo", 0.87, 0.8, 1.0),
    ]

    static var cores: [(nome: String, cor: Color)] {
        base.map { ($0.nome, Color(red: $0.r, green: $0.g, blue: $0.b)) }
    }

    static func cor(_ nome: String) -> Color {
        let tom = base.first { $0.nome == nome } ?? base[0]
        return Color(red: tom.r, green: tom.g, blue: tom.b)
    }

    static func tinta(_ nome: String) -> Color {
        let tom = base.first { $0.nome == nome } ?? base[0]
        return Color(red: tom.r * 0.24, green: tom.g * 0.24, blue: tom.b * 0.24)
    }
}

/// §15.1 — Markdown renderizado (títulos, listas, checkboxes clicáveis); edição em
/// texto puro ao focar; cores; `ultima_fonte` visível. A nota é PAPEL CLARO: o texto
/// é sempre tinta escura derivada da cor da nota, independente do dark mode.
struct NotaNodeView<Drag: Gesture>: View {
    let node: NotaNode
    @ObservedObject var controller: NotaController
    let dragGesture: Drag

    @EnvironmentObject private var store: AppStore
    @FocusState private var editorFocado: Bool

    static var cores: [(nome: String, cor: Color)] { NotaPaleta.cores }

    private var corFundo: Color {
        NotaPaleta.cor(node.cor)
    }

    private var tinta: Color {
        NotaPaleta.tinta(node.cor)
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
        .environment(\.colorScheme, .light)
        .tint(tinta)
        .contextMenu {
            Button("Apagar nota", role: .destructive) {
                Task { await store.deleteNode(node.id) }
            }
        }
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
            Button(role: .destructive) {
                Task { await store.deleteNode(node.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.black.opacity(0.48))
            }
            .buttonStyle(.plain)
            .help("Apagar nota")
            .accessibilityLabel("Apagar nota")
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
            .foregroundStyle(tinta)
            .scrollContentBackground(.hidden)
            .focused($editorFocado)
            .padding(4)
            .onChange(of: editorFocado) { _, focado in
                if !focado { terminarEdicao() }
            }
        } else {
            ScrollView {
                NotaMarkdownView(
                    texto: textoParaExibir,
                    tinta: tinta,
                    onToggleTarefa: { linha in
                        if controller.toggleTarefa(linha: linha) { registrarEdicaoHumana() }
                    },
                    onRemoveTarefa: { linha in
                        if controller.removerTarefa(linha: linha) { registrarEdicaoHumana() }
                    }
                )
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
                Button {
                    controller.adicionarTarefa()
                    registrarEdicaoHumana()
                    controller.editando = true
                    editorFocado = true
                } label: {
                    Label("Tarefa", systemImage: "checklist")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black.opacity(0.65))
                .help("Adicionar item ao checklist")
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
        case .agente(let nodeID):
            guard let id = ULID(nodeID) else { return "agente" }
            let nome = store.nodeName(id)
            return nome == nodeID ? "agente" : nome
        case .sistema: return "sistema"
        }
    }

    /// Notas antigas podem conter o cabeçalho técnico usado antes da apresentação
    /// amigável. Mantemos o arquivo/auditoria intactos, mas nunca exibimos ao usuário
    /// `_agente:<ULID> — ..._`.
    private var textoParaExibir: String {
        controller.texto
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let raw = String(line)
                guard raw.hasPrefix("_agente:"), raw.hasSuffix("_"),
                      let separator = raw.range(of: " — ")
                else { return raw }
                let rawAuthor = String(raw.dropFirst().prefix(upTo: separator.lowerBound))
                guard case .agente(let nodeID) = Author(rawValue: rawAuthor) else { return raw }
                let friendly: String
                if let id = ULID(nodeID) {
                    let nome = store.nodeName(id)
                    friendly = nome == nodeID ? "agente" : nome
                } else {
                    friendly = "agente"
                }
                return "_\(friendly)\(raw[separator.lowerBound...])"
            }
            .joined(separator: "\n")
    }

    private func terminarEdicao() {
        guard controller.editando else { return }
        controller.editando = false
        controller.persist()
        registrarEdicaoHumana()
    }

    /// A view pode receber um clique já enfileirado depois de `node.delete`.
    /// O AppStore descarta apenas esse update local inequivocamente obsoleto;
    /// rejeições do engine para nós ainda presentes continuam aparecendo.
    private func registrarEdicaoHumana() {
        store.perform(.nodeUpdate(NodeUpdateOpPayload(
            id: node.id,
            campos: .object(["ultima_fonte": .string(Author.humanoLocal.rawValue)])
        )))
    }
}

/// Markdown de nota por blocos: títulos com hierarquia real, listas, checkboxes
/// clicáveis (`- [ ]`/`- [x]` → alterna e persiste no .md) e inline bold/itálico/código.
struct NotaMarkdownView: View {
    let texto: String
    let tinta: Color
    let onToggleTarefa: (Int) -> Void
    let onRemoveTarefa: (Int) -> Void

    private enum Bloco: Identifiable {
        case titulo(linha: Int, nivel: Int, texto: String)
        case tarefa(linha: Int, feita: Bool, texto: String)
        case item(linha: Int, marcador: String, texto: String)
        case paragrafo(linha: Int, texto: String)
        case separador(linha: Int)
        case vazio(linha: Int)

        var id: Int {
            switch self {
            case .titulo(let linha, _, _), .tarefa(let linha, _, _), .item(let linha, _, _),
                 .paragrafo(let linha, _), .separador(let linha), .vazio(let linha):
                return linha
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(blocos) { bloco in
                render(bloco)
            }
        }
    }

    private var blocos: [Bloco] {
        texto.components(separatedBy: "\n").enumerated().map { (linha, conteudo) -> Bloco in
            let aparado = conteudo.trimmingCharacters(in: .whitespaces)
            if aparado.isEmpty {
                return .vazio(linha: linha)
            }
            if aparado == "---" || aparado == "***" {
                return .separador(linha: linha)
            }
            if aparado.hasPrefix("#") {
                let nivel = aparado.prefix(while: { $0 == "#" }).count
                let resto = aparado.drop(while: { $0 == "#" })
                if nivel <= 6, resto.first == " " {
                    return .titulo(linha: linha, nivel: nivel, texto: resto.trimmingCharacters(in: .whitespaces))
                }
            }
            if let marcador = aparado.first, marcador == "-" || marcador == "*" {
                let resto = aparado.dropFirst().trimmingCharacters(in: .whitespaces)
                for (caixa, feita) in [("[ ]", false), ("[x]", true), ("[X]", true)] where resto.hasPrefix(caixa) {
                    return .tarefa(
                        linha: linha,
                        feita: feita,
                        texto: textoVisivelDaTarefa(
                            resto.dropFirst(caixa.count).trimmingCharacters(in: .whitespaces)
                        )
                    )
                }
                if !resto.isEmpty {
                    return .item(linha: linha, marcador: "•", texto: resto)
                }
            }
            if let ponto = aparado.firstIndex(where: { $0 == "." || $0 == ")" }),
               ponto != aparado.startIndex,
               aparado[..<ponto].allSatisfy(\.isNumber),
               aparado.index(after: ponto) < aparado.endIndex,
               aparado[aparado.index(after: ponto)] == " " {
                return .item(
                    linha: linha,
                    marcador: "\(aparado[..<ponto]).",
                    texto: aparado[aparado.index(after: ponto)...].trimmingCharacters(in: .whitespaces)
                )
            }
            return .paragrafo(linha: linha, texto: conteudo)
        }
    }

    /// IDs estáveis usados pela API de agentes vivem em comentário HTML no
    /// Markdown. O arquivo continua interoperável, mas esse metadado não deve
    /// aparecer como parte do texto da tarefa no canvas.
    private func textoVisivelDaTarefa(_ texto: String) -> String {
        guard let inicio = texto.range(of: "<!-- colmeia:item:"),
              let fim = texto.range(of: "-->", range: inicio.upperBound..<texto.endIndex)
        else { return texto }
        var visivel = texto
        visivel.removeSubrange(inicio.lowerBound..<fim.upperBound)
        return visivel.trimmingCharacters(in: .whitespaces)
    }

    @ViewBuilder
    private func render(_ bloco: Bloco) -> some View {
        switch bloco {
        case .titulo(_, let nivel, let texto):
            Text(inline(texto))
                .font(fonteTitulo(nivel))
                .foregroundStyle(tinta)
                .padding(.top, nivel <= 2 ? 4 : 2)
        case .tarefa(let linha, let feita, let texto):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Button {
                    onToggleTarefa(linha)
                } label: {
                    Image(systemName: feita ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(tinta.opacity(feita ? 0.9 : 0.6))
                }
                .buttonStyle(.plain)
                Text(inline(texto))
                    .font(.system(size: 12))
                    .strikethrough(feita, color: tinta.opacity(0.5))
                    .foregroundStyle(tinta.opacity(feita ? 0.5 : 0.9))
                Button {
                    onRemoveTarefa(linha)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tinta.opacity(0.55))
                .help("Remover tarefa")
                .accessibilityLabel("Remover tarefa \(texto)")
            }
        case .item(_, let marcador, let texto):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(marcador)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tinta.opacity(0.6))
                Text(inline(texto))
                    .font(.system(size: 12))
                    .foregroundStyle(tinta.opacity(0.9))
            }
        case .paragrafo(_, let texto):
            Text(inline(texto))
                .font(.system(size: 12))
                .foregroundStyle(tinta.opacity(0.9))
        case .separador:
            Rectangle()
                .fill(tinta.opacity(0.25))
                .frame(height: 1)
                .padding(.vertical, 3)
        case .vazio:
            Spacer()
                .frame(height: 4)
        }
    }

    private func fonteTitulo(_ nivel: Int) -> Font {
        switch nivel {
        case 1: return .system(size: 17, weight: .bold)
        case 2: return .system(size: 15, weight: .bold)
        case 3: return .system(size: 13, weight: .semibold)
        default: return .system(size: 12, weight: .semibold)
        }
    }

    private func inline(_ texto: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: texto, options: options)) ?? AttributedString(texto)
    }
}

/// Renderização dos traços de um DesenhoNode. Ferramentas de desenho (§15.2) ainda
/// não existem — traços vindos do documento são exibidos.
struct DesenhoNodeView<Drag: Gesture>: View {
    let node: DesenhoNode
    let dragGesture: Drag

    @EnvironmentObject private var store: AppStore
    @State private var editandoTexto = false
    @State private var textoEditado = ""
    @FocusState private var focoNoTexto: Bool

    private var textoSolto: Bool {
        node.texto != nil && !node.tracos.isEmpty && node.tracos.allSatisfy { $0.tipo == .texto }
    }

    var body: some View {
        Group {
            if textoSolto {
                corpoTextoSolto
            } else {
                corpoDesenho
            }
        }
        .contextMenu {
            if textoSolto {
                Button("Editar texto") { iniciarEdicaoTexto() }
            } else {
                Button("Apagar último traço") { store.deleteUltimoTraco(nodeID: node.id) }
                    .disabled(node.tracos.isEmpty)
            }
            Button(textoSolto ? "Apagar texto" : "Apagar desenho", role: .destructive) {
                Task { await store.deleteNode(node.id) }
            }
        }
    }

    /// Texto solto não recebe cartão, fundo ou borda: fora do contorno temporário
    /// de seleção em NodeContainer, é só tinta sobre o canvas. Continua um nó
    /// para preservar acessibilidade, drag e resize.
    private var corpoTextoSolto: some View {
        Group {
            if editandoTexto {
                TextField("Texto", text: $textoEditado, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(1...12)
                    .focused($focoNoTexto)
                    .onSubmit(confirmarEdicaoTexto)
                    .onChange(of: focoNoTexto) { _, focado in
                        if !focado { confirmarEdicaoTexto() }
                    }
                    .accessibilityLabel("Editar texto solto")
            } else {
                Text(node.texto ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: iniciarEdicaoTexto)
                    .accessibilityLabel("Texto solto: \(node.texto ?? "")")
                    .accessibilityHint("Clique duas vezes para editar; arraste para mover")
            }
        }
        .gesture(editandoTexto ? nil : dragGesture)
        .onAppear {
            if textoEditado.isEmpty { textoEditado = node.texto ?? "" }
        }
        .onChange(of: node.texto) { _, novo in
            if !editandoTexto { textoEditado = novo ?? "" }
        }
    }

    private var corpoDesenho: some View {
        Canvas { context, _ in
            for traco in node.tracos {
                desenhar(traco, in: &context)
            }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    private func iniciarEdicaoTexto() {
        textoEditado = node.texto ?? ""
        editandoTexto = true
        focoNoTexto = true
    }

    private func confirmarEdicaoTexto() {
        guard editandoTexto else { return }
        editandoTexto = false
        let novo = textoEditado.trimmingCharacters(in: .whitespacesAndNewlines)
        if novo.isEmpty {
            Task { await store.deleteNode(node.id) }
        } else if novo != node.texto {
            store.updateTextoSolto(node.id, texto: novo)
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
