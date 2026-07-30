import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

private func memoryTestDirectory() -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cmem-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("Memória isolada por workspace", .serialized)
struct MemoryStoreTests {
    @Test func propostasSaoPendentesEAceitacaoHumanaPersiste() throws {
        let root = memoryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceMemoryStore(workspaceDirectory: root)
        let agent = Author.agente("01AGENTE")
        let human = Author.humanoLocal
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let proposalID = ULID.generate()

        _ = try store.update("Orientação já aprovada.", author: human, now: createdAt)
        let proposal = try store.propose("Preferir testes de integração curtos.", author: agent, id: proposalID, now: createdAt)
        #expect(proposal.status == .pending)
        #expect(store.get().content == "Orientação já aprovada.")
        #expect(store.list(status: .pending).map(\.id) == [proposalID])

        let accepted = try store.accept(
            proposalID, author: human, editedContent: "Preferir testes de integração focados.",
            now: createdAt.addingTimeInterval(60))
        #expect(accepted.content == "Orientação já aprovada.\n\nPreferir testes de integração focados.")
        #expect(store.list(status: .accepted).first?.resolvedBy == human)

        let reloaded = WorkspaceMemoryStore(workspaceDirectory: root)
        #expect(reloaded.get().content == "Orientação já aprovada.\n\nPreferir testes de integração focados.")
        #expect(reloaded.history().map(\.action).contains(.proposalAccepted))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("MEMORY.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("memory-proposals.json").path))
    }

    @Test func diarioEBriefingSaoPersistentesELimitadosAoDia() throws {
        let root = memoryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceMemoryStore(workspaceDirectory: root)
        let day = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 UTC
        _ = try store.update("Contexto estável do projeto.", author: .humanoLocal, now: day)
        let daily = try store.appendDaily("Decisão: manter o protocolo compatível.", author: .humanoLocal, date: day)
        #expect(daily.contains("Decisão: manter o protocolo compatível."))
        let automatic = try store.appendDaily("Rotina automática concluída.", author: .sistema, date: day)
        #expect(automatic.contains("Rotina automática concluída."))
        let briefing = store.briefing(for: day)
        #expect(briefing.memory.content == "Contexto estável do projeto.")
        #expect(briefing.daily.contains("manter o protocolo compatível"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("daily/2024-01-01.md").path))
    }

    @Test func agenteNaoPromoveMemoriaEHumanoNaoPodeFingirPropostaDeAgente() throws {
        let root = memoryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceMemoryStore(workspaceDirectory: root)
        let agent = Author.agente("01AGENTE")
        let proposal = try store.propose("Sugestão revisável.", author: agent)

        do {
            _ = try store.update("promoção indevida", author: agent)
            Issue.record("agente não pode atualizar MEMORY.md diretamente")
        } catch let error as MemoryStoreError {
            #expect(error == .authorizationDenied)
        }
        do {
            _ = try store.accept(proposal.id, author: agent)
            Issue.record("agente não pode aceitar a própria proposta")
        } catch let error as MemoryStoreError {
            #expect(error == .authorizationDenied)
        }
        do {
            _ = try store.propose("proposta humana inválida", author: .humanoLocal)
            Issue.record("propostas são reservadas à identidade de agente")
        } catch let error as MemoryStoreError {
            #expect(error == .authorizationDenied)
        }
        #expect(store.get().content.isEmpty)
        #expect(store.list(status: .pending).count == 1)
    }

    @Test func sanitizaSegredosERecusaTranscricoesBrutas() throws {
        let root = memoryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceMemoryStore(workspaceDirectory: root)
        let saved = try store.update(
            "Chave rotacionada: api_key=sk-abcdefghijklmnopqrstuvwxyz123456; usar variável de ambiente.",
            author: .humanoLocal)
        #expect(saved.content.contains("[SEGREDO_REMOVIDO]"))
        #expect(!saved.content.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        #expect(!store.get().content.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))

        do {
            _ = try store.propose("BEGIN RAW OUTPUT\nlinha de terminal\nEND RAW OUTPUT", author: .agente("01AGENTE"))
            Issue.record("saída bruta não deve entrar em proposta de memória")
        } catch let error as MemoryStoreError {
            #expect(error == .invalidContent)
        }
    }

    @Test func repeticoesDePropostaEAceitacaoNaoDuplicamMemoriaOuHistorico() throws {
        let root = memoryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceMemoryStore(workspaceDirectory: root)
        let id = ULID.generate()
        let agent = Author.agente("01AGENTE")
        let first = try store.propose("Registrar decisão A.", author: agent, id: id)
        let replay = try store.propose("conteúdo diferente ignorado no replay", author: agent, id: id)
        #expect(first.id == replay.id)
        #expect(first.content == replay.content)
        #expect(store.list().count == 1)

        let once = try store.accept(id, author: .humanoLocal)
        let twice = try store.accept(id, author: .humanoLocal)
        #expect(once.content == twice.content)
        #expect(store.get().content == "Registrar decisão A.")
        #expect(store.history().filter { $0.action == .proposalAccepted }.count == 1)
    }
}
