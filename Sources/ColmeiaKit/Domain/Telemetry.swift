import Foundation

/// Proveniência de uma amostra. `exact` nunca pode ser obtido por regex no
/// terminal; `unavailable` é diferente de zero e precisa permanecer visível.
public enum TelemetrySource: String, Codable, CaseIterable, Sendable {
    case exact
    case derived
    case estimated
    case unavailable
}

public struct UsageSample: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var workspaceID: ULID
    public var sessionID: ULID
    public var nodeID: ULID
    public var adapter: String
    public var provider: String?
    public var model: String?
    public var inputTokens: Int64?
    public var outputTokens: Int64?
    public var cacheReadTokens: Int64?
    public var cacheWriteTokens: Int64?
    public var totalTokens: Int64?
    public var currency: String
    public var estimatedCost: Double?
    public var source: TelemetrySource
    public var startedAt: Date
    public var endedAt: Date?
    public var recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, adapter, provider, model, currency, source
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case totalTokens = "total_tokens"
        case estimatedCost = "estimated_cost"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case recordedAt = "recorded_at"
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
        case nodeID = "node_id"
    }

    public init(
        id: ULID = .generate(),
        workspaceID: ULID,
        sessionID: ULID,
        nodeID: ULID,
        adapter: String,
        provider: String? = nil,
        model: String? = nil,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        cacheReadTokens: Int64? = nil,
        cacheWriteTokens: Int64? = nil,
        totalTokens: Int64? = nil,
        currency: String = "USD",
        estimatedCost: Double? = nil,
        source: TelemetrySource,
        startedAt: Date,
        endedAt: Date? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.nodeID = nodeID
        self.adapter = adapter
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens ?? Self.sumTokens(
            inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens)
        self.currency = currency
        self.estimatedCost = estimatedCost
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recordedAt = recordedAt
    }

    public var durationSeconds: Double {
        max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
    }

    public var hasCompleteTokenCount: Bool {
        inputTokens != nil && outputTokens != nil
            && cacheReadTokens != nil && cacheWriteTokens != nil
    }

    private static func sumTokens(_ values: Int64?...) -> Int64? {
        guard values.contains(where: { $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }
}

public struct TelemetryAgentAggregate: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID { nodeID }
    public var nodeID: ULID
    public var agentName: String?
    public var adapter: String
    public var model: String?
    public var totalTokens: Int64?
    public var estimatedCost: Double?
    public var currency: String
    public var source: TelemetrySource
    public var activeSeconds: Double
    public var sampleCount: Int
    public var unavailableSamples: Int

    enum CodingKeys: String, CodingKey {
        case adapter, model, currency, source
        case nodeID = "node_id"
        case agentName = "agent_name"
        case totalTokens = "total_tokens"
        case estimatedCost = "estimated_cost"
        case activeSeconds = "active_seconds"
        case sampleCount = "sample_count"
        case unavailableSamples = "unavailable_samples"
    }

    public init(
        nodeID: ULID, agentName: String? = nil, adapter: String, model: String? = nil,
        totalTokens: Int64? = nil, estimatedCost: Double? = nil, currency: String = "USD",
        source: TelemetrySource, activeSeconds: Double, sampleCount: Int,
        unavailableSamples: Int
    ) {
        self.nodeID = nodeID
        self.agentName = agentName
        self.adapter = adapter
        self.model = model
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
        self.currency = currency
        self.source = source
        self.activeSeconds = activeSeconds
        self.sampleCount = sampleCount
        self.unavailableSamples = unavailableSamples
    }
}

public struct TelemetryBudget: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var limit: Double?
    public var currency: String
    public var warningThresholds: [Double]
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case limit, currency
        case workspaceID = "workspace_id"
        case warningThresholds = "warning_thresholds"
        case updatedAt = "updated_at"
    }

    public init(
        workspaceID: ULID,
        limit: Double? = nil,
        currency: String = "USD",
        warningThresholds: [Double] = [0.5, 0.8, 1.0],
        updatedAt: Date = Date()
    ) {
        self.workspaceID = workspaceID
        self.limit = limit
        self.currency = currency
        self.warningThresholds = warningThresholds
            .filter { $0 > 0 && $0 <= 1 }
            .sorted()
        self.updatedAt = updatedAt
    }
}

