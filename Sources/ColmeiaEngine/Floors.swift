import Foundation
import ColmeiaKit

/// git síncrono via Process — usado só nas operações de andar (§16), que são raras.
enum Git {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    @discardableResult
    static func run(_ args: [String], cwd: String?) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: 127, stdout: "", stderr: "\(error)")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    static func isRepo(_ path: String) -> Bool {
        run(["-C", path, "rev-parse", "--is-inside-work-tree"], cwd: nil)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// §16.3 — mudanças não commitadas (staged, unstaged ou untracked) = sujo.
    static func isDirty(_ worktree: String) -> Bool {
        let result = run(["-C", worktree, "status", "--porcelain"], cwd: nil)
        guard result.status == 0 else { return true }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum FloorPaths {
    /// §16.1 — `<caminho_raiz>/../<repo>-andares/<nome-sanitizado>`.
    static func base(caminhoRaiz: String) -> String {
        let raiz = URL(fileURLWithPath: caminhoRaiz).standardizedFileURL
        let repo = raiz.lastPathComponent
        return raiz.deletingLastPathComponent().appendingPathComponent("\(repo)-andares").path
    }

    static func worktree(caminhoRaiz: String, nomeSanitizado: String) -> String {
        URL(fileURLWithPath: base(caminhoRaiz: caminhoRaiz))
            .appendingPathComponent(nomeSanitizado).path
    }
}
