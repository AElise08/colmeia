import Foundation
import Darwin

/// Rastreia PIDs de processos filho para o signal handler de SIGTERM.
/// Usa `os_unfair_lock` porque o signal handler (async-signal-safe) lê.
enum ChildPIDTracker {
    private static var pids: [Int32] = []
    private static var lock = os_unfair_lock()

    static func add(_ pid: Int32) {
        os_unfair_lock_lock(&lock)
        pids.append(pid)
        os_unfair_lock_unlock(&lock)
    }

    static func remove(_ pid: Int32) {
        os_unfair_lock_lock(&lock)
        pids.removeAll { $0 == pid }
        os_unfair_lock_unlock(&lock)
    }

    /// Cópia para o signal handler.
    static func all() -> [Int32] {
        os_unfair_lock_lock(&lock)
        let copy = pids
        os_unfair_lock_unlock(&lock)
        return copy
    }
}
