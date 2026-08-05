import Foundation
import ColmeiaKit

public enum TelemetryStoreError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidPath(String)

    public var description: String {
        switch self {
        case .invalidPath(let path): return "telemetry path inválido: \(path)"
        }
    }
}

/// JSONL local de telemetria. O arquivo contém somente eventos normalizados;
/// payload de prompt, output bruto, PTY, cookies e secrets nunca entram aqui.
public final class TelemetryStore: @unchecked Sendable {
    private struct Line: Codable, Equatable {
        var schemaVersion: Int
        var kind: String
        var id: ULID
        var usage: UsageSample?
        var file: FileActivityEvent?
        var connection: ConnectionActivityEvent?
        var portal: PortalActivityEvent?

        enum CodingKeys: String, CodingKey {
            case kind, id, usage, file, connection, portal
            case schemaVersion = "schema_version"
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var lines: [ULID: Line] = [:]

    public init(fileURL: URL) throws {
        guard !fileURL.path.isEmpty else { throw TelemetryStoreError.invalidPath(fileURL.path) }
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        load()
    }

    public var url: URL { fileURL }

    @discardableResult
    public func append(_ sample: UsageSample) throws -> Bool {
        try append(Line(schemaVersion: 1, kind: "usage", id: sample.id, usage: sample,
                        file: nil, connection: nil, portal: nil))
    }

    @discardableResult
    public func append(_ event: FileActivityEvent) throws -> Bool {
        try append(Line(schemaVersion: 1, kind: "file", id: event.id, usage: nil,
                        file: event, connection: nil, portal: nil))
    }

    @discardableResult
    public func append(_ event: ConnectionActivityEvent) throws -> Bool {
        try append(Line(schemaVersion: 1, kind: "connection", id: event.id, usage: nil,
                        file: nil, connection: event, portal: nil))
    }

    @discardableResult
    public func append(_ event: PortalActivityEvent) throws -> Bool {
        try append(Line(schemaVersion: 1, kind: "portal", id: event.id, usage: nil,
                        file: nil, connection: nil, portal: event))
    }

    public func usage(
        workspaceID: ULID, nodeID: ULID? = nil, sessionID: ULID? = nil,
        from: Date? = nil, until: Date? = nil, limit: Int = 500
    ) -> [UsageSample] {
        lock.lock(); defer { lock.unlock() }
        return lines.values.compactMap { $0.usage }
            .filter { sample in
                sample.workspaceID == workspaceID
                    && (nodeID == nil || sample.nodeID == nodeID)
                    && (sessionID == nil || sample.sessionID == sessionID)
                    && (from == nil || sample.recordedAt >= from!)
                    && (until == nil || sample.recordedAt <= until!)
            }
            .sorted { $0.recordedAt > $1.recordedAt }
            .prefix(max(1, min(10_000, limit)))
            .map { $0 }
    }

    public func fileActivity(
        workspaceID: ULID, nodeID: ULID? = nil, from: Date? = nil,
        until: Date? = nil, limit: Int = 500
    ) -> [FileActivityEvent] {
        lock.lock(); defer { lock.unlock() }
        return lines.values.compactMap { $0.file }
            .filter { event in
                event.workspaceID == workspaceID
                    && (nodeID == nil || event.nodeID == nodeID)
                    && (from == nil || event.startedAt >= from!)
                    && (until == nil || event.startedAt <= until!)
            }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(max(1, min(10_000, limit)))
            .map { $0 }
    }

    public func portalActivity(
        workspaceID: ULID, nodeID: ULID? = nil, from: Date? = nil,
        until: Date? = nil, limit: Int = 500
    ) -> [PortalActivityEvent] {
        lock.lock(); defer { lock.unlock() }
        return lines.values.compactMap { $0.portal }
            .filter { event in
                event.workspaceID == workspaceID
                    && (nodeID == nil || event.nodeID == nodeID)
                    && (from == nil || event.recordedAt >= from!)
                    && (until == nil || event.recordedAt <= until!)
            }
            .sorted { $0.recordedAt > $1.recordedAt }
            .prefix(max(1, min(10_000, limit)))
            .map { $0 }
    }

