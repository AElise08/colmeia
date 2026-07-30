import SwiftUI
import ColmeiaKit

/// Dados de alerta para a superfície operacional. O runtime pode convertê-los de
/// watchdog/archive sem expor detalhes de processo à view.
struct WorkerOperationAlert: Identifiable, Equatable {
    let id: String
    let sessionID: ULID
    let title: String
    let detail: String
    let createdAt: Date
    let escalated: Bool
}

struct ActiveWorkerSummary: Identifiable, Equatable {
    var id: ULID { sessionID }
    let nodeID: ULID
    let nome: String
    let adapter: String
    let estado: SessionEstado
    let sessionID: ULID
}

struct CanvasNoteSummary: Identifiable, Equatable {
    let id: ULID
    let title: String
    let lastWriter: String?
}

// MARK: - Agora

struct NowPanel: View {
    let workers: [ActiveWorkerSummary]
    let notes: [CanvasNoteSummary]
    let deliveries: [Delivery]
    let openDecisions: [Decision]
    let alerts: [WorkerOperationAlert]
    let messages: [AgentMessageSummary]
    let roomSyncLabel: String
    let nodeName: (ULID) -> String
    let onCreateWorker: () -> Void
    let onOpenDeliveries: () -> Void
    let onOpenMemory: () -> Void
    let onOpenRooms: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var pendingDeliveries: [Delivery] {
        deliveries.filter { $0.estado == .proposed || $0.estado == .reopened }
            .sorted { $0.atualizadaEm > $1.atualizadaEm }
    }

