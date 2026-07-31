import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ColmeiaKit

/// As duas superfícies usam o mesmo workspace. O canvas continua sendo a visão
/// espacial; Agent Chat é uma lente de coordenação para conversar e acompanhar
/// os mesmos agentes sem transformar o Colmeia em um terminal tradicional.
enum ColmeiaSurface: String, CaseIterable, Identifiable {
    case canvas
    case agentChat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .canvas: return "Canvas"
        case .agentChat: return "Agent Chat"
        }
    }

    var symbol: String {
        switch self {
        case .canvas: return "square.3.layers.3d"
        case .agentChat: return "bubble.left.and.bubble.right"
        }
    }
}

struct SurfaceSwitcher: View {
    @Binding var selection: ColmeiaSurface

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ColmeiaSurface.allCases) { surface in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selection = surface }
                } label: {
                    Label(surface.title, systemImage: surface.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selection == surface ? .primary : .secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            selection == surface ? Color.accentColor.opacity(0.16) : .clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == surface ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

struct AgentChatView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var surface: ColmeiaSurface

    @State private var selectedAgentID: ULID?
    @State private var primaryAgentID: ULID?
    @State private var switchingAgentID: ULID?
    @State private var draft = ""
    @State private var attachments: [URL] = []
    @State private var isDroppingAttachment = false
    @State private var sentMessages: [AgentChatEntry] = []
    @State private var showModelSheet = false
    @State private var requestedModel = ""
    @FocusState private var composerFocused: Bool

    private var agents: [AgentChatAgent] {
        store.nodes.values.compactMap { node in
            guard case .terminal(let terminal) = node,
                  let controller = store.terminalControllers[terminal.id] else { return nil }
            return AgentChatAgent(
                id: terminal.id,
                name: terminal.nome,
                role: terminal.papel,
                adapter: terminal.adapter,
                model: terminal.modelo,
                controller: controller)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedAgent: AgentChatAgent? {
        guard let selectedAgentID else { return nil }
        return agents.first { $0.id == selectedAgentID }
    }

    private var activeAgents: [AgentChatAgent] {
        agents.filter { $0.controller.viva }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            conversation
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if selectedAgentID == nil { selectedAgentID = agents.first?.id }
            restorePrimaryAgent()
        }
        .onChange(of: agentIDs) { _, ids in
            guard let selectedAgentID else {
                self.selectedAgentID = ids.first
                return
            }
            if !ids.contains(selectedAgentID) { self.selectedAgentID = ids.first }
        }
    }

    private var agentIDs: [ULID] { agents.map(\.id) }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "hexagon.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agent workspace")
                        .font(.headline)
                    Text(store.workspace?.nome ?? "Workspace")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    agentsSection
                    projectsSection
                }
                .padding(12)
            }
        }
        .frame(width: 245)
        .background(.thinMaterial)
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeader("AGENTS", symbol: "person.2.fill") {
                store.presentNewTerminal(adapter: store.newTerminalAdapter)
            }

            if agents.isEmpty {
                Text("No agents in this workspace yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
            } else {
                ForEach(agents) { agent in
                    AgentListRow(
                        agent: agent,
                        selected: selectedAgentID == agent.id,
                        primary: primaryAgentID == agent.id,
                        onSelect: { selectedAgentID = agent.id },
                        onSetPrimary: { setPrimaryAgent(agent.id) })
                }
            }
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeader("PROJECTS", symbol: "folder.fill") { surface = .canvas }

            projectRow("Main canvas", symbol: "square.3.layers.3d", selected: store.activeFloor == nil)
            ForEach(store.floors.filter { $0.estado == .ativo || $0.estado == .orfao }, id: \.id) { floor in
                projectRow(
                    floor.nome,
                    symbol: floor.estado == .orfao ? "exclamationmark.triangle" : "square.3.layers.3d",
                    detail: floor.branch,
                    selected: store.activeFloor?.id == floor.id)
            }
        }
    }

    private func projectRow(
        _ title: String,
        symbol: String,
        detail: String? = nil,
        selected: Bool
    ) -> some View {
        Button {
            if let floor = store.floors.first(where: { $0.nome == title }) {
                Task { await store.switchFloor(floor) }
            } else {
                Task { await store.switchFloor(nil) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.caption2).foregroundStyle(.tint) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            conversationHeader
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    introCard
                    ForEach(sentMessages) { message in
                        HumanMessageBubble(message: message)
                    }
                    agentMessages
                    inlineApprovals
                    if let selectedAgent {
                        LiveAgentOutput(agent: selectedAgent)
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showModelSheet) {
            ModelSelectionSheet(
                agent: selectedAgent,
                requestedModel: $requestedModel,
                onSave: { model in
                    guard let agent = selectedAgent else { return }
                    switchingAgentID = agent.id
                    Task {
                        await store.switchAgentModel(nodeID: agent.id, to: model)
                        switchingAgentID = nil
                    }
                })
        }
    }

    private var inlineApprovals: some View {
        let approvals = store.pendingApprovals.filter { approval in
            selectedAgentID == nil || store.nodes.values.contains { node in
                if case .terminal(let terminal) = node { return terminal.id == selectedAgentID && approval.nodeNome == terminal.nome }
                return false
            }
        }
        return Group {
            ForEach(approvals, id: \.id) { approval in
                ApprovalCard(approval: approval) {}
            }
        }
    }

    private var conversationHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Coordination room")
                    .font(.title3.weight(.semibold))
                Text(selectedAgent.map { "Talking to \($0.name)" } ?? "Talk to your agents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let primaryAgent = agents.first(where: { $0.id == primaryAgentID }) {
                Label("Primary · \(primaryAgent.name)", systemImage: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let selectedAgent {
                modelMenu(for: selectedAgent)
            }
            if !activeAgents.isEmpty {
                Label("\(activeAgents.count) active", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Button {
                surface = .canvas
            } label: {
                Label("Back to Canvas", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("A more visual way to work with agents")
                    .font(.headline)
            }
            Text("Ask an agent to research, write, review, or prepare something for the canvas. Their live terminal activity stays connected to this conversation.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                quickPrompt("Summarize the current project")
                quickPrompt("What needs my attention?")
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.13), Color.purple.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.tint.opacity(0.16), lineWidth: 1))
    }

    private func quickPrompt(_ prompt: String) -> some View {
        Button(prompt) { draft = prompt; composerFocused = true }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    @ViewBuilder
    private var agentMessages: some View {
        let messages = store.agentMessages.filter { message in
            guard let selectedAgentID else { return true }
            return message.de == selectedAgentID || message.para == selectedAgentID
        }.suffix(20)
        ForEach(Array(messages), id: \.id) { message in
            AgentMessageCard(message: message, name: store.nodeName(message.de), recipient: store.nodeName(message.para))
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty { attachmentBar }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("All active agents") { selectedAgentID = nil }
                    if !activeAgents.isEmpty { Divider() }
                    ForEach(activeAgents) { agent in
                        Button {
                            selectedAgentID = agent.id
                        } label: {
                            Label(agent.name, systemImage: selectedAgentID == agent.id ? "checkmark" : "person")
                        }
                    }
                } label: {
                    Label(selectedAgent?.name ?? "All active agents", systemImage: "at")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: chooseImages) {
                    Image(systemName: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Attach images, or drag images into this message")

                TextField("Ask an agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .onSubmit { send() }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(
                        isDroppingAttachment ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || activeAgents.isEmpty)
            }
        }
        .padding(14)
        .background(.bar)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDroppingAttachment, perform: acceptDrop)
        .overlay(alignment: .bottomLeading) {
            Text("⌘V paste · ⌘C copy selected text · Return sends")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 145)
                .padding(.bottom, 2)
                .allowsHitTesting(false)
        }
    }

    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments, id: \.path) { url in
                    HStack(spacing: 6) {
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 30, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        } else {
                            Image(systemName: "paperclip")
                        }
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            attachments.removeAll { $0.path == url.path }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(5)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Images are sent to the agent as local file references.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let targets = selectedAgent.map { [$0] } ?? activeAgents
        guard !targets.isEmpty else {
            store.avisoInfo = "No active agent is available."
            return
        }
        let references = attachments.isEmpty ? "" : "\n\nAttached images (inspect these local files when relevant):\n" + attachments.map { "- \($0.path)" }.joined(separator: "\n")
        let command = text + references
        let pendingAttachments = attachments
        guard let workspaceID = store.workspace?.id else { return }
        Task {
            var delivered: [String] = []
            var failures: [String] = []
            for target in targets {
                do {
                    try await target.controller.ensureAndSendCommand(
                        workspaceID: workspaceID,
                        floorID: store.activeFloor?.id,
                        command: command)
                    delivered.append(target.name)
                } catch {
                    failures.append("\(target.name): \(error.localizedDescription)")
                }
            }
            if !delivered.isEmpty {
                await MainActor.run {
                    sentMessages.append(AgentChatEntry(
                        text: text,
                        recipient: delivered.joined(separator: ", "),
                        attachments: pendingAttachments))
                    if sentMessages.count > 50 { sentMessages.removeFirst(sentMessages.count - 50) }
                    draft = ""
                    attachments = []
                }
            }
            if !failures.isEmpty {
                await MainActor.run {
                    store.avisoInfo = "Message not delivered to " + failures.joined(separator: " · ")
                }
            }
        }
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        addAttachments(panel.urls)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { addAttachments([url]) }
            }
        }
        return true
    }

    private func addAttachments(_ urls: [URL]) {
        let images = urls.filter { url in
            guard url.isFileURL else { return false }
            return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        }
        attachments.append(contentsOf: images.filter { newURL in
            !attachments.contains(where: { $0.path == newURL.path })
        })
    }

    private func restorePrimaryAgent() {
        if let id = store.workspace?.primaryNodeID, agents.contains(where: { $0.id == id }) {
            primaryAgentID = id
            return
        }
        primaryAgentID = agents.first(where: { agent in
            let role = agent.role?.lowercased() ?? ""
            return role.contains("lead") || role.contains("rainha") || role.contains("queen")
        })?.id ?? agents.first?.id
        if let id = primaryAgentID {
            Task { await store.setPrimaryAgent(id) }
        }
    }

    private func setPrimaryAgent(_ id: ULID) {
        primaryAgentID = id
        Task { await store.setPrimaryAgent(id) }
    }

    @ViewBuilder
    private func modelMenu(for agent: AgentChatAgent) -> some View {
        Menu {
            Section("MODEL") {
                Text("Current: \(agent.currentModelLabel)")
                if agent.adapter == KnownAdapter.codex.rawValue {
                    Button("Choose Codex model…") {
                        requestedModel = agent.model ?? ""
                        showModelSheet = true
                    }
                    Button("Use Codex default") {
                        switchingAgentID = agent.id
                        Task {
                            await store.switchAgentModel(nodeID: agent.id, to: nil)
                            switchingAgentID = nil
                        }
                    }
                    .disabled(agent.model == nil || switchingAgentID != nil)
                }
            }
            Divider()
            Section("AGENT RUNTIME") {
                ForEach(NewTerminalSheet.quickStarts) { option in
                    Button {
                        switchingAgentID = agent.id
                        Task {
                            await store.switchAgentAdapter(nodeID: agent.id, to: option.id)
                            switchingAgentID = nil
                        }
                    } label: {
                        Label(
                            agentModelLabel(option.id),
                            systemImage: agent.adapter == option.id ? "checkmark" : option.icone)
                    }
                    .disabled(agent.adapter == option.id || !store.adapterPodeSerSelecionado(option.id) || switchingAgentID != nil)
                }
            }
        } label: {
            HStack(spacing: 5) {
                if switchingAgentID == agent.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "cpu")
                }
                Text("\(agentModelLabel(agent.adapter)) · \(agent.currentModelLabel)")
            }
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("See or change the selected model. The agent identity and Codex conversation stay the same.")
    }
}

