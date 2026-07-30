import SwiftUI
import ColmeiaKit

/// Fila global de aprovações (§18.4): ordenada por idade, respondível sem focar o terminal.
struct ApprovalsPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Fila de Aprovações")
                    .font(.title3.bold())
                Spacer()
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            if store.pendingApprovals.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 30))
                        .foregroundStyle(.green)
                    Text("Nenhuma aprovação pendente")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.pendingApprovals, id: \.id) { approval in
                            ApprovalRow(approval: approval) {
                                dismiss()
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fila de aprovações, \(store.pendingApprovals.count) pendentes")
    }
}

private struct ApprovalRow: View {
    let approval: Approval
    let onNavigate: () -> Void

    @EnvironmentObject private var store: AppStore
    @State private var resolvendo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
                Text(approval.nodeNome)
                    .font(.headline)
                Spacer()
                Text(idade)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    store.focus(sessionID: approval.sessionID)
                    onNavigate()
                } label: {
                    Label("Ir para o nó", systemImage: "arrow.right.circle")
                        .font(.caption)
                }
                .accessibilityHint("Fecha a fila e foca o terminal que pediu esta aprovação")
            }

            Text(approval.resumo)
                .font(.system(size: 12))
                .textSelection(.enabled)

            HStack(spacing: 8) {
                if let opcoes = approval.opcoes, !opcoes.isEmpty {
                    ForEach(Array(opcoes.enumerated()), id: \.offset) { index, opcao in
                        Button(opcao) {
                            resolver(.aprovar, opcaoIndex: index)
                        }
                        .disabled(resolvendo)
                    }
                } else {
                    Button("Aprovar") { resolver(.aprovar, opcaoIndex: nil) }
                        .disabled(resolvendo)
                }
                Button("Negar", role: .destructive) { resolver(.negar, opcaoIndex: nil) }
                    .disabled(resolvendo)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aprovação pendente de \(approval.nodeNome), \(approval.resumo), \(idade)")
    }

    private var idade: String {
        let s = Int(Date().timeIntervalSince(approval.criadaEm))
        if s < 60 { return "há \(s)s" }
        if s < 3600 { return "há \(s / 60)min" }
        return "há \(s / 3600)h"
    }

    private func resolver(_ decisao: ApprovalDecisao, opcaoIndex: Int?) {
        resolvendo = true
        Task {
            await store.resolve(approval: approval, decisao: decisao, opcaoIndex: opcaoIndex)
            resolvendo = false
        }
    }
}
