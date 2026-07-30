import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

@Suite("Backpressure do transporte (§6.5)")
struct BackpressureTests {
    private func output(_ sessionID: ULID, seq: UInt64, bytes: Data = Data("x".utf8)) -> Envelope {
        let payload = try! JSONValue(encoding: SessionOutputTopicPayload(
            sessionID: sessionID, seq: seq, dataB64: bytes.base64EncodedString()))
        return .event(EventMessage(topic: .sessionOutput, params: payload))
    }

    @Test func coalesceSoOutputAdjacenteEMantemOutroTopico() {
        let engine = Engine(paths: ColmeiaPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())))
        let client = ClientConnection(fd: -1, engine: engine, writerEnabled: false)
        let session = ULID.generate()
        for seq in 1...300 { client.send(output(session, seq: UInt64(seq))) }
        // Até o limite suave preserva chunks; depois os adjacentes viram um stream.
        #expect(client.queuedEventCountForTesting == ClientConnection.coalesceAfter)
        let state = try! JSONValue(encoding: SessionStateTopicPayload(sessionID: session, estado: .rodando))
        client.send(.event(EventMessage(topic: .sessionState, params: state)))
        #expect(client.queuedEventCountForTesting == ClientConnection.coalesceAfter + 1)
    }

    @Test func limiteDuroAgendaAvisoEDesconexaoSemDescartarTopicosNoBuffer() {
        let engine = Engine(paths: ColmeiaPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())))
        let client = ClientConnection(fd: -1, engine: engine, writerEnabled: false)
        // Sessões distintas não são adjacentes coalescíveis.
        for seq in 1...(ClientConnection.maxQueuedEvents + 1) {
            client.send(output(ULID.generate(), seq: UInt64(seq)))
        }
        #expect(client.backpressureScheduledForTesting)
        #expect(client.backpressureWarningEnqueuedForTesting) // warning entra antes do drop agendado
        // +1 é o `engine.warning` colocado à frente do backlog antes do disconnect.
        #expect(client.queuedEventCountForTesting == ClientConnection.maxQueuedEvents + 2)
    }

    @Test func orcamentoDeBytesProtegeOutputCoalescidoDeClienteTravado() {
        let engine = Engine(paths: ColmeiaPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())))
        let client = ClientConnection(fd: -1, engine: engine, writerEnabled: false)
        let oversized = Data(repeating: 0x78, count: ClientConnection.maxQueuedBytes + 1)
        client.send(output(ULID.generate(), seq: 1, bytes: oversized))
        #expect(client.queuedByteCountForTesting > ClientConnection.maxQueuedBytes)
        #expect(client.backpressureWarningEnqueuedForTesting)
        #expect(client.backpressureScheduledForTesting)
    }
}