    var body: some View {
        NavigationStack {
            List {
                // §7.1 — fila priorizada de ação humana
                Section("Atenção humana") {
                    if openDecisions.isEmpty && pendingDeliveries.isEmpty && alerts.filter(\.escalated).isEmpty {
                        Text("Nada aguardando você agora.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(openDecisions, id: \.id) { decision in
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Decisão aberta", systemImage: "questionmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text(decision.question).lineLimit(3)
                        }
                    }
                    ForEach(pendingDeliveries.prefix(8), id: \.id) { delivery in
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Entrega aguarda revisão", systemImage: "shippingbox.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.blue)
                            Text(delivery.resumo).lineLimit(2)
                        }
                    }
                    ForEach(alerts.filter(\.escalated).prefix(5)) { alert in
                        Label(alert.title, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Button("Abrir salas e missões") { onOpenRooms() }
                    Button("Revisar entregas") { onOpenDeliveries() }
                }

                Section("Sala") {
                    Label(roomSyncLabel, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                }

                Section("Agentes") {
                    if workers.isEmpty {
                        ContentUnavailableView("Nenhum agente ativo", systemImage: "terminal")
                    } else {
                        ForEach(workers) { worker in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(worker.nome)
                                    Text(worker.adapter)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Label(EstadoStyle.rotulo(worker.estado), systemImage: "circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(EstadoStyle.cor(worker.estado))
                            }
                        }
                    }
                    Button { onCreateWorker() } label: {
                        Label("Criar agente", systemImage: "plus")
                    }
                }

                Section("Mensagens entre agentes") {
                    if messages.isEmpty {
                        ContentUnavailableView("Sem mensagens", systemImage: "tray")
                    } else {
                        ForEach(messages.suffix(12).reversed()) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(nodeName(message.de)) → \(nodeName(message.para))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(message.texto)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                                Text(message.deliveredAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Section("Notas conectadas") {
                    if notes.isEmpty {
                        Text("Nenhuma nota no canvas.").foregroundStyle(.secondary)
                    } else {
                        ForEach(notes) { note in
                            HStack {
                                Label(note.title, systemImage: "note.text")
                                Spacer()
                                if let lastWriter = note.lastWriter {
                                    Text(lastWriter).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Entregas recentes") {
                    let latest = deliveries.sorted { $0.atualizadaEm > $1.atualizadaEm }.prefix(5)
                    if latest.isEmpty {
                        Text("Nenhuma entrega declarada ainda.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(latest), id: \.id) { delivery in
                            VStack(alignment: .leading, spacing: 4) {
                                deliveryStatus(delivery.estado)
                                Text(delivery.resumo).lineLimit(2)
                                Label("\(delivery.evidencias.count) prova(s)", systemImage: "paperclip")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Abrir entregas") { onOpenDeliveries() }
                }

                Section("Alertas") {
                    if alerts.isEmpty {
                        Text("Sem alertas de operação.").foregroundStyle(.secondary)
                    } else {
                        ForEach(alerts.prefix(8)) { alert in
                            Label(alert.title, systemImage: alert.escalated ? "exclamationmark.triangle.fill" : "bell")
                                .foregroundStyle(alert.escalated ? .orange : .primary)
                        }
                    }
                }

                Section("Memória") {
                    Button("Abrir memória") { onOpenMemory() }
                }
            }
            .navigationTitle("Agora")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
            }
        }
        .frame(minWidth: 620, minHeight: 680)
    }

    private func deliveryStatus(_ status: DeliveryEstado) -> some View {
        let style: (String, Color, String) = switch status {
        case .accepted: ("Aceita", .green, "checkmark.circle.fill")
        case .proposed: ("Proposta", .blue, "paperplane.fill")
        case .draft: ("Rascunho", .secondary, "doc")
        case .reopened: ("Reaberta", .orange, "arrow.uturn.backward")
        case .partial: ("Parcial", .orange, "circle.lefthalf.filled")
        case .blocked: ("Bloqueada", .red, "hand.raised.fill")
        case .failed: ("Falhou", .red, "xmark.octagon.fill")
        }
        return Label(style.0, systemImage: style.2).foregroundStyle(style.1)
    }
}

// MARK: - Arquivos

struct FileTreePanel: View {
    let rootPath: String?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var items: [FileTreeItem] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let rootPath {
                    HStack(spacing: 8) {
                        Label(URL(fileURLWithPath: rootPath).lastPathComponent, systemImage: "folder")
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        Text(rootPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                }

                searchField

                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let rootPath {
                    List(filteredItems(items)) { item in
                        FileTreeRow(item: item, query: query)
                    }
                    .listStyle(.sidebar)
                    .safeAreaInset(edge: .bottom) {
                        Text(rootPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial)
                    }
                } else {
                    ContentUnavailableView(
                        "Sem pasta raiz",
                        systemImage: "folder",
                        description: Text("Abra um workspace com pasta, selecione um terminal ou configure o caminho do projeto.")
                    )
                }
            }
            .navigationTitle("Arquivos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
            }
        }
        .frame(minWidth: 560, minHeight: 640)
        .task(id: rootPath) { await load() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Buscar arquivo ou pasta", text: $query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func load() async {
        guard let rootPath else { return }
        loading = true
        let url = URL(fileURLWithPath: rootPath)
        let loaded = await Task.detached {
            FileTreeItem.load(url: url, depth: 0, maxDepth: 5)
        }.value
        items = loaded?.children ?? []
        loading = false
    }

    private func filteredItems(_ source: [FileTreeItem]) -> [FileTreeItem] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return source }
        return source.compactMap { item in item.filtered(matching: clean) }
    }
}

struct FileTreeRow: View {
    let item: FileTreeItem
    let query: String

    var body: some View {
        if item.isDirectory {
            DisclosureGroup {
                ForEach(item.children) { child in
                    FileTreeRow(item: child, query: query)
                }
            } label: {
                Label(item.name, systemImage: "folder")
            }
        } else {
            Label(item.name, systemImage: fileIcon(item.name))
                .foregroundStyle(item.isGitUntracked ? .green : .primary)
        }
    }

    private func fileIcon(_ name: String) -> String {
        if name.hasSuffix(".swift") || name.hasSuffix(".ts") || name.hasSuffix(".tsx") || name.hasSuffix(".js") {
            return "doc.text"
        }
        if name.hasSuffix(".png") || name.hasSuffix(".jpg") || name.hasSuffix(".svg") || name.hasSuffix(".ico") {
            return "photo"
        }
        return "doc"
    }
}

struct FileTreeItem: Identifiable, Equatable {
    let id: String
    let name: String
    let isDirectory: Bool
    let isGitUntracked: Bool
    var children: [FileTreeItem]

    static func load(url: URL, depth: Int, maxDepth: Int) -> FileTreeItem? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        var children: [FileTreeItem] = []
        if isDir.boolValue && depth < maxDepth {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
            let urls = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants])) ?? []
            children = urls
                .filter { $0.lastPathComponent != ".git" }
                .sorted {
                    let ld = ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                    let rd = ((try? $1.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                    if ld != rd { return ld && !rd }
                    return $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
                }
                .prefix(300)
                .compactMap { load(url: $0, depth: depth + 1, maxDepth: maxDepth) }
        }
        return FileTreeItem(
            id: url.path,
            name: name,
            isDirectory: isDir.boolValue,
            isGitUntracked: false,
            children: children)
    }

    func filtered(matching query: String) -> FileTreeItem? {
        let filteredChildren = children.compactMap { $0.filtered(matching: query) }
        if name.lowercased().contains(query) || !filteredChildren.isEmpty {
            var copy = self
            copy.children = filteredChildren
            return copy
        }
        return nil
    }
}

// MARK: - Janela compacta

#if false // Bzzz removido do produto; manter este bloco temporariamente facilita uma migração limpa do histórico.

struct BzzzCompanionView: View {
    let onClose: () -> Void
    @EnvironmentObject private var store: AppStore
    @State private var selectedWorkerID: ULID?
    @State private var command = ""
    @State private var showPromptComposer = false
    @State private var ombroQuestion = ""
    @StateObject private var ombro = OmbroAssistant()

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        workerPicker
                        if let worker = activeWorker, let controller = store.terminalControllers[worker.nodeID] {
                            agentCard(worker: worker, controller: controller)
                        } else {
                            emptyState
                        }
                        activityStrip
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 54)
                    .padding(.bottom, 12)
                }
                askBar
            }
            topControls
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.7), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { selectInitialWorker() }
        .onChange(of: terminalSummaries.map(\.id)) { _, _ in selectInitialWorker() }
        .sheet(isPresented: $showPromptComposer) {
            PromptComposerView(initialRecipient: activeWorker?.nodeID)
                .environmentObject(store)
        }
    }

    private var topControls: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Fechar Bzzz")
            Spacer()
            Button { showPromptComposer = true } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("Compor prompt para agentes")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    @ViewBuilder
    private func agentCard(worker: ActiveWorkerSummary, controller: TerminalController) -> some View {
        BzzzAgentCard(worker: worker, controller: controller, command: $command, ombroQuestion: $ombroQuestion, ombro: ombro) {
            sendCommand(to: controller)
        }
    }

    private var activityStrip: some View {
        HStack(spacing: 9) {
            Image(systemName: store.watchdogAlerts.last == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(store.watchdogAlerts.last == nil ? .green : .orange)
            Text(store.watchdogAlerts.last?.message ?? "Tudo sob observação. O Bzzz avisa quando você precisa entrar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var workerPicker: some View {
        Menu {
            if terminalSummaries.isEmpty {
                Text("Nenhum agente disponível")
            } else {
                ForEach(terminalSummaries) { worker in
                    Button {
                        selectedWorkerID = worker.id
                    } label: {
                        Label(worker.nome, systemImage: worker.id == selectedWorkerID ? "checkmark.circle.fill" : "terminal")
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sessão acompanhada")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(activeWorker?.nome ?? "Escolher agente")
                        .font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var askBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            TextField("Fale com o bzzz sobre este agente…", text: $ombroQuestion)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { askBzzz() }
            Button(action: askBzzz) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ombroQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.42) : Color.accentColor)
            .disabled(ombroQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || activeWorker == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nenhum agente para acompanhar",
            systemImage: "terminal",
            description: Text("Crie um agente no canvas e o Bzzz passa a mostrar a atividade dele aqui."))
        .frame(maxWidth: .infinity, minHeight: 430)
    }

    private var activeWorker: ActiveWorkerSummary? {
        terminalSummaries.first(where: { $0.id == selectedWorkerID }) ?? terminalSummaries.first
    }

    private func selectInitialWorker() {
        if selectedWorkerID == nil || !terminalSummaries.contains(where: { $0.id == selectedWorkerID }) {
            selectedWorkerID = terminalSummaries.first?.id
        }
    }

    private func sendCommand(to controller: TerminalController) {
        controller.sendCommand(command)
        command = ""
    }

    private func askBzzz() {
        guard let worker = activeWorker,
              let controller = store.terminalControllers[worker.nodeID]
        else { return }
        let question = ombroQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        ombroQuestion = ""
        Task { await ombro.summarize(worker: worker, lines: controller.linhasRecentes, question: question) }
    }

    private var terminalSummaries: [ActiveWorkerSummary] {
        store.nodes.values.compactMap { node in
            guard case .terminal(let terminal) = node,
                  let controller = store.terminalControllers[terminal.id],
                  let session = controller.session
            else { return nil }
            return ActiveWorkerSummary(
                nodeID: terminal.id,
                nome: terminal.nome,
                adapter: terminal.adapter,
                estado: controller.estado ?? session.estado,
                sessionID: session.id)
        }
        .sorted { $0.nome.localizedCaseInsensitiveCompare($1.nome) == .orderedAscending }
    }
}

private struct BzzzAgentCard: View {
    let worker: ActiveWorkerSummary
    @ObservedObject var controller: TerminalController
    @Binding var command: String
    @Binding var ombroQuestion: String
    @ObservedObject var ombro: OmbroAssistant
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BzzzAgentHeader(worker: worker)
            Text(summary)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.84))
                .lineLimit(3)
            BzzzTerminalExcerpt(lines: Array(controller.linhasRecentes.suffix(9)))
            ombroCard
            commandBar
        }
        .padding(18)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
    }

    private var summary: String {
        if !controller.ultimaLinha.isEmpty { return controller.ultimaLinha }
        if let state = controller.estado {
            return "O agente está \(EstadoStyle.rotulo(state)). Vou mostrar a saída assim que ele escrever no terminal."
        }
        return "Preparando a sessão do agente."
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            TextField("Mandar para \(worker.nome)…", text: $command)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit(onSend)
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .foregroundStyle(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.45) : Color.accentColor)
            .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var ombroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("bzzz")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(ombro.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(ombro.answer)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(6)
            HStack(spacing: 8) {
                Button("Resumir") { askBzzz() }
                Button("Próximo comando") { suggestCommand() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Text("Use a caixa fixa no rodapé para responder ou redirecionar o bzzz.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.purple.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.13), lineWidth: 1))
    }

    private func askBzzz() {
        let question = ombroQuestion
        ombroQuestion = ""
        let lines = controller.linhasRecentes
        Task { await ombro.summarize(worker: worker, lines: lines, question: question) }
    }

    private func suggestCommand() {
        let lines = controller.linhasRecentes
        Task { await ombro.suggestCommand(worker: worker, lines: lines) }
    }
}

private struct BzzzAgentHeader: View {
    let worker: ActiveWorkerSummary

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(worker.nome).font(.system(size: 15, weight: .semibold))
                Text(worker.adapter).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(EstadoStyle.cor(worker.estado)).frame(width: 9, height: 9)
            Text(EstadoStyle.rotulo(worker.estado))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct BzzzTerminalExcerpt: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("terminal ao vivo").font(.system(size: 10, weight: .bold, design: .monospaced))
                Spacer()
                Text("saída recente").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.06))
            ScrollView {
                Text(renderedLines)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .textColor).opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(height: 144)
        }
        .background(Color.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var renderedLines: String {
        let clean = lines.map { line -> String in
            let normalized = line.replacingOccurrences(of: "\t", with: "  ")
            return normalized.count > 220 ? String(normalized.prefix(217)) + "…" : normalized
        }
        return clean.isEmpty ? "Aguardando saída do terminal…" : clean.joined(separator: "\n")
    }
}

private struct BzzzSteps: View {
    let steps: [String]

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(Color.primary.opacity(0.07), in: Circle())
                        Text(step)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.8))
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

private struct BzzzWorkerRow: View {
    let worker: ActiveWorkerSummary
    @ObservedObject var controller: TerminalController
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(EstadoStyle.cor(worker.estado)).frame(width: 8, height: 8)
                Text(worker.nome).lineLimit(1)
                Spacer()
                Text(EstadoStyle.rotulo(worker.estado))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if hovering { terminalPreview }
        }
        .padding(8)
        .background(Color.primary.opacity(hovering ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var terminalPreview: some View {
        let lines = controller.linhasRecentes.suffix(6)
        if lines.isEmpty {
            Text(controller.ultimaLinha.isEmpty ? "Aguardando saída do terminal…" : controller.ultimaLinha)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.78))
                .lineLimit(6)
                .textSelection(.enabled)
        }
    }
}

#endif

// MARK: - Memória

struct MemoryPanel: View {
    let memory: WorkspaceMemory
    let proposals: [MemoryProposal]
    let history: [MemoryHistoryEntry]
    let onUpdate: (String) -> Void
    let onAccept: (ULID, String?) -> Void
    let onReject: (ULID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var proposalDrafts: [ULID: String] = [:]

    init(
        memory: WorkspaceMemory,
        proposals: [MemoryProposal],
        history: [MemoryHistoryEntry],
        onUpdate: @escaping (String) -> Void,
        onAccept: @escaping (ULID, String?) -> Void,
        onReject: @escaping (ULID) -> Void
    ) {
        self.memory = memory
        self.proposals = proposals
        self.history = history
        self.onUpdate = onUpdate
        self.onAccept = onAccept
        self.onReject = onReject
        _draft = State(initialValue: memory.content)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Cartões") {
                    let cards = MemoryCard.cards(from: draft)
                    Text("Cartões são linhas estruturadas da memória. Eles deixam claro para os agentes o que é decisão, fato, preferência ou próximo passo; o Markdown continua sendo a fonte editável.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if cards.isEmpty {
                        ContentUnavailableView(
                            "Sem cartões ainda",
                            systemImage: "rectangle.stack",
                            description: Text("Use linhas curtas como: Decisão: usar entregas com prova.")
                        )
                    } else {
                        ForEach(cards) { card in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(card.kind.label, systemImage: card.kind.icon)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(card.kind.color)
                                Text(card.text)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    HStack {
                        Button("Nova decisão") { appendMemoryTemplate("Decisão: ") }
                        Button("Novo fato") { appendMemoryTemplate("Fato: ") }
                        Button("Preferência") { appendMemoryTemplate("Preferência: ") }
                    }
                    .buttonStyle(.bordered)
                }

                Section {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $draft)
                            .font(.body.monospaced())
                            .frame(minHeight: 160)
                            .accessibilityLabel("Memória do workspace")
                        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Fatos estáveis do projeto, decisões aceitas e preferências que os agentes devem lembrar.")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    if let updatedAt = memory.updatedAt {
                        Label("Atualizada \(updatedAt.formatted(date: .abbreviated, time: .shortened)) por \(memory.updatedBy?.description ?? "desconhecido")", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Salvar memória") { onUpdate(draft) }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == memory.content)
                } header: {
                    Text("Memória editável")
                } footer: {
                    Text("Contexto durável deste projeto. Você decide o conteúdo final; agentes apenas enviam propostas para revisão.")
                }

                Section {
                    let pending = pendingProposals
                    if pending.isEmpty {
                        ContentUnavailableView("Sem propostas pendentes", systemImage: "checkmark.circle")
                    } else {
                        ForEach(pending) { proposal in
                            VStack(alignment: .leading, spacing: 8) {
                                TextEditor(text: proposalDraftBinding(proposal))
                                    .font(.body.monospaced())
                                    .frame(minHeight: 90)
                                    .accessibilityLabel("Proposta de memória")
                                Label("\(proposal.author.description) · \(proposal.createdAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "person")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Aceitar revisada") {
                                        onAccept(proposal.id, proposalDrafts[proposal.id] ?? proposal.content)
                                    }
                                        .buttonStyle(.borderedProminent)
                                    Button("Rejeitar", role: .destructive) { onReject(proposal.id) }
                                        .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                } header: {
                    HStack {
                        Text("Propostas pendentes")
                        if !pendingProposals.isEmpty {
                            Text("\(pendingProposals.count)")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.18), in: Capsule())
                        }
                    }
                } footer: {
                    Text("Agentes só propõem. Revise o texto aqui; aceitar substitui a memória curada pelo conteúdo aprovado.")
                }

                Section("Histórico") {
                    if history.isEmpty {
                        Text("Ainda não há alterações registradas.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(history.sorted { $0.timestamp > $1.timestamp }) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: memoryHistoryIcon(entry.action))
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(memoryHistoryLabel(entry.action))
                                    Text("\(entry.author.description) · \(entry.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let detail = entry.detail, !detail.isEmpty {
                                        Text(detail).font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(pendingProposals.isEmpty ? "Memória" : "Memória (\(pendingProposals.count))")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
            }
        }
        .frame(minWidth: 600, minHeight: 620)
    }

    private var pendingProposals: [MemoryProposal] {
        proposals.filter { $0.status == .pending }
    }

    private func proposalDraftBinding(_ proposal: MemoryProposal) -> Binding<String> {
        Binding(
            get: { proposalDrafts[proposal.id] ?? proposal.content },
            set: { proposalDrafts[proposal.id] = $0 }
        )
    }

    private func appendMemoryTemplate(_ template: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmed.isEmpty ? template : "\(trimmed)\n\n\(template)"
    }

    private func memoryHistoryIcon(_ action: MemoryHistoryAction) -> String {
        switch action {
        case .memoryUpdated: return "square.and.pencil"
        case .dailyAppended: return "calendar.badge.plus"
        case .proposalCreated: return "sparkles"
        case .proposalAccepted: return "checkmark.circle"
        case .proposalRejected: return "xmark.circle"
        }
    }

    private func memoryHistoryLabel(_ action: MemoryHistoryAction) -> String {
        switch action {
        case .memoryUpdated: return "Memória editada"
        case .dailyAppended: return "Diário atualizado"
        case .proposalCreated: return "Proposta criada"
        case .proposalAccepted: return "Proposta aceita"
        case .proposalRejected: return "Proposta rejeitada"
        }
    }
}

private struct MemoryCard: Identifiable, Equatable {
    enum Kind: String {
        case decision, fact, preference, next

        var label: String {
            switch self {
            case .decision: return "Decisão"
            case .fact: return "Fato"
            case .preference: return "Preferência"
            case .next: return "Próximo passo"
            }
        }

        var icon: String {
            switch self {
            case .decision: return "checkmark.seal"
            case .fact: return "info.circle"
            case .preference: return "slider.horizontal.3"
            case .next: return "arrow.right.circle"
            }
        }

        var color: Color {
            switch self {
            case .decision: return .green
            case .fact: return .blue
            case .preference: return .purple
            case .next: return .orange
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let text: String

    static func cards(from markdown: String) -> [MemoryCard] {
        markdown
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { line -> MemoryCard? in
                let clean = line
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-* "))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return nil }
                let lower = clean.lowercased()
                let pairs: [(String, Kind)] = [
                    ("decisão:", .decision), ("decisao:", .decision),
                    ("fato:", .fact),
                    ("preferência:", .preference), ("preferencia:", .preference),
                    ("próximo:", .next), ("proximo:", .next), ("próximo passo:", .next), ("proximo passo:", .next),
                ]
                guard let match = pairs.first(where: { lower.hasPrefix($0.0) }) else { return nil }
                let text = String(clean.dropFirst(match.0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return MemoryCard(kind: match.1, text: text)
            }
    }
}

// MARK: - Entregas

struct DeliveriesPanel: View {
    let deliveries: [Delivery]
    let onAccept: (ULID) -> Void
    let onReopen: (ULID) -> Void
    let onTerminateAndArchive: (ULID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pendingArchive: Delivery?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("O agente declara o resultado com evidências. Você aceita, reabre ou encerra e arquiva o worker; atividade ou silêncio nunca contam como conclusão automática.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if deliveries.isEmpty {
                    ContentUnavailableView(
                        "Sem entregas",
                        systemImage: "shippingbox",
                        description: Text("Uma entrega aparece quando um agente usa `colmeia done` com resumo e evidências.")
                    )
                } else {
                    ForEach(deliveries.sorted { $0.atualizadaEm > $1.atualizadaEm }, id: \.id) { delivery in
                        Section {
                            Text(delivery.resumo)
                                .textSelection(.enabled)
                            deliveryEvidence(delivery)
                            HStack {
                                Label("\(delivery.evidencias.count) evidência(s)", systemImage: "paperclip")
                                Spacer()
                                Text(delivery.atualizadaEm.formatted(date: .abbreviated, time: .shortened))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if delivery.aceita {
                                HStack {
                                    Button("Reabrir") { onReopen(delivery.id) }
                                    Spacer()
                                    Button("Encerrar e arquivar", role: .destructive) {
                                        pendingArchive = delivery
                                    }
                                }
                            } else {
                                Button("Aceitar") { onAccept(delivery.id) }
                                    .buttonStyle(.borderedProminent)
                            }
                        } header: {
                            HStack {
                                deliveryStatus(delivery.estado)
                                Spacer()
                                Text(delivery.aceita ? "aceita" : "aguarda revisão")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(delivery.aceita ? .green : .secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Entregas")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
            }
            .confirmationDialog(
                "Encerrar a sessão e arquivar este worker?",
                isPresented: Binding(
                    get: { pendingArchive != nil },
                    set: { if !$0 { pendingArchive = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Encerrar e arquivar", role: .destructive) {
                    if let delivery = pendingArchive {
                        onTerminateAndArchive(delivery.sessionID)
                    }
                    pendingArchive = nil
                }
                Button("Cancelar", role: .cancel) { pendingArchive = nil }
            } message: {
                Text("O processo será encerrado. Journal, entrega e replay serão preservados.")
            }
        }
        .frame(minWidth: 600, minHeight: 520)
    }

    @ViewBuilder
    private func deliveryEvidence(_ delivery: Delivery) -> some View {
        if delivery.evidencias.isEmpty {
            Label("Sem prova anexada", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Provas", systemImage: "paperclip")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(delivery.evidencias, id: \.id) { evidence in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(evidence.tipo.rawValue.replacingOccurrences(of: "_", with: " "), systemImage: evidenceIcon(evidence.tipo))
                            .font(.caption.weight(.medium))
                        Text(evidence.referencia)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                        if let descricao = evidence.descricao {
                            Text(descricao).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func deliveryStatus(_ status: DeliveryEstado) -> some View {
        let style: (String, Color, String) = switch status {
        case .accepted: ("Aceita", .green, "checkmark.circle.fill")
        case .proposed: ("Proposta", .blue, "paperplane.fill")
        case .draft: ("Rascunho", .secondary, "doc")
        case .reopened: ("Reaberta", .orange, "arrow.uturn.backward")
        case .partial: ("Parcial", .orange, "circle.lefthalf.filled")
        case .blocked: ("Bloqueada", .red, "hand.raised.fill")
        case .failed: ("Falhou", .red, "xmark.octagon.fill")
        }
        return Label(style.0, systemImage: style.2).foregroundStyle(style.1)
    }

    private func evidenceIcon(_ type: DeliveryEvidenceTipo) -> String {
        switch type {
        case .file: return "doc"
        case .diff: return "arrow.left.arrow.right"
        case .commit: return "arrow.triangle.branch"
        case .test: return "checkmark.seal"
        case .note: return "note.text"
        case .portal: return "globe"
        case .outputExcerpt: return "text.alignleft"
        case .artifact: return "shippingbox"
        }
    }
}

// MARK: - Operação de workers

struct WorkersOperationPanel: View {
    @Binding var watchdog: WorkerWatchdogConfiguration
    let alerts: [WorkerOperationAlert]
    let activeWorkers: [ActiveWorkerSummary]
    let archives: [WorkerArchiveTombstone]
    let onConfigurationChange: (WorkerWatchdogConfiguration) -> Void
    let onCreateWorker: () -> Void
    let onOpenReplay: (Session) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Workers ativos") {
                    if activeWorkers.isEmpty {
                        ContentUnavailableView(
                            "Nenhum worker ativo",
                            systemImage: "terminal",
                            description: Text("Crie um terminal para iniciar um worker.")
                        )
                    } else {
                        ForEach(activeWorkers) { worker in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(worker.nome)
                                    Text("\(worker.adapter) · sessão \(worker.sessionID.string.prefix(8))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Label(EstadoStyle.rotulo(worker.estado), systemImage: "circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(EstadoStyle.cor(worker.estado))
                            }
                        }
                    }
                    Button {
                        onCreateWorker()
                    } label: {
                        Label("Criar worker", systemImage: "plus")
                    }
                }

                Section("Watchdog") {
                    Toggle("Observar workers inativos", isOn: workspaceEnabled)
                    Text(watchdog.workspacePolicy.enabled
                         ? "Apenas avisa e escala; nunca mata, reinicia ou arquiva workers."
                         : "Desligado por padrão. Nenhuma ação é tomada automaticamente.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if watchdog.workspacePolicy.enabled {
                        Stepper("Inatividade: \(Int(watchdog.workspacePolicy.staleAfter)) s", value: staleAfter, in: 30...3_600, step: 30)
                        Stepper("Intervalo de lembrete: \(Int(watchdog.workspacePolicy.nudgeInterval)) s", value: nudgeInterval, in: 30...1_800, step: 30)
                        Stepper("Limite por episódio: \(watchdog.workspacePolicy.maxNudgesPerEpisode)", value: maxNudges, in: 0...2)
                        Text("Depois do limite, o worker só é escalado para revisão humana.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Alertas") {
                    if alerts.isEmpty {
                        ContentUnavailableView("Sem alertas", systemImage: "checkmark.shield")
                    } else {
                        ForEach(alerts) { alert in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(alert.title, systemImage: alert.escalated ? "exclamationmark.triangle.fill" : "bell")
                                    .foregroundStyle(alert.escalated ? .orange : .primary)
                                Text(alert.detail).font(.caption).foregroundStyle(.secondary)
                                Text(alert.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Section("Arquivos e replay") {
                    if archives.isEmpty {
                        Text("Nenhum worker arquivado.").foregroundStyle(.secondary)
                    } else {
                        ForEach(archives, id: \.id) { archive in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Sessão \(archive.session.id.string.prefix(8))")
                                    Text(archive.evidence.journal ?? "journal não informado")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Abrir replay") { onOpenReplay(archive.session) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Operação de workers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
            }
        }
        .frame(minWidth: 580, minHeight: 510)
    }

    private var workspaceEnabled: Binding<Bool> {
        Binding(
            get: { watchdog.workspacePolicy.enabled },
            set: { value in
                watchdog.workspacePolicy.enabled = value
                onConfigurationChange(watchdog)
            }
        )
    }

    private var staleAfter: Binding<Double> {
        Binding(
            get: { watchdog.workspacePolicy.staleAfter },
            set: { value in
                watchdog.workspacePolicy.staleAfter = value
                onConfigurationChange(watchdog)
            }
        )
    }

    private var nudgeInterval: Binding<Double> {
        Binding(
            get: { watchdog.workspacePolicy.nudgeInterval },
            set: { value in
                watchdog.workspacePolicy.nudgeInterval = value
                onConfigurationChange(watchdog)
            }
        )
    }

    private var maxNudges: Binding<Int> {
        Binding(
            get: { watchdog.workspacePolicy.maxNudgesPerEpisode },
            set: { value in
                watchdog.workspacePolicy.maxNudgesPerEpisode = value
                onConfigurationChange(watchdog)
            }
        )
    }
}