private func agentModelLabel(_ adapter: String) -> String {
    switch adapter {
    case KnownAdapter.claudeCode.rawValue: return "Claude Code"
    case KnownAdapter.codex.rawValue: return "Codex"
    case KnownAdapter.geminiCli.rawValue: return "Gemini CLI"
    case KnownAdapter.opencode.rawValue: return "OpenCode"
    case KnownAdapter.shell.rawValue: return "Shell"
    default: return adapter
    }
}

private struct AgentChatAgent: Identifiable {
    let id: ULID
    let name: String
    let role: String?
    let adapter: String
    let model: String?
    let controller: TerminalController

    var currentModelLabel: String {
        model ?? (adapter == KnownAdapter.codex.rawValue ? "Codex default" : "Default")
    }
}

private struct AgentChatEntry: Identifiable {
    let id = UUID()
    let text: String
    let recipient: String
    let attachments: [URL]
}

private struct AgentListRow: View {
    let agent: AgentChatAgent
    let selected: Bool
    let primary: Bool
    let onSelect: () -> Void
    let onSetPrimary: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .fill(agent.controller.viva ? Color.green.opacity(0.18) : Color.secondary.opacity(0.14))
                        Text(String(agent.name.prefix(1)).uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(agent.controller.viva ? .green : .secondary)
                    }
                    .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 3) {
                            Text(agent.role ?? "Agent")
                            Text("·")
                            Text("\(agentModelLabel(agent.adapter)) · \(agent.currentModelLabel)")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer()
                    Circle()
                        .fill(agent.controller.viva ? .green : .secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                }
            }
            .buttonStyle(.plain)
            Button(action: onSetPrimary) {
                Image(systemName: primary ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(primary ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(primary ? "Primary agent" : "Set as primary agent")
        }
        .padding(7)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct HumanMessageBubble: View {
    let message: AgentChatEntry

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("You → \(message.recipient)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message.text)
                .font(.callout)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 13))
            if !message.attachments.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text(message.attachments.map(\.lastPathComponent).joined(separator: ", "))
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct AgentMessageCard: View {
    let message: AgentMessageSummary
    let name: String
    let recipient: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("\(name) → \(recipient)", systemImage: "arrow.turn.down.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message.texto)
                .font(.callout)
                .textSelection(.enabled)
            Text(message.deliveredAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LiveAgentOutput: View {
    let agent: AgentChatAgent
    @ObservedObject var controller: TerminalController

    init(agent: AgentChatAgent) {
        self.agent = agent
        self._controller = ObservedObject(wrappedValue: agent.controller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Live activity · \(agent.name)", systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(EstadoStyle.rotulo(controller.estado))
                    .font(.caption2)
                    .foregroundStyle(EstadoStyle.cor(controller.estado))
            }
            Text(activitySummary)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let response = controller.structuredAssistantMessages.last {
                VStack(alignment: .leading, spacing: 5) {
                    Label("\(agent.name) replied", systemImage: "text.bubble.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(response)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
            Text("Responses come from the Codex conversation history. Terminal redraws stay in Canvas.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(13)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var activitySummary: String {
        switch controller.estado {
        case .rodando: return "Working on the latest instruction."
        case .esperandoHumano: return "Waiting for your input."
        case .aprovacaoPendente: return "Waiting for your approval."
        case .ociosa: return "Ready for the next instruction."
        case .iniciando: return "Starting the agent session…"
        case .encerrada, .morta: return "This agent session is not running."
        case nil: return "No active session yet."
        }
    }
}

private struct ModelSelectionSheet: View {
    let agent: AgentChatAgent?
    @Binding var requestedModel: String
    let onSave: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose Codex model")
                .font(.title3.bold())
            Text("Current: \(agent?.currentModelLabel ?? "Codex default")")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Codex model ID", text: $requestedModel, prompt: Text("Leave empty for Codex default"))
                .textFieldStyle(.roundedBorder)
            Text("This changes the model for this agent only. Its isolated Codex conversation, role, workspace, and files are retained.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    let value = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(value.isEmpty ? nil : value)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
