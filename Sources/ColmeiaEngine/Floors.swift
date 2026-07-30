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

    /// `git worktree add` precisa de um commit para materializar o checkout.
    /// Repositórios recém-inicializados ainda são um caso válido para andar via
    /// clone isolado, mas não podem usar o mecanismo de worktree.
    static func hasHead(_ path: String) -> Bool {
        run(["-C", path, "rev-parse", "--verify", "HEAD"], cwd: nil).status == 0
    }

    /// §16.3 — mudanças não commitadas (staged, unstaged ou untracked) = sujo.
    static func isDirty(_ worktree: String) -> Bool {
        let result = run(["-C", worktree, "status", "--porcelain"], cwd: nil)
        guard result.status == 0 else { return true }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Cópia isolada para workspaces sem histórico Git. Em APFS, `cp -cR` cria clones
/// copy-on-write; o fallback de Foundation mantém o comportamento correto em
/// volumes que não oferecem clonefile (por exemplo, um volume externo).
enum DirectoryClone {
    static func copy(from source: String, to destination: String) throws {
        let fm = FileManager.default
        var sourceIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source, isDirectory: &sourceIsDirectory), sourceIsDirectory.boolValue else {
            throw ProtocolError(name: .invalid_params, message: "caminho raiz do workspace não é um diretório")
        }
        guard !fm.fileExists(atPath: destination) else {
            throw ProtocolError(name: .invalid_params, message: "já existe andar em \(destination)")
        }

        let destinationURL = URL(fileURLWithPath: destination).standardizedFileURL
        let temporary = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).clone-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-cR", source, temporary.path]
        process.standardInput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        var clonedWithAPFS = false
        do {
            try process.run()
            process.waitUntilExit()
            clonedWithAPFS = process.terminationStatus == 0
        } catch {
            // O fallback abaixo dá uma mensagem de erro útil ao protocolo.
        }

        if !clonedWithAPFS {
            try? fm.removeItem(at: temporary)
            do {
                try fm.copyItem(atPath: source, toPath: temporary.path)
            } catch {
                let message = String(
                    decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ProtocolError(
                    name: .internal_error,
                    message: "não foi possível clonar o andar\(message.isEmpty ? "" : ": \(message)")")
            }
        }
        try fm.moveItem(at: temporary, to: destinationURL)
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
