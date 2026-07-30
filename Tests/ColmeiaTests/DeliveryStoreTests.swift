import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

private func deliveryTempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("colm-deliveries-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func validEvidence(
    id: ULID = ULID.generate(),
    author: Author = .agente("builder"),
    at: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> DeliveryEvidence {
    DeliveryEvidence(
        id: id,
        tipo: .test,
        referencia: "ColmeiaTests.DeliveryStoreTests/submit",
        descricao: "teste focal passou",
        resultadoTeste: .passed,
        autor: author,
        criadaEm: at
    )
}

private func validSubmission(
    id: ULID = ULID.generate(),
    workspaceID: ULID = ULID.generate(),
    sessionID: ULID = ULID.generate(),
    nodeID: ULID = ULID.generate(),
    estado: DeliveryEstado = .proposed,
    evidence: DeliveryEvidence? = nil
) -> DeliverySubmission {
    DeliverySubmission(
        id: id,
        workspaceID: workspaceID,
        sessionID: sessionID,
        nodeID: nodeID,
        estado: estado,
        resumo: "Implementação concluída com teste focal.",
        evidencias: [evidence ?? validEvidence()]
    )
}

@Suite("Entregas e evidências")
struct DeliveryStoreTests {
    @Test func validaResumoEReferenciaSemComandoArbitrario() throws {
        var empty = validSubmission()
        empty.resumo = " \n "
        #expect(throws: DeliveryValidationError.self) { try empty.validate() }

        var noEvidence = validSubmission()
        noEvidence.evidencias = []
        #expect(throws: DeliveryValidationError.self) { try noEvidence.validate() }

        for estado in [DeliveryEstado.partial, .blocked, .failed] {
            var declaracao = validSubmission(estado: estado)
            declaracao.evidencias = []
            try declaracao.validate()
        }

        let malicious = DeliveryEvidence(
            id: ULID.generate(), tipo: .test, referencia: "swift-test;rm-rf", resultadoTeste: .passed,
            autor: .agente("builder"), criadaEm: Date()
        )
        var invalidTest = validSubmission(evidence: malicious)
        #expect(throws: DeliveryValidationError.self) { try invalidTest.validate() }

        let pathEscape = DeliveryEvidence(
            id: ULID.generate(), tipo: .file, referencia: "../segredo.txt", autor: .agente("builder"), criadaEm: Date()
        )
        invalidTest = validSubmission(evidence: pathEscape)
        #expect(throws: DeliveryValidationError.self) { try invalidTest.validate() }
    }

    @Test func aceitaTodasAsClassesDeEvidenciaComRepresentacaoVerificavel() throws {
        let author = Author.agente("worker")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sha = String(repeating: "a", count: 64)
        let evidences: [DeliveryEvidence] = [
            DeliveryEvidence(id: ULID.generate(), tipo: .file, referencia: "Sources/App.swift", sha256: sha, autor: author, criadaEm: now),
            DeliveryEvidence(id: ULID.generate(), tipo: .diff, referencia: "patch:canvas", sha256: sha, autor: author, criadaEm: now),
            DeliveryEvidence(id: ULID.generate(), tipo: .commit, referencia: "a1b2c3d", autor: author, criadaEm: now),
            DeliveryEvidence(id: ULID.generate(), tipo: .test, referencia: "Target.Suite/test", resultadoTeste: .passed, autor: author, criadaEm: now),
            DeliveryEvidence(id: ULID.generate(), tipo: .note, referencia: ULID.generate().string, autor: author, criadaEm: now),
            DeliveryEvidence(id: ULID.generate(), tipo: .portal, referencia: "https://example.com/proof", autor: author, criadaEm: now),
            DeliveryEvidence(id: ULID.generate(), tipo: .outputExcerpt, referencia: "42 tests passed", autor: author, criadaEm: now),
            DeliveryEvidence(id: ULID.generate(), tipo: .artifact, referencia: "artifacts/report.json", sha256: sha, autor: author, criadaEm: now),
        ]
        for evidence in evidences { try evidence.validate() }
    }

    @Test func submissaoEIdempotenteEPersisteHistorico() throws {
        let directory = try deliveryTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let submission = validSubmission()
        let at = Date(timeIntervalSince1970: 1_700_000_100)
        let store = try DeliveryStore(directory: directory)

        let first = try store.submit(submission, author: .agente("worker"), at: at)
        let retry = try store.submit(submission, author: .agente("worker"), at: at.addingTimeInterval(5))
        #expect(first == retry)
        #expect(first.historico.count == 1)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))

        let restored = try DeliveryStore(directory: directory)
        #expect(restored.delivery(id: submission.id) == first)

        var conflicting = submission
        conflicting.resumo = "Outro conteúdo para o mesmo ID"
        #expect(throws: DeliveryStoreError.self) {
            try store.submit(conflicting, author: .agente("worker"), at: at)
        }
    }

    @Test func apenasHumanoAceitaEOReabrirPreservaAuditoria() throws {
        let directory = try deliveryTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DeliveryStore(directory: directory)
        let submission = validSubmission(estado: .partial)
        let submitted = try store.submit(submission, author: .agente("worker"), at: Date(timeIntervalSince1970: 10))

        #expect(throws: DeliveryStoreError.self) {
            try store.accept(submitted.id, by: .agente("worker"), at: Date(timeIntervalSince1970: 11))
        }
        #expect(throws: DeliveryStoreError.self) {
            try store.reopen(submitted.id, by: .humanoLocal, at: Date(timeIntervalSince1970: 11))
        }

        let accepted = try store.accept(submitted.id, by: .humanoLocal, at: Date(timeIntervalSince1970: 12))
        #expect(accepted.aceita)
        #expect(accepted.historico.map(\.acao) == [.submitted, .accepted])

        let reopened = try store.reopen(submitted.id, by: .humanoLocal, at: Date(timeIntervalSince1970: 13))
        #expect(!reopened.aceita)
        #expect(reopened.estado == .reopened)
        #expect(reopened.historico.map(\.acao) == [.submitted, .accepted, .reopened])

        let restored = try DeliveryStore(directory: directory)
        #expect(restored.delivery(id: submitted.id)?.historico == reopened.historico)
    }

    @Test func estadoFinalNuncaEDerivadoDeOciosidadeDaSessao() throws {
        // O serviço recebe somente um estado declarado no payload; SessionEstado
        // não participa da API, então `ociosa` não pode virar accepted por acaso.
        let submission = validSubmission(estado: .blocked)
        #expect(submission.estado == .blocked)
        #expect(DeliveryEstado.allCases == [
            .draft, .proposed, .accepted, .partial, .blocked, .failed, .reopened
        ])
    }
}
