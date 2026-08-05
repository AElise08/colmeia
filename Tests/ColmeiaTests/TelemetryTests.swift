import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

private func telemetryTempFile() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("colm-telemetry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("telemetry.jsonl")
}

@Suite("Telemetria do control plane")
struct TelemetryTests {
    @Test func jsonlEIdempotenteMesmoComRetry() throws {
        let file = try telemetryTempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let workspace = ULID.generate()
        let session = ULID.generate()
        let node = ULID.generate()
        let sample = UsageSample(
            workspaceID: workspace, sessionID: session, nodeID: node,
            adapter: "codex", provider: "openai", model: "gpt-test",
            inputTokens: 10, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0,
            source: .exact, startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 70),
            recordedAt: Date(timeIntervalSince1970: 70))
        let store = try TelemetryStore(fileURL: file)

        #expect(try store.append(sample))
        #expect(!(try store.append(sample)))
        #expect(store.usage(workspaceID: workspace).count == 1)

        let restored = try TelemetryStore(fileURL: file)
        #expect(restored.usage(workspaceID: workspace) == [sample])
    }

    @Test func custoDerivadoNaoConfundeTokensIndisponiveisComZero() throws {
        let file = try telemetryTempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let workspace = ULID.generate()
        let node = ULID.generate()
        let now = Date(timeIntervalSince1970: 100)
        let exact = UsageSample(
            workspaceID: workspace, sessionID: ULID.generate(), nodeID: node,
            adapter: "codex", provider: "openai", model: "gpt-test",
            inputTokens: 1_000, outputTokens: 500, cacheReadTokens: 0, cacheWriteTokens: 0,
            source: .exact, startedAt: now, endedAt: now.addingTimeInterval(60), recordedAt: now)
        let unavailable = UsageSample(
            workspaceID: workspace, sessionID: ULID.generate(), nodeID: node,
            adapter: "claude-code", provider: "anthropic", model: nil,
            source: .unavailable, startedAt: now, endedAt: now.addingTimeInterval(30), recordedAt: now)
        let store = try TelemetryStore(fileURL: file)
        _ = try store.append(exact)
        _ = try store.append(unavailable)

        let pricing = TelemetryPricingTable(
            version: "fixture-v1",
            prices: [TelemetryPrice(
                id: "gpt-test-v1", provider: "openai", model: "gpt-test",
                inputPerMillion: 1, outputPerMillion: 2)])
        let snapshot = store.snapshot(
            workspaceID: workspace, pricing: pricing,
            agentNames: [node: "builder"], now: now.addingTimeInterval(120))

        #expect(snapshot.knownTokens == 1_500)
        #expect(snapshot.totalTokens == nil)
        #expect(snapshot.totalCost == nil)
        #expect(snapshot.source == .unavailable)
        #expect(snapshot.unavailableSamples == 1)
        #expect(snapshot.agents.first?.agentName == "builder")
        #expect(snapshot.agents.first?.totalTokens == nil)
    }

    @Test func tabelaVersionadaCalculaBurnEAlertaDeOrcamento() throws {
        let file = try telemetryTempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let workspace = ULID.generate()
        let sample = UsageSample(
            workspaceID: workspace, sessionID: ULID.generate(), nodeID: ULID.generate(),
            adapter: "codex", provider: "openai", model: "gpt-test",
            inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
            source: .exact, startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 60),
            recordedAt: Date(timeIntervalSince1970: 60))
        let store = try TelemetryStore(fileURL: file)
        _ = try store.append(sample)
        let table = TelemetryPricingTable(
            version: "fixture-v2",
            prices: [TelemetryPrice(
                id: "gpt-test-v2", provider: "openai", model: "gpt-test",
                inputPerMillion: 2, outputPerMillion: 4)])
        let budget = TelemetryBudget(
            workspaceID: workspace, limit: 1, warningThresholds: [0.5, 0.8, 1.0])
        let snapshot = store.snapshot(
            workspaceID: workspace, pricing: table, budget: budget,
            now: Date(timeIntervalSince1970: 60))

        #expect(snapshot.totalCost == 2)
        #expect(snapshot.budgetPercent == 2)
        #expect(snapshot.burnPerMinute == 2)
        #expect(snapshot.alerts == ["budget_50", "budget_80", "budget_100"])
    }
}

