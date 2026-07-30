import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

@Suite("Fixtures de adapters (§10.3–§10.5)")
struct AdapterFixturesTests {
    private func context(_ text: String, silence: Double = 2) -> AdapterContexto {
        AdapterContexto(ultimoChunk: Data(text.utf8), bufferRecente: text, silencioSeg: silence)
    }

    @Test func transcriptClaudeDetectaPermissaoMasShellNunca() throws {
        let transcript = """
        \u{1B}[1mBash command\u{1B}[0m
        rm -rf build/

        Do you want to proceed?
        ❯ 1. Yes
          2. Yes, and don't ask again this session
          3. No, and tell Claude what to do differently
        """
        let claude = ClaudeCodeAdapter()
        let draft = try #require(try claude.detectApproval(context(transcript)))
        #expect(draft.resumo == "Do you want to proceed?")
        #expect(draft.opcoes?.count == 3)
        #expect(try claude.classify(context(transcript)) == .aprovacaoPendente)
        #expect(try ShellAdapter().detectApproval(context(transcript)) == nil)
        #expect(try ShellAdapter().classify(context(transcript, silence: 120)) == nil)
    }

    @Test func fixtureOpenCodeUsaApenasDialogoCompletoEDuasTeclasDocumentadas() throws {
        let transcript = """
        Permission required to run bash: git push origin main
        [a] Allow permission   [A] Allow for session   [d] Deny permission
        """
        let adapter = OpenCodeAdapter()
        let draft = try #require(try adapter.detectApproval(context(transcript)))
        #expect(draft.resumo == "Permission required to run bash: git push origin main")
        #expect(draft.opcoes == ["Allow", "Deny"])
        let approval = Approval(
            id: ULID.generate(), sessionID: ULID.generate(), nodeNome: "open",
            resumo: draft.resumo, opcoes: draft.opcoes, estado: .pendente, criadaEm: Date())
        #expect(adapter.injectReply(approval, decisao: .aprovar, opcaoIndex: nil) == Data("a\r".utf8))
        #expect(adapter.injectReply(approval, decisao: .negar, opcaoIndex: nil) == Data("d\r".utf8))
        #expect(adapter.injectReply(approval, decisao: .aprovar, opcaoIndex: 4) == nil)
    }

    @Test func gatesNegativosNaoInventamApprovalParaOutrosMotores() throws {
        let prose = "The model may allow permission checks, but this is ordinary output."
        let ctx = context(prose)
        #expect(try CodexAdapter().detectApproval(ctx) == nil)
        #expect(try GeminiCliAdapter().detectApproval(ctx) == nil)
        #expect(try OpenCodeAdapter().detectApproval(ctx) == nil)
        let unknownOptions = Approval(
            id: ULID.generate(), sessionID: ULID.generate(), nodeNome: "open", resumo: "?",
            opcoes: ["Always", "Never"], estado: .pendente, criadaEm: Date())
        #expect(OpenCodeAdapter().injectReply(unknownOptions, decisao: .aprovar, opcaoIndex: nil) == nil)
    }

    @Test func tituloOSCEBellSaoEdgeTriggered() {
        let firstChunk = Data("\u{1B}]2;Colmeia — ".utf8)
        let oscAcrossChunks = firstChunk + Data("Codex\u{1B}\\".utf8)
        #expect(TerminalControlSequences.lastOSCTitle(in: firstChunk) == nil)
        #expect(TerminalControlSequences.lastOSCTitle(in: oscAcrossChunks) == "Colmeia — Codex")
        #expect(TerminalControlSequences.lastOSCTitle(in: Data("sem osc\u{07}".utf8)) == nil)
    }
}
