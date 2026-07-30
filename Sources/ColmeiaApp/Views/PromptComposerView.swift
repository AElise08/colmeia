import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ColmeiaKit

/// Um rascunho fica no Mac, por workspace. Anexos são apenas referências de
/// arquivo: o compositor nunca lê nem executa seu conteúdo por conta própria.
private struct PromptDraft: Codable {
    var text: String = ""
    var recipientIDs: [String] = []
    var attachmentPaths: [String] = []
}

/// Compositor humano → agentes. Ele deixa a intenção visível antes de escrever
/// no PTY e conserva o rascunho caso a janela seja fechada.
struct PromptComposerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private let initialRecipient: ULID?
    @State private var text = ""
    @State private var recipients: Set<ULID> = []
    @State private var attachments: [URL] = []
    @State private var loaded = false
    @State private var showRecipients = false
    @State private var showSendConfirmation = false
    @State private var editor: NSTextView?

    init(initialRecipient: ULID? = nil) {
        self.initialRecipient = initialRecipient
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    recipientsBar
                    RichPromptEditor(text: $text, textView: $editor)
                        .frame(minHeight: 190, maxHeight: 360)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary, lineWidth: 1))
                    attachmentsBar
                    safetyNote
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 470)
        .background(.regularMaterial)
        .onAppear(perform: restoreDraft)
        .onDisappear(perform: saveDraft)
        .confirmationDialog(
            "Enviar para (recipients.count) agente\(recipients.count == 1 ? "" : "s")?",
            isPresented: $showSendConfirmation,
            titleVisibility: .visible
        ) {
            Button("Enviar agora") { send() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O texto será digitado nos terminais selecionados. Arquivos entram apenas como caminhos de referência.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compor prompt")
                    .font(.headline)
                Text("Rascunho salvo neste workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Fechar") { dismiss() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var recipientsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Para")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    showRecipients.toggle()
                } label: {
                    Label("Mencionar", systemImage: "at")
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showRecipients) {
                    recipientPicker
                }
            }
            if recipients.isEmpty {
                Text("Escolha ao menos um agente usando @ Mencionar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(activeAgents.filter { recipients.contains($0.id) }) { agent in
                        Button {
                            recipients.remove(agent.id)
                        } label: {
                            Label("@\(agent.name)", systemImage: "xmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(.accentColor)
                    }
                }
            }
        }
    }

    private var recipientPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mencionar agente")
                .font(.headline)
                .padding(.bottom, 4)
            if activeAgents.isEmpty {
                Text("Nenhum terminal ativo")
                    .foregroundStyle(.secondary)
            }
            ForEach(activeAgents) { agent in
                Button {
                    recipients.insert(agent.id)
                    insertMention(agent.name)
                    showRecipients = false
                } label: {
                    HStack {
                        Image(systemName: "at")
                        Text(agent.name)
                        Spacer()
                        if recipients.contains(agent.id) { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 5)
            }
        }
        .padding(14)
        .frame(width: 250)
    }

    private var attachmentsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Anexos")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    chooseAttachments()
                } label: {
                    Label("Adicionar arquivo", systemImage: "paperclip")
                }
                .buttonStyle(.bordered)
            }
            if attachments.isEmpty {
                Text("Você envia a referência do arquivo, não seu conteúdo automaticamente.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(attachments, id: \.path) { url in
                        Button {
                            attachments.removeAll { $0.path == url.path }
                        } label: {
                            Label(url.lastPathComponent, systemImage: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var safetyNote: some View {
        Label("Revise antes de enviar: o Colmeia só escreve no terminal depois da sua confirmação.", systemImage: "checkmark.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            Button("Limpar") {
                text = ""
                attachments = []
                editor?.textStorage?.setAttributedString(NSAttributedString())
            }
            .buttonStyle(.borderless)
            Spacer()
            Text("⌘↵ para enviar")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                showSendConfirmation = true
            } label: {
                Label("Enviar", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recipients.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var activeAgents: [ComposerAgent] {
        store.nodes.values.compactMap { node in
            guard case .terminal(let terminal) = node,
                  let controller = store.terminalControllers[terminal.id], controller.viva else { return nil }
            return ComposerAgent(id: terminal.id, name: terminal.nome)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var draftKey: String {
        "colmeia.prompt-draft.\(store.workspace?.id.string ?? "none")"
    }

    private func restoreDraft() {
        guard !loaded else { return }
        loaded = true
        guard let data = UserDefaults.standard.data(forKey: draftKey),
              let draft = try? JSONDecoder().decode(PromptDraft.self, from: data) else {
            if let initialRecipient { recipients.insert(initialRecipient) }
            return
        }
        text = draft.text
        recipients = Set(draft.recipientIDs.compactMap(ULID.init))
        attachments = draft.attachmentPaths.map(URL.init(fileURLWithPath:))
        if let initialRecipient { recipients.insert(initialRecipient) }
    }

    private func saveDraft() {
        guard loaded else { return }
        let draft = PromptDraft(text: text, recipientIDs: recipients.map(\.string), attachmentPaths: attachments.map(\.path))
        guard let data = try? JSONEncoder().encode(draft) else { return }
        UserDefaults.standard.set(data, forKey: draftKey)
    }

    private func insertMention(_ name: String) {
        let mention = "@\(name) "
        if let editor, let range = editor.selectedRanges.first?.rangeValue {
            editor.insertText(mention, replacementRange: range)
            text = editor.string
        } else {
            text += (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n")) ? mention : " \(mention)"
        }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.item]
        guard panel.runModal() == .OK else { return }
        attachments.append(contentsOf: panel.urls.filter { newURL in !attachments.contains(where: { $0.path == newURL.path }) })
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let reference = attachments.isEmpty ? "" : "\n\nArquivos de referência (leia somente se necessário):\n" + attachments.map { "- \($0.path)" }.joined(separator: "\n")
        let prompt = trimmed + reference
        let eligible = recipients.compactMap { id -> TerminalController? in
            guard let controller = store.terminalControllers[id], controller.viva else { return nil }
            return controller
        }
        guard !eligible.isEmpty else {
            store.avisoInfo = "Nenhum agente selecionado está com terminal ativo."
            return
        }
        eligible.forEach { $0.sendCommand(prompt) }
        text = ""
        attachments = []
        editor?.textStorage?.setAttributedString(NSAttributedString())
        UserDefaults.standard.removeObject(forKey: draftKey)
        store.avisoInfo = "Prompt enviado para \(eligible.count) agente\(eligible.count == 1 ? "" : "s")."
        dismiss()
    }
}

private struct ComposerAgent: Identifiable {
    let id: ULID
    let name: String
}

/// NSTextView oferece seleção e estilos nativos, mantendo o texto serializável
/// como rascunho simples. ⌘↵ é encaminhado pelo delegate para o botão Enviar.
private struct RichPromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var textView: NSTextView?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView()
        view.isRichText = true
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.font = .systemFont(ofSize: 15)
        view.textColor = .labelColor
        view.backgroundColor = .clear
        view.drawsBackground = false
        view.delegate = context.coordinator
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 12, height: 12)
        scroll.documentView = view
        DispatchQueue.main.async { textView = view }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichPromptEditor
        init(parent: RichPromptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

/// Layout de chips sem depender de APIs novas de Grid.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing; lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; lineHeight = max(lineHeight, size.height)
        }
    }
}
