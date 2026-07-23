import SwiftUI
import ColmeiaKit

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var connection: EngineConnection

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if store.workspace != nil {
                VStack(spacing: 0) {
                    FloorBar()
                    CanvasView()
                }
                DrawingToolbar()
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else {
                emptyState
            }
            overlayIndicators
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $store.showNewTerminal) {
            NewTerminalSheet()
        }
        .sheet(isPresented: $store.showApprovals) {
            ApprovalsPanel()
        }
        .sheet(isPresented: $store.showRoutines) {
            RoutinesPanel()
        }
        .sheet(item: $store.replaySession) { session in
            ReplayPanel(session: session, connection: connection)
        }
        .sheet(isPresented: Binding(
            get: { store.textoPendentePonto != nil },
            set: { if !$0 { store.textoPendentePonto = nil } }
        )) {
            if let ponto = store.textoPendentePonto {
                TextoSoltoSheet(ponto: ponto)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "hexagon")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Nenhum workspace aberto")
                .font(.title3)
            if connection.isConnected {
                WorkspaceSelectorMenu()
            } else {
                Text("aguardando o engine…")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var overlayIndicators: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if case .reconectando(let tentativa) = connection.status {
                Label("reconectando (\(tentativa))", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
            }
            if let erro = store.lastError {
                HStack(spacing: 6) {
                    Text(erro)
                        .font(.caption)
                        .lineLimit(2)
                    Button {
                        store.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 420)
            }
        }
        .padding(12)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            WorkspaceSelectorMenu()
        }
        ToolbarItemGroup {
            Button {
                store.showNewTerminal = true
            } label: {
                Label("Novo Terminal", systemImage: "terminal")
            }
            .disabled(store.workspace == nil)

            Button {
                store.addNota()
            } label: {
                Label("Nova Nota", systemImage: "note.text.badge.plus")
            }
            .disabled(store.workspace == nil)

            approvalsButton
        }
    }

    /// Badge global DEVE ficar sempre visível quando > 0 (§18.4).
    private var approvalsButton: some View {
        Button {
            store.showApprovals.toggle()
        } label: {
            Label("Aprovações", systemImage: "checkmark.shield")
                .overlay(alignment: .topTrailing) {
                    let count = store.pendingApprovals.count
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .offset(x: 10, y: -8)
                    }
                }
        }
    }
}
