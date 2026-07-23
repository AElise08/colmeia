import SwiftUI
import AppKit
import ColmeiaKit

/// Raiz de dependências fora do ciclo de vida SwiftUI: os Commands do menu precisam
/// alcançar o mesmo store da janela.
@MainActor
enum AppEnvironmentHolder {
    static let connection = EngineConnection()
    static let store = AppStore(connection: connection)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Executável SPM sem Info.plist não vira app de verdade sem isso.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ColmeiaCanvasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var store: AppStore { AppEnvironmentHolder.store }

    init() {
        let store = AppEnvironmentHolder.store
        store.notifications.onNavigateToNode = { [weak store] nodeID in
            store?.focus(nodeID: nodeID)
        }
        store.notifications.requestPermission()
        AppEnvironmentHolder.connection.start()
    }

    var body: some Scene {
        WindowGroup("Colmeia") {
            ContentView()
                .environmentObject(store)
                .environmentObject(AppEnvironmentHolder.connection)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Desfazer") { store.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!store.canUndo)
                Button("Refazer") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("Novo Terminal…") { store.showNewTerminal = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Nova Nota") { store.addNota() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Canvas") {
                // ⌘= é o "⌘+" físico em teclados ANSI/ABNT.
                Button("Ampliar") { store.zoom(by: 1.25) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Reduzir") { store.zoom(by: 0.8) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Zoom 100%") { store.zoomReset() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Fila de Aprovações") { store.showApprovals.toggle() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Rotinas…") { store.showRoutines.toggle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Abrir no Editor") { abrirNoEditor() }
                    .keyboardShortcut("e", modifiers: .command)
            }
        }
    }

    /// ⌘E — cwd do nó selecionado, senão caminho_raiz do workspace (§18.7).
    private func abrirNoEditor() {
        if let selection = store.selection, case .terminal(let t)? = store.nodes[selection] {
            EditorOpener.abrir(caminho: t.cwd)
        } else if let raiz = store.workspace?.caminhoRaiz {
            EditorOpener.abrir(caminho: raiz)
        }
    }
}
