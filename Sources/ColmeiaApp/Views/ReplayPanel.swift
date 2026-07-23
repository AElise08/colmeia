import SwiftUI
import AppKit
import SwiftTerm
import ColmeiaKit

/// Modo replay (§18.6): read-only, painel separado do vivo, scrubber temporal,
/// velocidades 1×/4×/16×, marcadores nos eventos não-output.
@MainActor
final class ReplayController: ObservableObject {
    let session: Session
    private unowned let connection: EngineConnection

    @Published private(set) var events: [Event] = []
    @Published private(set) var index = 0
    @Published var playing = false {
        didSet { if playing { startPlayback() } else { playbackTask?.cancel() } }
    }
    @Published var speed = 1.0
    /// Trocada a cada seek para trás: reconstruir = view nova alimentada do zero.
    @Published private(set) var terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    @Published private(set) var carregando = true

    private var playbackTask: Task<Void, Never>?

    init(session: Session, connection: EngineConnection) {
        self.session = session
        self.connection = connection
    }

    func load() async {
        carregando = true
        events = (try? await connection.call(
            .sessionReplay,
            params: SessionReplayParams(sessionID: session.id),
            expecting: SessionReplayResult.self
        ))?.events ?? []
        carregando = false
        seek(to: events.count)
    }

    var marcadores: [(fracao: Double, tipo: EventTipo)] {
        guard events.count > 1 else { return [] }
        return events.enumerated().compactMap { i, event in
            event.tipo == .output ? nil : (Double(i) / Double(events.count), event.tipo)
        }
    }

    func seek(to novo: Int) {
        let alvo = max(0, min(novo, events.count))
        if alvo < index {
            terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
            index = 0
        }
        feed(ate: alvo)
    }

    private func feed(ate alvo: Int) {
        while index < alvo {
            let event = events[index]
            switch event.payload {
            case .output(let payload):
                if let data = Data(base64Encoded: payload.dataB64) {
                    terminalView.feed(byteArray: [UInt8](data)[...])
                }
            case .resize(let payload):
                terminalView.resize(cols: payload.cols, rows: payload.rows)
            default:
                break
            }
            index += 1
        }
    }

    private func startPlayback() {
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            while let self, self.playing, self.index < self.events.count {
                let atual = self.index
                self.feed(ate: atual + 1)
                if self.index < self.events.count {
                    let delta = self.events[self.index].ts.timeIntervalSince(self.events[atual].ts)
                    let espera = min(max(delta, 0.01), 2.0) / self.speed
                    try? await Task.sleep(nanoseconds: UInt64(espera * 1_000_000_000))
                } else {
                    self.playing = false
                }
                if Task.isCancelled { return }
            }
            self?.playing = false
        }
    }

    func stop() {
        playing = false
        playbackTask?.cancel()
    }
}

extension Session: Identifiable {}

private struct ReplayTerminalHost: NSViewRepresentable {
    let terminalView: TerminalView

    func makeNSView(context: Context) -> TerminalView { terminalView }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

struct ReplayPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: ReplayController

    init(session: Session, connection: EngineConnection) {
        _controller = StateObject(wrappedValue: ReplayController(session: session, connection: connection))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Replay — \(store.nodeName(controller.session.nodeID))", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Text(controller.session.iniciadaEm.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fechar") {
                    controller.stop()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            if controller.carregando {
                ProgressView("carregando journal…")
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                ReplayTerminalHost(terminalView: controller.terminalView)
                    .id(ObjectIdentifier(controller.terminalView))
                    .frame(minWidth: 640, minHeight: 360)
                    .allowsHitTesting(false)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    controller.playing.toggle()
                } label: {
                    Image(systemName: controller.playing ? "pause.fill" : "play.fill")
                }
                .disabled(controller.carregando || controller.events.isEmpty)

                Picker("", selection: $controller.speed) {
                    Text("1×").tag(1.0)
                    Text("4×").tag(4.0)
                    Text("16×").tag(16.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .labelsHidden()

                scrubber

                Text("\(controller.index)/\(controller.events.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(width: 720)
        .task { await controller.load() }
    }

    private var scrubber: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Slider(
                    value: Binding(
                        get: { Double(controller.index) },
                        set: { controller.seek(to: Int($0.rounded())) }
                    ),
                    in: 0...Double(max(1, controller.events.count))
                )
                ForEach(Array(controller.marcadores.enumerated()), id: \.offset) { _, marcador in
                    Rectangle()
                        .fill(corMarcador(marcador.tipo))
                        .frame(width: 2, height: 6)
                        .offset(x: marcador.fracao * geo.size.width, y: 12)
                }
            }
        }
        .frame(height: 28)
    }

    private func corMarcador(_ tipo: EventTipo) -> SwiftUI.Color {
        switch tipo {
        case .approval: return .red
        case .message: return .blue
        case .state: return .orange
        case .input: return .green
        default: return .gray
        }
    }
}