    public func snapshot(
        workspaceID: ULID,
        windowStart: Date? = nil,
        pricing: TelemetryPricingTable = TelemetryPricingTable(),
        budget: TelemetryBudget? = nil,
        agentNames: [ULID: String] = [:],
        now: Date = Date()
    ) -> TelemetrySnapshot {
        let samples = usage(workspaceID: workspaceID, from: windowStart, limit: 10_000)
        let activeSeconds = samples.reduce(0) { $0 + $1.durationSeconds }
        let knownTokens = samples.compactMap { $0.totalTokens }.reduce(0, +)
        let completeTokens = !samples.isEmpty && samples.allSatisfy { $0.totalTokens != nil }
        let costs = samples.map { sample -> Double? in
            sample.estimatedCost ?? pricing.price(provider: sample.provider, model: sample.model)?.cost(for: sample)
        }
        let completeCosts = !samples.isEmpty && costs.allSatisfy { $0 != nil }
        let totalCost = completeCosts ? costs.compactMap { $0 }.reduce(0, +) : nil
        let source = aggregateSource(samples)
        let earliest = samples.map { $0.startedAt }.min()
        let latest = samples.compactMap { $0.endedAt ?? $0.recordedAt }.max() ?? now
        let elapsed = max(0, latest.timeIntervalSince(windowStart ?? earliest ?? now))
        let budgetPercent: Double? = {
            guard let budget, let limit = budget.limit, limit > 0, let totalCost else { return nil }
            return totalCost / limit
        }()
        let alerts = budgetPercent.map { percent in
            (budget?.warningThresholds ?? []).filter { percent >= $0 }.map { "budget_\(Int($0 * 100))" }
        } ?? []

        let byAgent = Dictionary(grouping: samples, by: { $0.nodeID })
            .map { nodeID, values in
                let agentCosts = values.map { sample -> Double? in
                    sample.estimatedCost ?? pricing.price(provider: sample.provider, model: sample.model)?.cost(for: sample)
                }
                let completeAgentTokens = values.allSatisfy { $0.totalTokens != nil }
                let completeAgentCosts = agentCosts.allSatisfy { $0 != nil }
                return TelemetryAgentAggregate(
                    nodeID: nodeID,
                    agentName: agentNames[nodeID],
                    adapter: values.first?.adapter ?? "unknown",
                    model: values.compactMap { $0.model }.first,
                    totalTokens: completeAgentTokens ? values.compactMap { $0.totalTokens }.reduce(0, +) : nil,
                    estimatedCost: completeAgentCosts ? agentCosts.compactMap { $0 }.reduce(0, +) : nil,
                    currency: values.first?.currency ?? budget?.currency ?? "USD",
                    source: aggregateSource(values),
                    activeSeconds: values.reduce(0) { $0 + $1.durationSeconds },
                    sampleCount: values.count,
                    unavailableSamples: values.filter { $0.source == .unavailable }.count)
            }
            .sorted { ($0.estimatedCost ?? -1) > ($1.estimatedCost ?? -1) }

        return TelemetrySnapshot(
            workspaceID: workspaceID,
            generatedAt: now,
            windowStart: windowStart,
            totalTokens: completeTokens ? knownTokens : nil,
            knownTokens: knownTokens,
            totalCost: totalCost,
            currency: budget?.currency ?? samples.first?.currency ?? "USD",
            source: source,
            burnPerMinute: totalCost.flatMap { elapsed > 0 ? $0 / (elapsed / 60) : nil },
            activeSeconds: activeSeconds,
            sampleCount: samples.count,
            unavailableSamples: samples.filter { $0.source == .unavailable }.count,
            agents: byAgent,
            budget: budget,
            budgetPercent: budgetPercent,
            alerts: alerts)
    }

    private func append(_ line: Line) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let existing = lines[line.id] {
            // Retries do not duplicate telemetry. A conflicting ID is ignored as
            // well: IDs are the idempotency boundary and never overwrite history.
            return existing == line ? false : false
        }
        let data = try ColmeiaJSON.encoder().encode(line)
        var framed = data
        framed.append(0x0A)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        handle.write(framed)
        try handle.close()
        lines[line.id] = line
        return true
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        for raw in data.split(separator: 0x0A) {
            guard let line = try? ColmeiaJSON.decoder().decode(Line.self, from: Data(raw)) else { continue }
            lines[line.id] = line
        }
    }

    private func aggregateSource(_ samples: [UsageSample]) -> TelemetrySource {
        guard !samples.isEmpty else { return .unavailable }
        if samples.contains(where: { $0.source == .unavailable }) { return .unavailable }
        if samples.contains(where: { $0.source == .estimated }) { return .estimated }
        if samples.contains(where: { $0.source == .derived }) { return .derived }
        return .exact
    }
}