public struct TelemetrySnapshot: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var generatedAt: Date
    public var windowStart: Date?
    public var totalTokens: Int64?
    public var knownTokens: Int64
    public var totalCost: Double?
    public var currency: String
    public var source: TelemetrySource
    public var burnPerMinute: Double?
    public var activeSeconds: Double
    public var sampleCount: Int
    public var unavailableSamples: Int
    public var agents: [TelemetryAgentAggregate]
    public var budget: TelemetryBudget?
    public var budgetPercent: Double?
    public var alerts: [String]

    enum CodingKeys: String, CodingKey {
        case currency, source, agents, budget, alerts
        case workspaceID = "workspace_id"
        case generatedAt = "generated_at"
        case windowStart = "window_start"
        case totalTokens = "total_tokens"
        case knownTokens = "known_tokens"
        case totalCost = "total_cost"
        case burnPerMinute = "burn_per_minute"
        case activeSeconds = "active_seconds"
        case sampleCount = "sample_count"
        case unavailableSamples = "unavailable_samples"
        case budgetPercent = "budget_percent"
    }

    public init(
        workspaceID: ULID, generatedAt: Date, windowStart: Date? = nil,
        totalTokens: Int64? = nil, knownTokens: Int64 = 0, totalCost: Double? = nil,
        currency: String = "USD", source: TelemetrySource = .unavailable,
        burnPerMinute: Double? = nil, activeSeconds: Double = 0, sampleCount: Int = 0,
        unavailableSamples: Int = 0, agents: [TelemetryAgentAggregate] = [],
        budget: TelemetryBudget? = nil, budgetPercent: Double? = nil,
        alerts: [String] = []
    ) {
        self.workspaceID = workspaceID
        self.generatedAt = generatedAt
        self.windowStart = windowStart
        self.totalTokens = totalTokens
        self.knownTokens = knownTokens
        self.totalCost = totalCost
        self.currency = currency
        self.source = source
        self.burnPerMinute = burnPerMinute
        self.activeSeconds = activeSeconds
        self.sampleCount = sampleCount
        self.unavailableSamples = unavailableSamples
        self.agents = agents
        self.budget = budget
        self.budgetPercent = budgetPercent
        self.alerts = alerts
    }
}

public struct TelemetryPrice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: String
    public var model: String
    public var currency: String
    public var inputPerMillion: Double
    public var outputPerMillion: Double
    public var cacheReadPerMillion: Double
    public var cacheWritePerMillion: Double
    public var effectiveFrom: Date

    enum CodingKeys: String, CodingKey {
        case id, provider, model, currency
        case inputPerMillion = "input_per_million"
        case outputPerMillion = "output_per_million"
        case cacheReadPerMillion = "cache_read_per_million"
        case cacheWritePerMillion = "cache_write_per_million"
        case effectiveFrom = "effective_from"
    }

    public init(
        id: String, provider: String, model: String, currency: String = "USD",
        inputPerMillion: Double, outputPerMillion: Double,
        cacheReadPerMillion: Double = 0, cacheWritePerMillion: Double = 0,
        effectiveFrom: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.currency = currency
        self.inputPerMillion = max(0, inputPerMillion)
        self.outputPerMillion = max(0, outputPerMillion)
        self.cacheReadPerMillion = max(0, cacheReadPerMillion)
        self.cacheWritePerMillion = max(0, cacheWritePerMillion)
        self.effectiveFrom = effectiveFrom
    }

    public func cost(for sample: UsageSample) -> Double? {
        guard sample.hasCompleteTokenCount else { return nil }
        let input = Double(sample.inputTokens ?? 0) * inputPerMillion / 1_000_000
        let output = Double(sample.outputTokens ?? 0) * outputPerMillion / 1_000_000
        let read = Double(sample.cacheReadTokens ?? 0) * cacheReadPerMillion / 1_000_000
        let write = Double(sample.cacheWriteTokens ?? 0) * cacheWritePerMillion / 1_000_000
        return input + output + read + write
    }
}

