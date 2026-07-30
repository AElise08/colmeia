import SwiftUI
import ColmeiaKit

struct ShareSheetView: View {
    let room: Room
    let hubURL: String
    @ObservedObject var hub: HubConnection

    @Environment(\.dismiss) private var dismiss
    @State private var role: MemberRole = .viewer
    @State private var ttl: InviteTTL = .day
    @State private var invites: [InviteToken] = []
    @State private var createdLink: String?
    @State private var erro: String?
    @State private var carregando = false

    enum InviteTTL: String, CaseIterable, Identifiable {
        case hour = "1 hora"
        case day = "24 horas"
        case week = "7 dias"
        case never = "Nunca"
        var id: String { rawValue }
        var seconds: Int? {
            switch self {
            case .hour: return 3600
            case .day: return 86400
            case .week: return 604800
            case .never: return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Compartilhar Sala").font(.headline)
                Spacer()
                Button("Fechar") { dismiss() }.buttonStyle(.plain)
            }
            .padding(.horizontal)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Criar Convite") {
                        VStack(spacing: 8) {
                            Picker("Papel", selection: $role) {
                                Text("Visualizador").tag(MemberRole.viewer)
                                Text("Editor").tag(MemberRole.editor)
                            }
                            .pickerStyle(.segmented)

                            Picker("Expira em", selection: $ttl) {
                                ForEach(InviteTTL.allCases) { t in
                                    Text(t.rawValue).tag(t)
                                }
                            }
                            .pickerStyle(.menu)

                            Button("Gerar Link") {
                                Task { await criar() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(carregando)

                            if let link = createdLink {
                                HStack {
                                    Text(link).font(.caption.monospaced()).lineLimit(1)
                                    Button("Copiar") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(link, forType: .string)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(8)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                        .padding(8)
                    }

                    GroupBox("Convites Ativos") {
                        if invites.isEmpty {
                            Text("Nenhum convite").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(invites, id: \.token) { invite in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(invite.displayName)
                                            .font(.subheadline.bold())
                                        HStack(spacing: 4) {
                                            Text(invite.roles.map(\.rawValue).joined(separator: ", "))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text("·")
                                            Text(statusText(invite))
                                                .font(.caption2)
                                                .foregroundStyle(statusColor(invite))
                                        }
                                        Text("expira \(invite.expiresAt.formatted(date: .numeric, time: .shortened))")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if invite.isValid {
                                        Button("Revogar") {
                                            Task { await revogar(invite.token) }
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                    }
                                }
                                .padding(6)
                                .background(Color.secondary.opacity(0.06))
                                .cornerRadius(6)
                            }
                        }
                    }
                }
                .padding()
            }

            if let erro {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(erro).font(.caption).foregroundStyle(.red)
                }
                .padding(.horizontal)
            }
        }
        .frame(width: 420, height: 480)
        .task { await carregar() }
    }

    private func statusText(_ invite: InviteToken) -> String {
        if invite.used { return "usado" }
        if invite.isExpired { return "expirado" }
        return "ativo"
    }

    private func statusColor(_ invite: InviteToken) -> Color {
        if invite.used { return .gray }
        if invite.isExpired { return .orange }
        return .green
    }

    private func hostBase() -> String {
        hubURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
    }

    private func call<R: Decodable>(_ method: ColmeiaMethod, params: some Encodable, expecting: R.Type) async throws -> R {
        try await hub.call(method, params: params, expecting: expecting)
    }

    private func criar() async {
        carregando = true
        erro = nil
        do {
            let res = try await call(.memberInvite,
                params: MemberInviteParams(roomID: room.id, displayName: "Convidado", roles: [role], ttlSeconds: ttl.seconds),
                expecting: MemberInviteResult.self)
            createdLink = "\(hostBase())/join/\(room.id.string)/\(res.inviteToken)"
            try? await Task.sleep(nanoseconds: 500_000_000)
            await carregar()
        } catch {
            erro = mensagemAmigavel(error)
        }
        carregando = false
    }

    private func revogar(_ token: String) async {
        erro = nil
        do {
            let _: EmptyResult = try await call(.memberInviteRevoke,
                params: MemberInviteRevokeParams(roomID: room.id, token: token),
                expecting: EmptyResult.self)
            await carregar()
        } catch {
            erro = mensagemAmigavel(error)
        }
    }

    private func carregar() async {
        erro = nil
        do {
            let list: MemberInviteListResult = try await call(.memberInviteList,
                params: MemberInviteListParams(roomID: room.id),
                expecting: MemberInviteListResult.self)
            invites = list
        } catch {
            erro = mensagemAmigavel(error)
        }
    }

    private func mensagemAmigavel(_ error: Error) -> String {
        if let proto = error as? ProtocolError {
            switch proto.known {
            case .room_not_found: return "Sala não encontrada. Pode ter sido apagada."
            case .invite_invalid: return "Convite inválido ou já usado."
            case .invite_expired: return "Convite expirado."
            case .insufficient_permissions: return "Sem permissão para esta operação."
            case .internal_error: return "Erro interno do servidor. Tente novamente."
            default: break
            }
        }
        let desc = error.localizedDescription
        if desc.contains("conexão") || desc.contains("conect") || desc.contains("Hub") {
            return "Hub offline. Verifique sua conexão."
        }
        return desc
    }
}
