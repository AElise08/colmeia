import Foundation
import ColmeiaKit

// MARK: - Contrato (§10.1)

public struct LaunchConfig: Sendable {
    public var node: TerminalNode
    public var workspace: Workspace

    public init(node: TerminalNode, workspace: Workspace) {
        self.node = node
        self.workspace = workspace
    }
}

/// §10.2 — o engine soma, independente do adapter: PATH com a CLI, COLMEIA_*, TERM.
public struct LaunchPlan: Sendable {
    public var executavel: String
    public var args: [String]
    public var envExtra: [String: String]

    public init(executavel: String, args: [String] = [], envExtra: [String: String] = [:]) {
        self.executavel = executavel
        self.args = args
        self.envExtra = envExtra
    }
}

/// §10.1 — o que o adapter enxerga para classificar.
public struct AdapterContexto: Sendable {
    public var ultimoChunk: Data
    /// Tail do output recente, já decodificado (lossy UTF-8), COM escapes ANSI.
    public var bufferRecente: String
    public var silencioSeg: Double
    public var tituloOSC: String?
    public var belRecente: Bool

    public init(
        ultimoChunk: Data, bufferRecente: String, silencioSeg: Double,
        tituloOSC: String? = nil, belRecente: Bool = false
    ) {
        self.ultimoChunk = ultimoChunk
        self.bufferRecente = bufferRecente
        self.silencioSeg = silencioSeg
        self.tituloOSC = tituloOSC
        self.belRecente = belRecente
    }
}

public struct ApprovalDraft: Equatable, Sendable {
    public var resumo: String
    public var opcoes: [String]?

    public init(resumo: String, opcoes: [String]? = nil) {
        self.resumo = resumo
        self.opcoes = opcoes
    }
}

/// §10 — todo conhecimento específico de motor vive aqui; o engine não conhece
/// binário, regex nem formato de nenhum motor (§4.6).
public protocol AgentAdapter: Sendable {
    var id: String { get }
    var nomeExibicao: String { get }
    func disponivel() -> Bool
    func launch(_ config: LaunchConfig) -> LaunchPlan
    /// nil = "não sei" (o engine aplica fallback rodando/ociosa por I/O).
    func classify(_ contexto: AdapterContexto) throws -> SessionEstado?
    func detectApproval(_ contexto: AdapterContexto) throws -> ApprovalDraft?
    /// Bytes exatos que o motor espera; nil = não mapeável → `invalid_params` (§10.4).
    func injectReply(_ approval: Approval, decisao: ApprovalDecisao, opcaoIndex: Int?) -> Data?
}

public extension AgentAdapter {
    func classify(_ contexto: AdapterContexto) throws -> SessionEstado? { nil }
    func detectApproval(_ contexto: AdapterContexto) throws -> ApprovalDraft? { nil }
    func injectReply(_ approval: Approval, decisao: ApprovalDecisao, opcaoIndex: Int?) -> Data? { nil }
}

/// Registro plugável (§4.6): motor novo = adapter novo, zero mudança no engine (25.3.1).
public final class AdapterRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var adapters: [String: AgentAdapter] = [:]

    public init() {}

    public static func standard() -> AdapterRegistry {
        let registry = AdapterRegistry()
        registry.register(ShellAdapter())
        registry.register(ClaudeCodeAdapter())
        registry.register(CodexAdapter())
        registry.register(GeminiCliAdapter())
        registry.register(OpenCodeAdapter())
        return registry
    }

    public func register(_ adapter: AgentAdapter) {
        lock.lock()
        defer { lock.unlock() }
        adapters[adapter.id] = adapter
    }

    public func find(_ id: String) -> AgentAdapter? {
        lock.lock()
        defer { lock.unlock() }
        return adapters[id]
    }
}

// MARK: - Heurísticas compartilhadas

enum AdapterHeuristics {
    static let spinnerScalars = Set("⠁⠂⠄⡀⢀⠠⠐⠈⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏✢✳✶✻·✽∗*")
    /// Limiar de silêncio → ociosa (§10.3, DEVERIA ser 30s).
    static let limiarOciosaSeg: Double = 30

