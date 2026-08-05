import Foundation
import ColmeiaKit

public final class DeployStore: @unchecked Sendable {
    private struct Snapshot: Codable {
        var schemaVersion: Int
        var targets: [DeployTarget]
        var requests: [DeployRequest]
        enum CodingKeys: String, CodingKey {
            case targets, requests
            case schemaVersion = "schema_version"
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var targets: [ULID: DeployTarget] = [:]
    private var requests: [ULID: DeployRequest] = [:]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let snapshot = try AtomicJSON.read(Snapshot.self, from: fileURL)
        targets = Dictionary(uniqueKeysWithValues: snapshot.targets.map { ($0.id, $0) })
        requests = Dictionary(uniqueKeysWithValues: snapshot.requests.map { ($0.id, $0) })
    }

    public func register(_ target: DeployTarget) throws -> DeployTarget {
        lock.lock(); defer { lock.unlock() }
        targets[target.id] = target
        try persist()
        return target
    }

    public func targets(workspaceID: ULID) -> [DeployTarget] {
        lock.lock(); defer { lock.unlock() }
        return targets.values.filter { $0.workspaceID == workspaceID }.sorted { $0.name < $1.name }
    }

    public func target(id: ULID) -> DeployTarget? {
        lock.lock(); defer { lock.unlock() }; return targets[id]
    }

    public func add(_ request: DeployRequest) throws -> DeployRequest {
        lock.lock(); defer { lock.unlock() }
        if let existing = requests[request.id] { return existing }
        requests[request.id] = request
        try persist()
        return request
    }

    public func request(id: ULID) -> DeployRequest? {
        lock.lock(); defer { lock.unlock() }; return requests[id]
    }

    public func update(_ request: DeployRequest) throws -> DeployRequest {
        lock.lock(); defer { lock.unlock() }
        requests[request.id] = request
        try persist()
        return request
    }

    public func requests(workspaceID: ULID) -> [DeployRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.values.filter { $0.workspaceID == workspaceID }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() throws {
        try AtomicJSON.write(Snapshot(schemaVersion: 1, targets: Array(targets.values), requests: Array(requests.values)), to: fileURL)
    }
}
