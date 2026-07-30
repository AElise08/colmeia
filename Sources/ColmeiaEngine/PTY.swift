import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ColmeiaKit

/// PTY + processo (§9.1). Spawn sem fork manual: posix_spawn com o slave aberto por
/// file-action (open → controlling tty do novo session leader via POSIX_SPAWN_SETSID).
struct PTYHandle {
    let master: Int32
    let pid: pid_t
    let slavePath: String
}

enum PTYError: Error, CustomStringConvertible {
    case allocFailed(String, Int32)
    case spawnFailed(String, Int32)

    var description: String {
        switch self {
        case .allocFailed(let what, let code):
            return "pty \(what): \(String(cString: strerror(code)))"
        case .spawnFailed(let exec, let code):
            return "spawn \(exec): \(String(cString: strerror(code)))"
        }
    }
}

enum PTY {
    // spawn.h: valores estáveis do Darwin; nem todos os defines chegam ao Swift.
    private static let POSIX_SPAWN_SETSID_FLAG: Int16 = 0x0400
    private static let POSIX_SPAWN_CLOEXEC_DEFAULT_FLAG: Int16 = 0x4000

    static func spawn(
        executable: String,
        args: [String],
        environment: [String: String],
        cwd: String,
        cols: Int,
        rows: Int
    ) throws -> PTYHandle {
        let resolvedExecutable = executablePath(executable, environment: environment) ?? executable
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw PTYError.allocFailed("posix_openpt", errno) }
        guard grantpt(master) == 0, unlockpt(master) == 0, let slaveC = ptsname(master) else {
            let code = errno
            close(master)
            throw PTYError.allocFailed("grantpt/unlockpt", code)
        }
        let slavePath = String(cString: slaveC)

        var ws = winsize(
            ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols),
            ws_xpixel: 0, ws_ypixel: 0)
        // No Darwin, configurar apenas o master antes da primeira abertura do
        // slave não basta: a abertura feita pela file-action pode reinicializar
        // a geometria para 0×0. Pré-abrir o slave sem adquirir controlling tty,
        // aplicar nele e fechar preserva o winsize que o filho verá no primeiro
        // ioctl — antes de o TUI ter qualquer chance de desenhar.
        let sizingSlave = open(slavePath, O_RDWR | O_NOCTTY)
        guard sizingSlave >= 0 else {
            let code = errno
            close(master)
            throw PTYError.allocFailed("open slave for sizing", code)
        }
        let sizingResult = ioctl(sizingSlave, TIOCSWINSZ, &ws)
        let sizingError = errno
        guard sizingResult == 0 else {
            close(sizingSlave)
            close(master)
            throw PTYError.allocFailed("TIOCSWINSZ slave", sizingError)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // open (não dup) do slave: session leader sem ctty adquire o pty como controlling terminal.
        posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&fileActions, cwd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID_FLAG | POSIX_SPAWN_CLOEXEC_DEFAULT_FLAG)

        var argv: [UnsafeMutablePointer<CChar>?] = ([resolvedExecutable] + args).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, resolvedExecutable, &fileActions, &attr, argv, envp)
        guard rc == 0 else {
            close(sizingSlave)
            close(master)
            throw PTYError.spawnFailed(resolvedExecutable, rc)
        }
        // posix_spawn só retorna depois de aplicar o addopen do slave no filho.
        // Até aqui o descritor auxiliar precisa permanecer aberto: fechar o
        // último slave antes do spawn faz o Darwin voltar a geometria para 0×0.
        close(sizingSlave)
        // Também mantém o master sincronizado para resizes imediatamente após
        // o spawn; neste ponto o slave já foi aberto pelo processo.
        _ = ioctl(master, TIOCSWINSZ, &ws)
        return PTYHandle(master: master, pid: pid, slavePath: slavePath)
    }

    static func writeAll(fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    static func resize(master: Int32, pid: pid_t, cols: Int, rows: Int) {
        var ws = winsize(
            ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols),
            ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &ws)
        _ = kill(-pid, SIGWINCH)
    }

    static func size(master: Int32) -> (cols: Int, rows: Int)? {
        var ws = winsize()
        guard ioctl(master, TIOCGWINSZ, &ws) == 0 else { return nil }
        return (Int(ws.ws_col), Int(ws.ws_row))
    }

    /// Sinaliza o grupo (o filho é session leader: pgid == pid); fallback para o pid.
    static func signal(pid: pid_t, _ sig: Int32) {
        if kill(-pid, sig) != 0 {
            _ = kill(pid, sig)
        }
    }

    static func isAlive(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
