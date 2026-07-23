import Foundation
import Darwin
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
        _ = ioctl(master, TIOCSWINSZ, &ws)

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

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, executable, &fileActions, &attr, argv, envp)
        guard rc == 0 else {
            close(master)
            throw PTYError.spawnFailed(executable, rc)
        }
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
