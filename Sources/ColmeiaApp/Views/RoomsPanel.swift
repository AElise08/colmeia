import SwiftUI
import ColmeiaKit

/// Painel de salas multiplayer. Lista salas, permite criar/entrar, ver membros e thread.
struct RoomsPanel: View {
    @EnvironmentObject private var connection: EngineConnection
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var presenceStore: CollaborationPresenceStore
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var hubConnection: HubConnection
    @State private var rooms: [Room] = []
    @State private var erro: String?
    @State private var carregando = false

    @State private var criando = false
    @State private var nomeNova = ""
    @State private var entrandoID = ""
    @State private var salaSelecionada: Room?

    @State private var mostrandoConfigHub = false
    @State private var hubURLInput = HubConnection.savedHubURL
    @State private var hubTokenInput = HubConnection.savedHubToken ?? ""
    @State private var hubAtivoURL = HubConnection.savedHubURL

    var body: some View {
        NavigationSplitView {
            List(selection: $salaSelecionada) {
                Section {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hubAtivoURL.contains("127.0.0.1") || hubAtivoURL.contains("localhost") ? "Hub Virtual Local" : "Hub Remoto (\(hubAtivoURL))")
                                .font(.caption.bold())
                            Text(statusText)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if hubConnection.pendingOutboxCount > 0 {
                            Label("\(hubConnection.pendingOutboxCount) pendente(s)", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("Alterações da Sala aguardando reconexão")
                        }
                        Spacer()
                        Button("Alterar") {
                            mostrandoConfigHub = true
                        }
                        .controlSize(.small)
                    }
                } header: {
                    Text("Conexão do Hub").font(.subheadline.weight(.medium))
                }

                Section {
                    ForEach(rooms) { room in
                        NavigationLink(value: room) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(room.name).font(.headline)
                                if room.workspaceID == store.workspace?.id {
                                    Text("Workspace aberto")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await deleteRoom(room) }
                            } label: {
                                Label("Apagar", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Salas").font(.subheadline.weight(.medium))
                        Spacer()
                        if carregando { ProgressView().controlSize(.small) }
                    }
                }
                Section {
                    HStack {
                        TextField("Entrar por ID…", text: $entrandoID)
                            .font(.caption.monospaced())
                        Button("Entrar") { Task { await joinByID() } }
                            .disabled(entrandoID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Entrar em sala existente").font(.subheadline.weight(.medium))
                }
            }
        } detail: {
            if let sala = salaSelecionada {
                RoomDetailView(room: sala, hubURL: hubAtivoURL, hubConnection: hubConnection)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.3.sequence.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Selecione uma sala ou crie uma nova")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Conectado ao Hub: \(hubAtivoURL)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Label("Fechar", systemImage: "xmark.circle.fill")
                }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Fechar painel e voltar ao Canvas (Esc)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    nomeNova = ""
                    criando = true
                } label: {
                    Label("Nova Sala", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refresh() } } label: {
                    Label("Atualizar", systemImage: "arrow.clockwise")
                }
            }
        }
        .alert("Nova Sala", isPresented: $criando) {
            TextField("Nome", text: $nomeNova)
            Button("Cancelar", role: .cancel) {}
            Button("Criar") { Task { await createRoom() } }
        }
        .sheet(isPresented: $mostrandoConfigHub) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Configurar Conexão do Hub")
                    .font(.title3.bold())
                Text("Informe a URL do Hub WSS (ex.: wss://hub.seudominio.com/ws ou ws://127.0.0.1:9620) para acessar salas multiplayer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("URL do Hub (ws:// ou wss://)", text: $hubURLInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                SecureField("Token do Hub", text: $hubTokenInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                HStack {
                    Button("Usar Hub Local") {
                        hubAtivoURL = "ws://127.0.0.1:9620"
                        hubURLInput = hubAtivoURL
                        hubTokenInput = ""
                        hubConnection.saveConfiguration(url: hubAtivoURL, token: "")
                        mostrandoConfigHub = false
                        Task { await refresh() }
                    }
                    Spacer()
                    Button("Cancelar") {
                        mostrandoConfigHub = false
                    }
                    Button("Conectar") {
                        let url = hubURLInput.trimmingCharacters(in: .whitespaces)
                        if !url.isEmpty {
                            hubAtivoURL = url
                            hubConnection.saveConfiguration(url: url, token: hubTokenInput)
                        }
                        mostrandoConfigHub = false
                        Task { await refresh() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 480)
        }
        .onAppear {
            hubConnection.start()
            Task { await refresh() }
        }
        .frame(minWidth: 680, idealWidth: 840, minHeight: 480)
    }

    private var statusColor: Color {
        switch hubConnection.status {
        case .conectado: return .green
        case .conectando: return .yellow
        case .reconectando: return .orange
        }
    }

    private var statusText: String {
        switch hubConnection.status {
        case .conectado: return hubAtivoURL
        case .conectando: return "Conectando a \(hubAtivoURL)..."
        case .reconectando: return "Reconectando ao Hub..."
        }
    }

    private func callRPC<R: Decodable>(_ method: ColmeiaMethod, params: some Encodable, expecting: R.Type) async throws -> R {
        guard hubConnection.isConnected else {
            throw ProtocolError(name: .internal_error, message: "Hub desconectado (\(hubAtivoURL)). Não há fallback silencioso para o engine local.")
        }
        return try await hubConnection.call(method, params: params, expecting: expecting)
    }

    private func callRPC<R: Decodable>(_ method: ColmeiaMethod, expecting: R.Type) async throws -> R {
        guard hubConnection.isConnected else {
            throw ProtocolError(name: .internal_error, message: "Hub desconectado (\(hubAtivoURL)). Não há fallback silencioso para o engine local.")
        }
        return try await hubConnection.call(method, expecting: expecting)
    }

    private func refresh() async {
        carregando = true
        erro = nil
        if hubConnection.hubURL != hubAtivoURL {
            hubConnection.connect(to: hubAtivoURL)
        }
        for _ in 0..<50 {
            if hubConnection.isConnected { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        do {
            let result: RoomListResult = try await callRPC(.roomList, expecting: RoomListResult.self)
            rooms = result
        } catch {
            erro = "Falha ao listar salas: \(error)"
        }
        carregando = false
    }

    private func createRoom() async {
        let nome = nomeNova.trimmingCharacters(in: .whitespaces)
        guard !nome.isEmpty else { return }
        do {
            guard let workspaceID = store.workspace?.id else {
                erro = "Abra um workspace antes de criar uma sala."
                return
            }
            _ = try await callRPC(
                .roomCreate,
                params: RoomCreateParams(name: nome, workspaceID: workspaceID),
                expecting: RoomResult.self
            )
            await refresh()
        } catch {
            erro = "Falha ao criar sala: \(error)"
        }
    }

    private func deleteRoom(_ room: Room) async {
        do {
            _ = try await callRPC(.roomDelete, params: RoomDeleteParams(roomID: room.id, confirmar: true), expecting: EmptyResult.self)
            if salaSelecionada == room { salaSelecionada = nil }
            await refresh()
        } catch {
            erro = "Falha ao apagar sala: \(error)"
        }
    }

    private func joinByID() async {
        let raw = entrandoID.trimmingCharacters(in: .whitespaces)
        guard let roomID = ULID(raw) else {
            erro = "ID inválido: \(raw)"
            return
        }
        do {
            let result: RoomJoinResult = try await callRPC(.roomJoin, params: RoomJoinParams(roomID: roomID), expecting: RoomJoinResult.self)
            presenceStore.activate(roomID: roomID, members: result.members, workspaceID: result.room.workspaceID)
            if let workspaceID = result.room.workspaceID, store.workspace?.id != workspaceID {
                await store.open(workspaceID: workspaceID)
            }
            entrandoID = ""
            await refresh()
            if let room = rooms.first(where: { $0.id == roomID }) ?? Optional(result.room) {
                salaSelecionada = room
            }
        } catch {
            erro = "Falha ao entrar na sala: \(error)"
        }
    }
}

extension Room: Identifiable, Hashable {
    public static func == (lhs: Room, rhs: Room) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct RoomDetailView: View {
    let room: Room
    var hubURL: String = "ws://127.0.0.1:9620"
    @ObservedObject var hubConnection: HubConnection
    @EnvironmentObject private var connection: EngineConnection
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var presenceStore: CollaborationPresenceStore
    @Environment(\.dismiss) private var dismiss

    @State private var joined = false
    @State private var members: [Member] = []
    @State private var sessions: [AgentSession] = []
    @State private var events: [CollaborativeSessionEvent] = []
    @State private var missions: [Mission] = []
    @State private var workstreams: [Workstream] = []
    @State private var roomSeq: UInt64 = 0
    @State private var erro: String?

    @State private var novaMensagem = ""
    @State private var enviando = false
    @State private var objectiveNova = ""
    @State private var showingNovaSession = false
    @State private var selectedSessionID: ULID?
    @State private var inviteAlertText: String?
    @State private var showingShareSheet = false
    @State private var invites: [InviteToken] = []
    @State private var showingNovaMissao = false
    @State private var missaoTitulo = ""
    private let eventTaskID = UUID()
    @State private var missaoDoD = ""
    @State private var missaoFrente = ""
    @State private var missaoFrenteObj = ""

    private func callRoomRPC<R: Decodable>(_ method: ColmeiaMethod, params: some Encodable, expecting: R.Type) async throws -> R {
        if hubConnection.isConnected {
            return try await hubConnection.call(method, params: params, expecting: expecting)
        }
        throw ProtocolError(name: .internal_error, message: "Hub desconectado (\(hubURL)). Não é possível executar operação de sala.")
    }

    private func callRoomRPC<R: Decodable>(_ method: ColmeiaMethod, expecting: R.Type) async throws -> R {
        if hubConnection.isConnected {
            return try await hubConnection.call(method, expecting: expecting)
        }
        throw ProtocolError(name: .internal_error, message: "Hub desconectado (\(hubURL)). Não é possível executar operação de sala.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    missionsSection
                    if !members.isEmpty { membersSection }
                    threadSection
                }
                .padding()
            }
            if joined {
                Divider()
                composerBar
            } else {
                joinBar
            }
        }
        .onAppear {
            let myID = eventTaskID
            hubConnection.onEvent = { [self] event in
                guard eventTaskID == myID else { return }
                Task { @MainActor in handleRoomEvent(event) }
            }
            Task { await entrar() }
        }
        .onDisappear {
            if hubConnection.onEvent != nil { hubConnection.onEvent = nil }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(room.name).font(.title2.bold())
                Text("seq \(roomSeq)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if joined {
                Button {
                    showingShareSheet = true
                } label: {
                    Label("Convidar / Sharing", systemImage: "square.and.arrow.up")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .help("Gera um link/token de convite para compartilhar esta sala")
                .sheet(isPresented: $showingShareSheet) {
                    ShareSheetView(room: room, hubURL: hubURL, hub: hubConnection)
                }

                Label(hubURL.contains("127.0.0.1") || hubURL.contains("localhost") ? "Hub virtual local" : "Hub Remoto", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button(role: .destructive) { Task { await removerSala() } } label: {
                    Label("Apagar sala", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Apagar esta sala")
            }
            if let erro {
                Text(erro).font(.caption).foregroundStyle(.red)
            }
            if let inviteAlertText {
                Text(inviteAlertText).font(.caption.bold()).foregroundStyle(.green)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func gerarConvite() async {
        showingShareSheet = true
    }

    /// §5.2 / Marco A — Missões da sala.
    private var visibleMissions: [Mission] { missions.filter { $0.state != .archived } }

    private var missionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Missões").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    missaoTitulo = ""
                    missaoDoD = "Resultado verificável entregue"
                    missaoFrente = "Pesquisa"
                    missaoFrenteObj = "Mapear contexto e critérios"
                    showingNovaMissao = true
                } label: {
                    Label("Nova Missão", systemImage: "flag.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            if visibleMissions.isEmpty {
                Text("Nenhuma missão. Crie uma para organizar frentes, decisões e entregas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleMissions, id: \.id) { mission in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(mission.title).font(.subheadline.bold())
                            Spacer()
                            Text(mission.state.rawValue)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(6)
                        }
                        Text(mission.definitionOfDone)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let frentes = workstreams.filter { $0.missionID == mission.id }
                        if !frentes.isEmpty {
                            Text("Frentes: " + frentes.map { "\($0.title) (\($0.state.rawValue))" }.joined(separator: " · "))
                                .font(.caption2)
                        }
                        HStack {
                            if mission.state == .draft {
                                Button("Ativar") {
                                    Task { await ativarMissao(mission) }
                                }
                                .controlSize(.small)
                            }
                            Spacer()
                            Button("Arquivar", role: .destructive) {
                                Task { await arquivarMissao(mission) }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(8)
                }
            }
        }
        .alert("Criar uma Missão", isPresented: $showingNovaMissao) {
            TextField("Resultado desejado", text: $missaoTitulo)
            TextField("Definição de pronto", text: $missaoDoD)
            TextField("Primeira frente", text: $missaoFrente)
            TextField("Objetivo da frente", text: $missaoFrenteObj)
            Button("Cancelar", role: .cancel) {}
            Button("Criar") { Task { await criarMissao() } }
        } message: {
            Text("Missão = resultado. A primeira frente habilita ativação.")
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Membros").font(.caption.bold()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(members) { m in
                    HStack(spacing: 4) {
                        Circle().fill(m.status == .active ? Color.green : Color.gray).frame(width: 6, height: 6)
                        Text(m.displayName).font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
                }
            }
        }
    }

    private var threadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Eventos & Chat").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(events) { ev in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        let authorName = members.first(where: { $0.id == ev.author.rawValue })?.displayName ?? ev.author.rawValue
                        Text("\(authorName) • \(ev.kind.rawValue)")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        if let texto = ev.payload.texto {
                            Text(texto).font(.body)
                        } else if let dir = ev.payload.direction {
                            Text("Direção: \(dir)").font(.body.italic())
                        }
                    }
                    Spacer()
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }
        }
    }

    private var joinBar: some View {
        HStack {
            Spacer()
            Button("Entrar na Sala") { Task { await entrar() } }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private var composerBar: some View {
        HStack {
            TextField("Digite uma mensagem...", text: $novaMensagem)
                .textFieldStyle(.roundedBorder)
            Button("Enviar") { Task { await postMensagem() } }
                .disabled(novaMensagem.trimmingCharacters(in: .whitespaces).isEmpty || enviando)
        }
        .padding()
    }

    @MainActor
    private func entrar() async {
        do {
            let result: RoomJoinResult = try await callRoomRPC(.roomJoin, params: RoomJoinParams(roomID: room.id), expecting: RoomJoinResult.self)
            members = result.members
            sessions = result.agentSessions
            joined = true
            presenceStore.activate(roomID: room.id, members: result.members, workspaceID: result.room.workspaceID)
            if let workspaceID = result.room.workspaceID, store.workspace?.id != workspaceID {
                await store.open(workspaceID: workspaceID)
            }
            await carregarEventos()
            await carregarMissoes()
        } catch {
            erro = "Erro ao entrar: \(error)"
            await carregarMissoes()
        }
    }

    @MainActor
    private func handleRoomEvent(_ event: EventMessage) {
        defer { presenceStore.updateMembers(members) }
        switch event.knownTopic {
        case .memberJoined:
            if let payload = try? event.decodeParams(MemberJoinedTopicPayload.self),
               payload.roomID == room.id,
               !members.contains(where: { $0.id == payload.member.id }) {
                members.append(payload.member)
                members.sort { $0.joinedAt < $1.joinedAt }
                if let seq = payload.roomSeq { roomSeq = seq }
            }
        case .memberLeft:
            if let payload = try? event.decodeParams(MemberLeftTopicPayload.self),
               payload.roomID == room.id {
                members.removeAll { $0.id == payload.memberID }
            }
        case .memberUpdated:
            if let payload = try? event.decodeParams(MemberUpdatedTopicPayload.self),
               let index = members.firstIndex(where: { $0.id == payload.member.id }) {
                members[index] = payload.member
            }
        case .roomUpdated:
            if let payload = try? event.decodeParams(RoomUpdatedTopicPayload.self),
               payload.room.id == room.id {
                // Atualiza metadata da sala se necessário
            }
        case .sessionEventAppended:
            if let payload = try? event.decodeParams(SessionEventAppendedTopicPayload.self),
               payload.event.roomID == room.id,
               !events.contains(where: { $0.id == payload.event.id }) {
                events.append(payload.event)
                events.sort { $0.logicalClock < $1.logicalClock }
                roomSeq = max(roomSeq, payload.event.logicalClock)
            }
        case .missionChanged:
            guard let payload = try? event.decodeParams(MissionChangedTopicPayload.self),
                  payload.roomID == room.id else { return }
            if let index = missions.firstIndex(where: { $0.id == payload.mission.id }) {
                missions[index] = payload.mission
            } else {
                missions.append(payload.mission)
            }
            store.applyRemoteMissionEvent(event)
        case .workstreamChanged:
            guard let payload = try? event.decodeParams(WorkstreamChangedTopicPayload.self),
                  payload.roomID == room.id else { return }
            if let index = workstreams.firstIndex(where: { $0.id == payload.workstream.id }) {
                workstreams[index] = payload.workstream
            } else {
                workstreams.append(payload.workstream)
            }
            store.applyRemoteMissionEvent(event)
        case .decisionChanged:
            guard let payload = try? event.decodeParams(DecisionChangedTopicPayload.self),
                  payload.roomID == room.id else { return }
            store.applyRemoteDecisionEvent(event)
        default:
            break
        }
    }

    @MainActor
    private func carregarMissoes() async {
        do {
            missions = try await callRoomRPC(
                .missionList,
                params: MissionListParams(roomID: room.id),
                expecting: MissionListResult.self
            )
            workstreams = try await callRoomRPC(
                .workstreamList,
                params: WorkstreamListParams(roomID: room.id),
                expecting: WorkstreamListResult.self
            )
            // Mantém a visão Missão do Canvas alinhada imediatamente após uma
            // criação/transição feita no painel multiplayer, inclusive quando
            // a Sala vive em um Hub remoto ao Engine local.
            store.updateMissionSnapshot(missions, workstreams: workstreams)
        } catch {
            erro = "Falha ao carregar missões: \(error)"
        }
    }

    private func criarMissao() async {
        let title = missaoTitulo.trimmingCharacters(in: .whitespacesAndNewlines)
        let dod = missaoDoD.trimmingCharacters(in: .whitespacesAndNewlines)
        let frente = missaoFrente.trimmingCharacters(in: .whitespacesAndNewlines)
        let obj = missaoFrenteObj.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !dod.isEmpty else { return }
        do {
            let created: MissionResult = try await callRoomRPC(
                .missionCreate,
                params: MissionCreateParams(
                    roomID: room.id, title: title, definitionOfDone: dod),
                expecting: MissionResult.self
            )
            if !frente.isEmpty, !obj.isEmpty {
                _ = try await callRoomRPC(
                    .workstreamCreate,
                    params: WorkstreamCreateParams(
                        roomID: room.id,
                        missionID: created.mission.id,
                        title: frente,
                        objective: obj,
                        definitionOfDone: dod
                    ),
                    expecting: WorkstreamResult.self
                )
                _ = try await callRoomRPC(
                    .missionTransition,
                    params: MissionTransitionParams(
                        roomID: room.id, missionID: created.mission.id, state: .active),
                    expecting: MissionResult.self
                )
            }
            await carregarMissoes()
        } catch {
            erro = "Falha ao criar missão: \(error)"
        }
    }

    private func ativarMissao(_ mission: Mission) async {
        do {
            _ = try await callRoomRPC(
                .missionTransition,
                params: MissionTransitionParams(
                    roomID: room.id, missionID: mission.id, state: .active),
                expecting: MissionResult.self
            )
            await carregarMissoes()
        } catch {
            erro = "Falha ao ativar: \(error)"
        }
    }

    private func arquivarMissao(_ mission: Mission) async {
        do {
            _ = try await callRoomRPC(
                .missionTransition,
                params: MissionTransitionParams(
                    roomID: room.id, missionID: mission.id, state: .archived,
                    reason: "Arquivada pelo usuário"),
                expecting: MissionResult.self
            )
            await carregarMissoes()
        } catch {
            erro = "Falha ao arquivar: \(error)"
        }
    }

    @MainActor
    private func carregarEventos() async {
        do {
            let snap: RoomSnapshotResult = try await callRoomRPC(.roomSnapshot, params: RoomSnapshotParams(roomID: room.id), expecting: RoomSnapshotResult.self)
            events = snap.events
            roomSeq = snap.roomSeq
        } catch {
            // snapshot pode falhar se não houver eventos ainda
        }
    }

    private func postMensagem() async {
        let texto = novaMensagem.trimmingCharacters(in: .whitespaces)
        guard !texto.isEmpty else { return }
        enviando = true
        do {
            if sessions.isEmpty {
                let result: AgentSessionResult = try await callRoomRPC(
                    .agentSessionCreate,
                    params: AgentSessionCreateParams(
                        roomID: room.id, workspaceID: ULID.generate(), nodeID: ULID.generate(),
                        objective: "Thread da sala \(room.name)"),
                    expecting: AgentSessionResult.self)
                sessions.append(result.agentSession)
                selectedSessionID = result.agentSession.id
            }
            guard let target = sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.first else { return }
            let kind: CollaborativeEventKind = .messageSent
            let payload = CollaborativeEventPayload(texto: texto)
            _ = try await callRoomRPC(
                .sessionEventAppend,
                params: SessionEventAppendParams(roomID: room.id, sessionID: target.id, kind: kind, payload: payload),
                expecting: SessionEventAppendResult.self)
            novaMensagem = ""
            await carregarEventos()
        } catch {
            erro = "Erro ao enviar: \(error)"
        }
        enviando = false
    }

    private func requestHandoff(_ session: AgentSession) async {
        do {
            _ = try await callRoomRPC(
                .agentSessionHandoffRequest,
                params: AgentSessionHandoffRequestParams(
                    agentSessionID: session.id, toMemberID: session.conductorID ?? currentMemberID, scope: .conductor),
                expecting: AgentSessionResult.self)
            await carregarEventos()
            await entrar() // recarrega sessions
        } catch { erro = "Erro no handoff: \(error)" }
    }

    private func acceptHandoff(_ session: AgentSession) async {
        do {
            _ = try await callRoomRPC(
                .agentSessionHandoffAccept,
                params: AgentSessionHandoffAcceptParams(agentSessionID: session.id),
                expecting: AgentSessionResult.self)
            await carregarEventos()
            await entrar()
        } catch { erro = "Erro ao aceitar: \(error)" }
    }

    private func rejectHandoff(_ session: AgentSession) async {
        do {
            _ = try await callRoomRPC(
                .agentSessionHandoffReject,
                params: AgentSessionHandoffAcceptParams(agentSessionID: session.id),
                expecting: AgentSessionResult.self)
            await carregarEventos()
            await entrar()
        } catch { erro = "Erro ao recusar: \(error)" }
    }

    private func lancarTerminalVPSNoCanvas() async {
        await store.addTerminal(
            nome: "Sala (\(room.name))",
            papel: "Colaborador",
            adapter: KnownAdapter.shell.rawValue,
            comandoOverride: "colmeia room join \(room.id.string) --hub \(hubURL)",
            cwd: "/opt/colmeia-canvas",
            monitorarAtividade: true
        )
        dismiss()
    }

    private var currentMemberID: String {
        InstallationIdentity.current().string
    }

    private func colorForState(_ state: AgentSessionState) -> Color {
        switch state {
        case .draft: return .gray
        case .ready: return .green
        case .running: return .blue
        case .waitingForDirection: return .orange
        case .waitingForApproval: return .yellow
        case .handoffPending: return .orange
        case .paused: return .purple
        case .completed: return .green
        case .failed: return .red
        case .archived: return .gray
        }
    }

    private func criarSession() async {
        let obj = objectiveNova.trimmingCharacters(in: .whitespaces)
        do {
            let result: AgentSessionResult = try await callRoomRPC(
                .agentSessionCreate,
                params: AgentSessionCreateParams(
                    roomID: room.id,
                    workspaceID: ULID.generate(),
                    nodeID: ULID.generate(),
                    objective: obj.isEmpty ? nil : obj),
                expecting: AgentSessionResult.self)
            sessions.append(result.agentSession)
            selectedSessionID = result.agentSession.id
            await carregarEventos()
        } catch {
            erro = "Erro ao criar sessão: \(error)"
        }
    }

    private func removerSala() async {
        do {
            _ = try await callRoomRPC(.roomDelete,
                params: RoomDeleteParams(roomID: room.id, confirmar: true),
                expecting: EmptyResult.self)
            dismiss()
        } catch {
            erro = "Erro ao apagar: \(error.localizedDescription)"
        }
    }
}

extension Member: Identifiable {}
extension AgentSession: Identifiable {}
extension CollaborativeSessionEvent: Identifiable {}

// MARK: - Chat Message Bubble (WhatsApp Style)

struct ChatMessageBubble: View {
    let event: CollaborativeSessionEvent
    let isMe: Bool

    private var text: String {
        event.payload.texto ?? event.payload.direction ?? event.payload.decision ?? ""
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: event.createdAt)
    }

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 40) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                if !isMe {
                    Text(event.author.rawValue)
                        .font(.caption2.bold())
                        .foregroundStyle(Color.accentColor)
                }
                Text(text)
                    .font(.body)
                    .foregroundStyle(isMe ? Color.white : Color.primary)
                    .multilineTextAlignment(isMe ? .trailing : .leading)

                HStack(spacing: 4) {
                    Text(timeString)
                        .font(.caption2)
                        .foregroundStyle(isMe ? Color.white.opacity(0.8) : Color.secondary)
                    if isMe {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.8))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isMe ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !isMe { Spacer(minLength: 40) }
        }
    }
}
