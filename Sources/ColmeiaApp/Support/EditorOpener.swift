import Foundation
import AppKit

/// §18.7 — abrir o cwd do nó (ou caminho_raiz) no editor: detecção dos instalados
/// + preferência da usuária, via `open -b`.
enum EditorOpener {
    struct Editor: Identifiable, Equatable {
        let id: String
        let nome: String
    }

    static let appPadrao = Editor(id: "__default__", nome: "App padrão do macOS")

    static let conhecidos: [Editor] = [
        Editor(id: "com.todesktop.230313mzl4w4u92", nome: "Cursor"),
        Editor(id: "com.exafunction.windsurf", nome: "Windsurf"),
        Editor(id: "com.microsoft.VSCode", nome: "VS Code"),
        Editor(id: "dev.zed.Zed", nome: "Zed"),
        Editor(id: "com.apple.dt.Xcode", nome: "Xcode"),
        Editor(id: "com.sublimetext.4", nome: "Sublime Text"),
        Editor(id: "com.barebones.bbedit", nome: "BBEdit"),
        Editor(id: "com.apple.TextEdit", nome: "TextEdit"),
    ]

    private static let prefKey = "colmeia.editor-preferido"

    static var instalados: [Editor] {
        conhecidos.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil
        }
    }

    /// Escolha EXPLÍCITA da usuária. É diferente do editor efetivo: quando nil,
    /// `preferido` usa a detecção automática, mas a UI continua podendo marcar
    /// corretamente "Detecção automática" em vez de fingir que o primeiro app
    /// encontrado foi escolhido (§18.7).
    static var preferenciaExplicita: Editor? {
        guard let saved = UserDefaults.standard.string(forKey: prefKey) else { return nil }
        if saved == appPadrao.id { return appPadrao }
        return instalados.first(where: { $0.id == saved })
    }

    static var preferido: Editor? {
        get {
            preferenciaExplicita ?? instalados.first
        }
        set {
            UserDefaults.standard.set(newValue?.id, forKey: prefKey)
        }
    }

    static func usarDeteccaoAutomatica() {
        UserDefaults.standard.removeObject(forKey: prefKey)
    }

    static func abrir(caminho: String, editor: Editor? = nil) {
        guard let alvo = editor ?? preferido else {
            NSWorkspace.shared.open(URL(fileURLWithPath: caminho))
            return
        }
        if alvo.id == appPadrao.id {
            NSWorkspace.shared.open(URL(fileURLWithPath: caminho))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", alvo.id, caminho]
        try? process.run()
    }
}
