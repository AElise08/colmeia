import Foundation
import AppKit

/// §18.7 — abrir o cwd do nó (ou caminho_raiz) no editor: detecção dos instalados
/// + preferência da usuária, via `open -b`.
enum EditorOpener {
    struct Editor: Identifiable, Equatable {
        let id: String
        let nome: String
    }

    static let conhecidos: [Editor] = [
        Editor(id: "com.microsoft.VSCode", nome: "VS Code"),
        Editor(id: "dev.zed.Zed", nome: "Zed"),
        Editor(id: "com.apple.dt.Xcode", nome: "Xcode"),
    ]

    private static let prefKey = "colmeia.editor-preferido"

    static var instalados: [Editor] {
        conhecidos.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil
        }
    }

    static var preferido: Editor? {
        get {
            let disponiveis = instalados
            if let saved = UserDefaults.standard.string(forKey: prefKey),
               let editor = disponiveis.first(where: { $0.id == saved }) {
                return editor
            }
            return disponiveis.first
        }
        set {
            UserDefaults.standard.set(newValue?.id, forKey: prefKey)
        }
    }

    static func abrir(caminho: String, editor: Editor? = nil) {
        guard let alvo = editor ?? preferido else {
            NSWorkspace.shared.open(URL(fileURLWithPath: caminho))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", alvo.id, caminho]
        try? process.run()
    }
}
