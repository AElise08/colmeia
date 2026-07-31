import SwiftUI
import AppKit
import Darwin
import ColmeiaKit

extension Notification.Name {
    static let colmeiaOpenRooms = Notification.Name("com.mel.colmeia.openRooms")
    static let colmeiaShowCanvas = Notification.Name("com.mel.colmeia.showCanvas")
    static let colmeiaShowAgentChat = Notification.Name("com.mel.colmeia.showAgentChat")
    static let colmeiaShowNow = Notification.Name("com.mel.colmeia.showNow")
    static let colmeiaShowAttention = Notification.Name("com.mel.colmeia.showAttention")
    static let colmeiaCreateWorkspace = Notification.Name("com.mel.colmeia.createWorkspace")
}

@MainActor
enum AppEnvironmentHolder {
    static let connection = EngineConnection()
    static let store = AppStore(connection: connection)
    static let remoteSync = RemoteWorkspaceSync()
    static let hub = HubConnection()
    static let presence = CollaborationPresenceStore(hub: hub)
}

/// Signal handler — só async-signal-safe. Mata filhos e propaga o sinal.
private func handleSignal(_ signo: Int32) {
    signal(SIGTERM, SIG_DFL)
    signal(SIGINT, SIG_DFL)
    for pid in ChildPIDTracker.all() {
        kill(pid, SIGTERM)
        usleep(50_000)
        var status: Int32 = 0
        waitpid(pid, &status, WNOHANG)
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            waitpid(pid, &status, WNOHANG)
        }
    }
    kill(getpid(), signo)
}



final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        signal(SIGTERM, handleSignal)
        signal(SIGINT, handleSignal)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironmentHolder.remoteSync.stop()
        AppEnvironmentHolder.hub.stop()
        AppEnvironmentHolder.connection.stop()
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
        store.notifications.onNavigateToDestination = { [weak store] destination in
            guard let store else { return }
            Task {
                if let workspaceID = destination.workspaceID,
                   store.workspace?.id != workspaceID {
                    await store.open(workspaceID: workspaceID)
                }
                if destination.workspaceID != nil {
                    if let floorID = destination.floorID,
                       store.activeFloor?.id != floorID,
                       let floor = store.floors.first(where: { $0.id == floorID }) {
                        await store.switchFloor(floor)
                    } else if destination.floorID == nil, store.activeFloor != nil {
                        await store.switchFloor(nil)
                    }
                }
                if let nodeID = destination.nodeID {
                    store.focus(nodeID: nodeID)
                }
            }
        }
        store.notifications.requestPermission()
        AppEnvironmentHolder.presence.onOpenWorkspace = { workspaceID in
            if AppEnvironmentHolder.store.workspace?.id != workspaceID {
                await AppEnvironmentHolder.store.open(workspaceID: workspaceID)
            }
        }
        AppEnvironmentHolder.presence.onFocusNode = { nodeID in
            AppEnvironmentHolder.store.focus(nodeID: nodeID)
        }
        AppEnvironmentHolder.connection.start()
        AppEnvironmentHolder.remoteSync.start()
        AppEnvironmentHolder.hub.start()
    }

    var body: some Scene {
        WindowGroup("Colmeia") {
            ContentView()
                .environmentObject(store)
                .environmentObject(AppEnvironmentHolder.connection)
                .environmentObject(AppEnvironmentHolder.hub)
                .environmentObject(AppEnvironmentHolder.presence)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { url in
                    guard url.scheme == "colmeia", url.host == "join" else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    Task { await AppEnvironmentHolder.presence.handleDeepLink(url) }
                    NotificationCenter.default.post(name: .colmeiaOpenRooms, object: url)
                }
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Desfazer") { store.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!store.canUndo)
                Button("Refazer") { store.redo() }
                    .keyboardShortcut("Z", modifiers: .command)
                    .disabled(!store.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("Novo Terminal…") { store.presentNewTerminal(adapter: store.newTerminalAdapter) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Nova Nota") { store.addNota() }
                    .keyboardShortcut("N", modifiers: .command)
                Button("Novo Portal") { store.showNewPortal = true }
                    .keyboardShortcut("P", modifiers: .command)
            }
            CommandMenu("Canvas") {
                Button("Canvas") {
                    NotificationCenter.default.post(name: .colmeiaShowCanvas, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("Agent Chat") {
                    NotificationCenter.default.post(name: .colmeiaShowAgentChat, object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)
                Button("Atenção") {
                    NotificationCenter.default.post(name: .colmeiaShowAttention, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                Button("Agora") {
                    NotificationCenter.default.post(name: .colmeiaShowNow, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Ampliar") { store.zoom(by: 1.25) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Reduzir") { store.zoom(by: 0.8) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Zoom 100%") { store.zoomReset() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Fila de Aprovações") { store.showApprovals.toggle() }
                    .keyboardShortcut("A", modifiers: .command)
                Button("Rotinas…") { store.showRoutines.toggle() }
                    .keyboardShortcut("R", modifiers: .command)
                Divider()
                Button("Abrir no Editor") { abrirNoEditor() }
                    .keyboardShortcut("e", modifiers: .command)
            }
        }
    }

    private func abrirNoEditor() {
        if let selection = store.selection, case .terminal(let t)? = store.nodes[selection] {
            EditorOpener.abrir(caminho: t.cwd)
        } else if let raiz = store.workspace?.caminhoRaiz {
            EditorOpener.abrir(caminho: raiz)
        }
    }
}
