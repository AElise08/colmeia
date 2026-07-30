import Foundation
import Darwin

@MainActor
final class RemoteWorkspaceSync {
    private var process: Process?
    private var retryTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var logHandle: FileHandle?
    private var stopping = false

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .colmeiaHubConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restart()
            }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func start() {
        guard process == nil, retryTask == nil else { return }
        stopping = false
        launch()
    }

    func stop() {
        stopping = true
        retryTask?.cancel()
        retryTask = nil
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
        logHandle?.closeFile()
        logHandle = nil
    }

    private func restart() {
        stop()
        stopping = false
        launch()
    }

    private func launch() {
        guard let token = HubConnection.savedHubToken,
              let endpoint = Self.endpoint(from: HubConnection.savedHubURL),
              let binary = Self.findBinary() else { return }

        let task = Process()
        task.executableURL = binary
        task.arguments = [endpoint.host, String(endpoint.port)]
        var environment = ProcessInfo.processInfo.environment
        environment["COLMEIA_HUB_TOKEN"] = token
        task.environment = environment

        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Colmeia/sync.log")
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()
        task.standardOutput = logHandle ?? FileHandle.nullDevice
        task.standardError = logHandle ?? FileHandle.nullDevice
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopping else { return }
                ChildPIDTracker.remove(task.processIdentifier)
                self.process = nil
                self.logHandle?.closeFile()
                self.logHandle = nil
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

    private static func endpoint(from rawURL: String) -> (host: String, port: UInt16)? {
        let normalized = rawURL.contains("://") ? rawURL : "wss://\(rawURL)"
        guard let components = URLComponents(string: normalized),
              let host = components.host else { return nil }
        return (host, UInt16(components.port ?? 9620))
    }

    private static func findBinary() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("colmeia-sync"))
        }
        let project = fm.homeDirectoryForCurrentUser.appendingPathComponent("app/colmeia-canvas/.build")
        candidates.append(project.appendingPathComponent("arm64-apple-macosx/release/colmeia-sync"))
        candidates.append(project.appendingPathComponent("arm64-apple-macosx/debug/colmeia-sync"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