public struct TelemetryPricingTable: Codable, Equatable, Sendable {
    public var version: String
    public var prices: [TelemetryPrice]

    public init(version: String = "local-empty-v1", prices: [TelemetryPrice] = []) {
        self.version = version
        self.prices = prices
    }

    public func price(provider: String?, model: String?) -> TelemetryPrice? {
        guard let provider, let model else { return nil }
        return prices
            .filter { $0.provider == provider && $0.model == model }
            .sorted { $0.effectiveFrom > $1.effectiveFrom }
            .first
    }
}

public enum FileActivityAction: String, Codable, CaseIterable, Sendable {
    case read, search, create, modify, delete, test, reference
}

public struct FileActivityEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var workspaceID: ULID
    public var sessionID: ULID?
    public var nodeID: ULID
    public var relativePath: String
    public var action: FileActivityAction
    public var tool: String?
    public var source: TelemetrySource
    public var startedAt: Date
    public var endedAt: Date?
    public var success: Bool?
    public var metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, tool, action, source, success, metadata
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
        case nodeID = "node_id"
        case relativePath = "relative_path"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    public init(
        id: ULID = .generate(), workspaceID: ULID, sessionID: ULID? = nil,
        nodeID: ULID, relativePath: String, action: FileActivityAction,
        tool: String? = nil, source: TelemetrySource, startedAt: Date,
        endedAt: Date? = nil, success: Bool? = nil, metadata: [String: String] = [:]
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.nodeID = nodeID
        self.relativePath = relativePath
        self.action = action
        self.tool = tool
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.success = success
        self.metadata = metadata
    }
}

public enum ConnectionActivityKind: String, Codable, CaseIterable, Sendable {
    case message, delegation, contextTransfer = "context_transfer"
    case delivery, approval, error
}

public struct ConnectionActivityEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var workspaceID: ULID
    public var connectionID: ULID
    public var fromNodeID: ULID
    public var toNodeID: ULID
    public var activity: ConnectionActivityKind
    public var volume: Int
    public var status: String
    public var startedAt: Date
    public var completedAt: Date?
    public var correlationID: ULID?

    enum CodingKeys: String, CodingKey {
        case id, activity, volume, status
        case workspaceID = "workspace_id"
        case connectionID = "connection_id"
        case fromNodeID = "from_node_id"
        case toNodeID = "to_node_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case correlationID = "correlation_id"
    }

    public init(
        id: ULID = .generate(), workspaceID: ULID, connectionID: ULID,
        fromNodeID: ULID, toNodeID: ULID, activity: ConnectionActivityKind,
        volume: Int = 1, status: String = "completed", startedAt: Date,
        completedAt: Date? = nil, correlationID: ULID? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.connectionID = connectionID
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.activity = activity
        self.volume = max(0, volume)
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.correlationID = correlationID
    }
}

public enum PortalActivityAction: String, Codable, CaseIterable, Sendable {
    case navigate, click, fill, key, eval, shot, snapshot
}

public struct PortalActivityEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var workspaceID: ULID
    public var nodeID: ULID
    public var sessionID: ULID?
    public var action: PortalActivityAction
    public var url: String?
    public var selector: String?
    public var coordinates: [Double]?
    public var status: String
    public var durationMs: Int?
    public var screenshotReference: String?
    public var recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, action, url, selector, coordinates, status
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case sessionID = "session_id"
        case durationMs = "duration_ms"
        case screenshotReference = "screenshot_reference"
        case recordedAt = "recorded_at"
    }

    public init(
        id: ULID = .generate(), workspaceID: ULID, nodeID: ULID,
        sessionID: ULID? = nil, action: PortalActivityAction, url: String? = nil,
        selector: String? = nil, coordinates: [Double]? = nil,
        status: String = "completed", durationMs: Int? = nil,
        screenshotReference: String? = nil, recordedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.sessionID = sessionID
        self.action = action
        self.url = url
        self.selector = selector
        self.coordinates = coordinates
        self.status = status
        self.durationMs = durationMs
        self.screenshotReference = screenshotReference
        self.recordedAt = recordedAt
    }
}

