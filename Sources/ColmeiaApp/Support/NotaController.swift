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
