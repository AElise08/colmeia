import Foundation
import ColmeiaKit

/// Conteúdo da nota vive em `notes/<node-id>.md` (§5.2.2) e o protocolo §6.4 não tem
/// método de leitura/escrita para humanos — a UI age como "editor externo", que a spec
/// sanciona (§15.1: notas editáveis fora do app). Edições externas são refletidas via
/// watch de arquivo (DEVE §15.1).
@MainActor
final class NotaController: ObservableObject {
    let nodeID: ULID
    private let fileURL: URL

    @Published var texto: String = ""
    @Published var editando = false

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var saveTask: Task<Void, Never>?

    init(node: NotaNode, workspaceID: ULID) {
        self.nodeID = node.id
        self.fileURL = ColmeiaPaths().workspaceDir(workspaceID).appendingPathComponent(node.arquivo)
        reloadFromDisk()
        startWatching()
    }

    deinit {
        if watchedFD >= 0 {
            watcher?.cancel()
        }
    }

    func reloadFromDisk() {
        guard !editando else { return }
        texto = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func textoEditado(_ novo: String) {
        texto = novo
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    func persist() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? texto.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Alterna `- [ ]`/`- [x]` na linha (0-based) e persiste no .md — o caminho de
    /// "editor externo" sancionado pela §15.1. Retorna true se a linha era uma tarefa.
    @discardableResult
    func toggleTarefa(linha: Int) -> Bool {
        var linhas = texto.components(separatedBy: "\n")
        guard linhas.indices.contains(linha),
              let alterada = Self.alternarCheckbox(linhas[linha]) else { return false }
        linhas[linha] = alterada
        texto = linhas.joined(separator: "\n")
        persist()
        return true
    }

    static func alternarCheckbox(_ linha: String) -> String? {
        guard let abre = linha.range(of: #"^\s*[-*]\s+\["#, options: .regularExpression) else { return nil }
        let resto = linha[abre.upperBound...]
        guard let fecha = resto.firstIndex(of: "]") else { return nil }
        let estado = linha[abre.upperBound..<fecha].trimmingCharacters(in: .whitespaces).lowercased()
        guard estado.isEmpty || estado == "x" else { return nil }
        return linha.replacingCharacters(in: abre.upperBound..<fecha, with: estado == "x" ? " " : "x")
    }

    private func startWatching() {
        stopWatching()
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reloadFromDisk()
            if self.watcher?.data.contains(.rename) == true || self.watcher?.data.contains(.delete) == true {
                self.startWatching()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watchedFD = -1
    }
}
