import Foundation
import SwiftUI
import ColmeiaKit

/// HUD compacto da Visão Execução. Números ausentes são mostrados como
/// “indisponível”; a interface não converte falta de telemetria em zero.
struct ExecutionTelemetryHUD: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        CanvasSurface(padding: 12, radius: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(ColmeiaCanvasTheme.amber.opacity(0.15))
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ColmeiaCanvasTheme.amber)
                    }
                    .frame(width: 25, height: 25)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("LIVE TELEMETRY")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(1.0)
                            .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
                        Text("Execução")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(ColmeiaCanvasTheme.ink)
                    }
                    Spacer()
                    Button {
                        Task { await store.refreshTelemetry() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
                            .padding(5)
                            .background(ColmeiaCanvasTheme.surfaceRaised, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Atualizar telemetria")
                }

                if let snapshot = store.telemetrySnapshot {
                    summary(snapshot)
                    if snapshot.agents.isEmpty {
                        Text("Nenhuma amostra de uso foi reportada ainda.")
                            .font(.caption2)
                            .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
                    } else {
                        Divider().overlay(ColmeiaCanvasTheme.line)
                        ForEach(snapshot.agents.prefix(5)) { agent in
                            agentRow(agent)
                        }
                    }
                } else {
                    Text("Telemetria aguardando dados do Engine.")
                        .font(.caption)
                        .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
                    Text("Tokens e custo aparecem quando o provider fornece um hook oficial.")
                        .font(.caption2)
                        .foregroundStyle(ColmeiaCanvasTheme.mutedInk.opacity(0.72))
                }
            }
        }
        .frame(width: 300, alignment: .leading)
        .padding(16)
    }

    private func summary(_ snapshot: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                metric("Tokens", value: snapshot.totalTokens.map(formatTokens) ?? "indisponível")
                Spacer()
                metric("Custo", value: cost(snapshot.totalCost, currency: snapshot.currency))
            }
            HStack {
                metric("Burn/min", value: cost(snapshot.burnPerMinute, currency: snapshot.currency))
                Spacer()
                if let percent = snapshot.budgetPercent {
                    metric("Orçamento", value: "\(Int(percent * 100))%")
                        .foregroundStyle(budgetColor(percent, budget: snapshot.budget))
                } else {
                    metric("Amostras", value: "\(snapshot.sampleCount)")
                }
            }
            if snapshot.source == .unavailable || snapshot.unavailableSamples > 0 {
                Label("Parte do uso está indisponível", systemImage: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
            }
            if !snapshot.alerts.isEmpty {
                Label("Limite de custo atingido", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
    }

    private func agentRow(_ agent: TelemetryAgentAggregate) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(agent.source == .unavailable ? ColmeiaCanvasTheme.mutedInk : ColmeiaCanvasTheme.cyan)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.agentName ?? String(agent.nodeID.string.prefix(8)))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(agent.adapter) · \(sourceLabel(agent.source))")
                    .font(.caption2)
                    .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(cost(agent.estimatedCost, currency: agent.currency))
                    .font(.caption.monospacedDigit())
                Text(agent.totalTokens.map(formatTokens) ?? "tokens indisponíveis")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(ColmeiaCanvasTheme.mutedInk)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(ColmeiaCanvasTheme.ink)
        }
    }

    private func cost(_ value: Double?, currency: String) -> String {
        guard let value else { return "indisponível" }
        return "\(currency) \(String(format: "%.4f", value))"
    }

    private func formatTokens(_ value: Int64) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func sourceLabel(_ source: TelemetrySource) -> String {
        switch source {
        case .exact: return "exato"
        case .derived: return "derivado"
        case .estimated: return "estimado"
        case .unavailable: return "indisponível"
        }
    }

    private func budgetColor(_ percent: Double, budget: TelemetryBudget?) -> Color {
        if percent >= 1 { return .red }
        if percent >= (budget?.warningThresholds.dropLast().last ?? 0.8) { return .orange }
        return .green
    }
}
