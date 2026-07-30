import Foundation
import Darwin

@MainActor
final class RemoteEngineTunnel {
    private var process: Process?
    private var retryTask: Task<Void, Never>?
    private var stopping = false

    func start() {
        guard ProcessInfo.processInfo.environment["COLMEIA_REMOTE_SSH_TARGET"] != nil else { return }
        guard process == nil, retryTask == nil else { return }
        stopping = false
        launch()
    }

    func stop() {
        stopping = true
        retryTask?.cancel()
        retryTask = nil
        if let proc = process {
            let pid = proc.processIdentifier
            ChildPIDTracker.remove(pid)
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
                let deadline = Date().addingTimeInterval(3)
                while proc.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if proc.isRunning {
                    kill(pid, SIGKILL)
                    Thread.sleep(forTimeInterval: 0.1)
                    var status: Int32 = 0
                    waitpid(pid, &status, WNOHANG)
                }
            }
        }
        process = nil
    }

    private func launch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-N",
            "-R", "9622:localhost:9622",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            ProcessInfo.processInfo.environment["COLMEIA_REMOTE_SSH_TARGET"]!,
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopping else { return }
                self.process = nil
                self.retryTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, !self.stopping else { return }
                    self.retryTask = nil
                    self.launch()
                }
            }
        }
        do {
            try task.run()
            process = task
            ChildPIDTracker.add(task.processIdentifier)
        } catch {
            process = nil
            retryTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, !stopping else { return }
                retryTask = nil
                launch()
            }
        }
    }
}