    static func temSpinner(_ chunk: Data) -> Bool {
        let text = TerminalText.decodeLossy(chunk)
        return text.unicodeScalars.contains { spinnerScalars.contains(Character($0)) }
    }

    static func ultimaLinhaVisivel(_ buffer: String) -> String {
        let limpo = TerminalText.stripANSI(buffer)
        for line in limpo.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Prompt de menu numerado precedido de pergunta — formato dos pedidos de permissão
    /// do Claude Code (e parecidos). Retorna (pergunta, opções).
    static func menuNumerado(_ buffer: String) -> (String, [String])? {
        let limpo = TerminalText.stripANSI(String(buffer.suffix(6000)))
        let linhas = limpo.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var opcoes: [String] = []
        var primeiraOpcaoIdx: Int?
        var esperado = 1
        var idx = 0
        for linha in linhas {
            var corpo = linha
            if corpo.hasPrefix("❯") {
                corpo = corpo.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            if corpo.hasPrefix("\(esperado). ") {
                if esperado == 1 { primeiraOpcaoIdx = idx }
                opcoes.append(String(corpo.dropFirst("\(esperado). ".count)))
                esperado += 1
            } else if esperado > 1, !corpo.isEmpty {
                // menu terminou; se já temos ≥ 2 opções, aceita
                if opcoes.count >= 2 { break }
                opcoes = []
                esperado = 1
                primeiraOpcaoIdx = nil
            }
            idx += 1
        }
        guard opcoes.count >= 2, let inicio = primeiraOpcaoIdx else { return nil }
        var pergunta = ""
        var cursor = inicio - 1
        while cursor >= 0 {
            let linha = linhas[cursor].trimmingCharacters(in: CharacterSet(charactersIn: " │┃|"))
            if !linha.isEmpty {
                pergunta = linha
                if linha.hasSuffix("?") { break }
            }
            cursor -= 1
        }
        guard !pergunta.isEmpty else { return nil }
        return (pergunta, opcoes)
    }

    /// aprovar → primeira opção afirmativa; negar → primeira negativa (senão a última).
    static func mapearDecisao(_ opcoes: [String], decisao: ApprovalDecisao) -> Int? {
        func é(_ opcao: String, _ prefixos: [String]) -> Bool {
            let lower = opcao.lowercased()
            return prefixos.contains { lower.hasPrefix($0) }
        }
        switch decisao {
        case .aprovar:
            return opcoes.firstIndex { é($0, ["yes", "sim", "allow", "approve", "aceitar"]) } ?? 0
        case .negar:
            if let idx = opcoes.firstIndex(where: { é($0, ["no", "não", "nao", "deny", "reject", "cancel", "esc"]) }) {
                return idx
            }
            return opcoes.count > 1 ? opcoes.count - 1 : nil
        }
    }
}

// MARK: - shell (§10.3: classify nil sempre)

public struct ShellAdapter: AgentAdapter {
    public let id = "shell"
    public let nomeExibicao = "Shell"

    public init() {}

    public func disponivel() -> Bool { true }

    public func launch(_ config: LaunchConfig) -> LaunchPlan {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return LaunchPlan(executavel: shell, args: ["-l"])
    }
}

// MARK: - claude-code (§10.3–10.4)

public struct ClaudeCodeAdapter: AgentAdapter {
    public let id = "claude-code"
    public let nomeExibicao = "Claude Code"

    public init() {}

    public func disponivel() -> Bool { which("claude") }

    public func launch(_ config: LaunchConfig) -> LaunchPlan {
        LaunchPlan(executavel: "claude")
    }

    public func classify(_ contexto: AdapterContexto) throws -> SessionEstado? {
        if try detectApproval(contexto) != nil { return .aprovacaoPendente }
        if AdapterHeuristics.temSpinner(contexto.ultimoChunk) { return .rodando }
        let limpo = TerminalText.stripANSI(String(contexto.bufferRecente.suffix(4000)))
        if limpo.contains("esc to interrupt") || limpo.contains("tokens ·") { return .rodando }
        let ultima = AdapterHeuristics.ultimaLinhaVisivel(contexto.bufferRecente)
        let promptVazio = ultima.hasPrefix("❯") || ultima.hasPrefix(">") || limpo.hasSuffix("│\n╰")
        if promptVazio, contexto.silencioSeg > 1.0 { return .esperandoHumano }
        if contexto.belRecente, contexto.silencioSeg > 1.0 { return .esperandoHumano }
        if contexto.silencioSeg > AdapterHeuristics.limiarOciosaSeg { return .ociosa }
        if contexto.silencioSeg < 2.0 { return .rodando }
        return nil
    }

    public func detectApproval(_ contexto: AdapterContexto) throws -> ApprovalDraft? {
        guard let (pergunta, opcoes) = AdapterHeuristics.menuNumerado(contexto.bufferRecente) else {
            return nil
        }
        let marcadores = [
            "do you want", "would you like", "allow", "permission", "permitir",
            "proceed", "run this", "trust", "approve",
        ]
        let lower = pergunta.lowercased()
        let opcaoAfirmativa = opcoes.contains { $0.lowercased().hasPrefix("yes") || $0.lowercased().hasPrefix("sim") }
        guard marcadores.contains(where: { lower.contains($0) }) || (pergunta.hasSuffix("?") && opcaoAfirmativa)
        else { return nil }
        return ApprovalDraft(resumo: pergunta, opcoes: opcoes)
    }

    public func injectReply(_ approval: Approval, decisao: ApprovalDecisao, opcaoIndex: Int?) -> Data? {
        guard let opcoes = approval.opcoes, !opcoes.isEmpty else { return nil }
        let index: Int
        if let opcaoIndex {
            guard opcoes.indices.contains(opcaoIndex) else { return nil }
            index = opcaoIndex
        } else if let mapped = AdapterHeuristics.mapearDecisao(opcoes, decisao: decisao) {
            index = mapped
        } else {
            return nil
        }
        // Menus do Claude Code atual selecionam e confirmam pela tecla numérica.
        return Data("\(index + 1)".utf8)
    }
}

// MARK: - codex / gemini-cli / opencode (launch correto + classify básico por silêncio)

public struct CodexAdapter: AgentAdapter {
    public let id = "codex"
    public let nomeExibicao = "Codex CLI"

    public init() {}
    public func disponivel() -> Bool { which("codex") }
    public func launch(_ config: LaunchConfig) -> LaunchPlan { LaunchPlan(executavel: "codex") }

    public func classify(_ contexto: AdapterContexto) throws -> SessionEstado? {
        if AdapterHeuristics.temSpinner(contexto.ultimoChunk) { return .rodando }
        if contexto.silencioSeg > AdapterHeuristics.limiarOciosaSeg { return .ociosa }
        return nil
    }
}

public struct GeminiCliAdapter: AgentAdapter {
    public let id = "gemini-cli"
    public let nomeExibicao = "Gemini CLI"

    public init() {}
    public func disponivel() -> Bool { which("gemini") }
    public func launch(_ config: LaunchConfig) -> LaunchPlan { LaunchPlan(executavel: "gemini") }

    public func classify(_ contexto: AdapterContexto) throws -> SessionEstado? {
        if AdapterHeuristics.temSpinner(contexto.ultimoChunk) { return .rodando }
        if contexto.silencioSeg > AdapterHeuristics.limiarOciosaSeg { return .ociosa }
        return nil
    }
}

public struct OpenCodeAdapter: AgentAdapter {
    public let id = "opencode"
    public let nomeExibicao = "OpenCode"

    public init() {}
    public func disponivel() -> Bool { which("opencode") }
    public func launch(_ config: LaunchConfig) -> LaunchPlan { LaunchPlan(executavel: "opencode") }

    public func classify(_ contexto: AdapterContexto) throws -> SessionEstado? {
        if AdapterHeuristics.temSpinner(contexto.ultimoChunk) { return .rodando }
        if contexto.silencioSeg > AdapterHeuristics.limiarOciosaSeg { return .ociosa }
        return nil
    }
}
