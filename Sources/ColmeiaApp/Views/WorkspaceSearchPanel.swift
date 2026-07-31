import SwiftUI
import AppKit
import ColmeiaKit

/// Busca transversal no canvas e na árvore de arquivos do workspace.
struct WorkspaceSearchPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var fileResults: [FileSearchResult] = []
    @State private var historyResults: [WorkspaceHistorySearchResult] = []
    @State private var isSearchingFiles = false

    private struct FileSearchResult: Identifiable, Equatable, Sendable {
        let id: String
        let url: URL
        let relativePath: String
        let match: String
    }

    private var results: [(id: ULID, title: String, detail: String, symbol: String)] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return store.nodes.values.sorted { store.nodeName($0.id) < store.nodeName($1.id) }.map(result)
        }
        return store.nodes.values
            .filter { searchableText(for: $0).lowercased().contains(normalized) }
            .sorted { store.nodeName($0.id) < store.nodeName($1.id) }
            .map(result)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar nós, notas, arquivos e URLs", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { openFirst() }
                }
                .padding(11)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .padding(12)

                if results.isEmpty && fileResults.isEmpty && historyResults.isEmpty && !isSearchingFiles {
                    ContentUnavailableView("Nenhum resultado", systemImage: "magnifyingglass", description: Text("Tente outro termo."))
                } else {
                    List {
                        if !results.isEmpty {
                            Section("Canvas") {
                                ForEach(results, id: \.id) { item in
                                    Button {
                                        store.focus(nodeID: item.id)
                                        dismiss()
                                    } label: {
                                        Label {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.title)
                                                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                        } icon: {
                                            Image(systemName: item.symbol).foregroundStyle(.tint)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if isSearchingFiles || !fileResults.isEmpty {
                            Section("Arquivos e histórico local") {
                                if isSearchingFiles { ProgressView().controlSize(.small) }
                                ForEach(fileResults) { item in
                                    Button { NSWorkspace.shared.open(item.url) } label: {
                                        Label {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.relativePath).lineLimit(1)
                                                Text(item.match).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                        } icon: {
                                            Image(systemName: "doc.text").foregroundStyle(.tint)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if !historyResults.isEmpty {
                            Section("Histórico do Engine") {
                                ForEach(historyResults) { item in
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    } icon: {
                                        Image(systemName: item.symbol).foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Buscar no workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .task(id: query) {
            await searchFiles()
            historyResults = await store.searchWorkspaceHistory(query)
        }
    }

    private func openFirst() {
        if let first = results.first {
            store.focus(nodeID: first.id)
            dismiss()
        } else if let first = fileResults.first {
            NSWorkspace.shared.open(first.url)
            dismiss()
        }
    }

    private func searchableText(for node: Node) -> String {
        switch node {
        case .terminal(let terminal):
            return [terminal.nome, terminal.papel, terminal.adapter, terminal.cwd].compactMap { $0 }.joined(separator: " ")
        case .nota(let note):
            return [store.nodeName(note.id), store.notaControllers[note.id]?.texto, note.arquivo].compactMap { $0 }.joined(separator: " ")
        case .desenho(let drawing):
            return [store.nodeName(drawing.id), drawing.texto].compactMap { $0 }.joined(separator: " ")
        case .portal(let portal):
            return [store.nodeName(portal.id), portal.titulo, portal.url].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func result(_ node: Node) -> (id: ULID, title: String, detail: String, symbol: String) {
        switch node {
        case .terminal(let terminal):
            return (terminal.id, terminal.nome, terminal.papel ?? terminal.adapter, "terminal")
        case .nota(let note):
            return (note.id, store.nodeName(note.id), note.arquivo, "note.text")
        case .desenho(let drawing):
            return (drawing.id, store.nodeName(drawing.id), drawing.texto ?? "Desenho", "pencil.tip")
        case .portal(let portal):
            return (portal.id, portal.titulo ?? portal.url, portal.url, "globe")
        }
    }

    private func searchFiles() async {
        fileResults = []
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty, let rootPath = store.workspace?.caminhoRaiz,
              !rootPath.isEmpty else { return }
        isSearchingFiles = true
        defer { isSearchingFiles = false }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let found = await Task.detached(priority: .userInitiated) { () -> [FileSearchResult] in
            let manager = FileManager.default
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { return [] }
            var output: [FileSearchResult] = []
            let ignored = [".git", ".maestri", ".build", "node_modules", "DerivedData"]
            while let item = enumerator.nextObject(), let url = item as? URL {
                if Task.isCancelled || output.count >= 100 { break }
                if url.pathComponents.contains(where: { ignored.contains($0) }) { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let nameHit = relative.lowercased().contains(term)
                var match = nameHit ? "nome do arquivo" : ""
                if !nameHit, (values?.fileSize ?? 0) <= 512_000,
                   let data = try? Data(contentsOf: url),
                   let text = String(data: data, encoding: .utf8),
                   let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                    let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
                    let end = text.index(range.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
                    match = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
                }
                guard !match.isEmpty else { continue }
                output.append(FileSearchResult(id: url.path, url: url, relativePath: relative, match: match))
            }
            return output
        }.value
        guard !Task.isCancelled else { return }
        fileResults = found
    }
}