public struct TelemetrySnapshotParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var windowStart: Date?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case windowStart = "window_start"
    }

    public init(workspaceID: ULID, windowStart: Date? = nil) {
        self.workspaceID = workspaceID
        self.windowStart = windowStart
    }
}

public struct TelemetryQueryParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID?
    public var sessionID: ULID?
    public var from: Date?
    public var until: Date?
    public var limit: Int

    enum CodingKeys: String, CodingKey {
        case from, until, limit
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case sessionID = "session_id"
    }

    public init(
        workspaceID: ULID, nodeID: ULID? = nil, sessionID: ULID? = nil,
        from: Date? = nil, until: Date? = nil, limit: Int = 500
    ) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.sessionID = sessionID
        self.from = from
        self.until = until
        self.limit = min(10_000, max(1, limit))
    }
}

public struct TelemetryQueryResult: Codable, Equatable, Sendable {
    public var samples: [UsageSample]

    public init(samples: [UsageSample]) { self.samples = samples }
}

public struct FileActivityQueryResult: Codable, Equatable, Sendable {
    public var events: [FileActivityEvent]

    public init(events: [FileActivityEvent]) { self.events = events }
}

/// Entrada explícita para hooks de ferramentas. O Engine só aceita paths
/// relativos ao workspace; texto incidental do terminal nunca passa por aqui.
public struct FileActivityRecordParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var sessionID: ULID?
    public var nodeID: ULID
    public var relativePath: String
    public var action: FileActivityAction
    public var tool: String?
    public var source: TelemetrySource
    public var startedAt: Date?
    public var endedAt: Date?
    public var success: Bool?
    public var metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case action, tool, source, success, metadata
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
        case nodeID = "node_id"
        case relativePath = "relative_path"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    public init(
        workspaceID: ULID, sessionID: ULID? = nil, nodeID: ULID,
        relativePath: String, action: FileActivityAction, tool: String? = nil,
        source: TelemetrySource = .exact, startedAt: Date? = nil,
        endedAt: Date? = nil, success: Bool? = nil,
        metadata: [String: String] = [:]
    ) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.nodeID = nodeID
        self.relativePath = relativePath
        self.action = action
        self.tool = tool
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.success = success
        self.metadata = metadata
    }
}

public struct FileActivityRecordResult: Codable, Equatable, Sendable {
    public var event: FileActivityEvent

    public init(event: FileActivityEvent) { self.event = event }
}

public struct FileActivityScanParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID
    public var sessionID: ULID?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case sessionID = "session_id"
    }

    public init(workspaceID: ULID, nodeID: ULID, sessionID: ULID? = nil) {
        self.workspaceID = workspaceID; self.nodeID = nodeID; self.sessionID = sessionID
    }
}

public struct FileActivityScanResult: Codable, Equatable, Sendable {
    public var events: [FileActivityEvent]
    public init(events: [FileActivityEvent]) { self.events = events }
}

public struct PortalActivityQueryResult: Codable, Equatable, Sendable {
    public var events: [PortalActivityEvent]

    public init(events: [PortalActivityEvent]) { self.events = events }
}

public struct TelemetryBudgetResult: Codable, Equatable, Sendable {
    public var budget: TelemetryBudget

    public init(budget: TelemetryBudget) { self.budget = budget }
}

public struct TelemetryBudgetUpdateParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var limit: Double?
    public var currency: String
    public var warningThresholds: [Double]

    enum CodingKeys: String, CodingKey {
        case limit, currency
        case workspaceID = "workspace_id"
        case warningThresholds = "warning_thresholds"
    }

    public init(
        workspaceID: ULID, limit: Double?, currency: String = "USD",
        warningThresholds: [Double] = [0.5, 0.8, 1.0]
    ) {
        self.workspaceID = workspaceID
        self.limit = limit
        self.currency = currency
        self.warningThresholds = warningThresholds
    }
}

public struct TelemetryPricingResult: Codable, Equatable, Sendable {
    public var table: TelemetryPricingTable

    public init(table: TelemetryPricingTable) { self.table = table }
}
