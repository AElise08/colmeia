import Foundation
import Testing
@testable import ColmeiaEngine
import ColmeiaKit

struct ChatMessageStoreTests {
    @Test func mensagensPersistemERecarregamOrdenadas() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("colmeia-chat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("chat.json")
        let workspaceID = ULID.generate()
        let first = ChatMessage(
            workspaceID: workspaceID,
            toNodeID: ULID.generate(),
            text: "  primeiro  ",
            createdAt: Date(timeIntervalSince1970: 10))
        let second = ChatMessage(
            workspaceID: workspaceID,
            fromNodeID: ULID.generate(),
            toNodeID: first.toNodeID,
            text: "segundo",
            createdAt: Date(timeIntervalSince1970: 20))

        let store = try ChatMessageStore(fileURL: file)
        #expect(try store.append(first).text == "primeiro")
        #expect(try store.append(second) == second)
        #expect(store.list() == [first.withText("primeiro"), second])

        let restored = try ChatMessageStore(fileURL: file)
        #expect(restored.list() == [first.withText("primeiro"), second])
    }

    @Test func appendIdempotenteMasConflitoEhRejeitado() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("colmeia-chat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let message = ChatMessage(workspaceID: ULID.generate(), toNodeID: ULID.generate(), text: "ok")
        let store = try ChatMessageStore(fileURL: root.appendingPathComponent("chat.json"))
        _ = try store.append(message)
        _ = try store.append(message)
        #expect(throws: ChatMessageStoreError.self) {
            try store.append(ChatMessage(id: message.id, workspaceID: message.workspaceID,
                                         toNodeID: message.toNodeID, text: "outro"))
        }
    }

    @Test func filtroELimiteNaoPermitemCrescimentoSemControle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("colmeia-chat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try ChatMessageStore(fileURL: root.appendingPathComponent("chat.json"))
        let workspaceID = ULID.generate()
        let target = ULID.generate()
        for index in 0..<5 {
            _ = try store.append(ChatMessage(workspaceID: workspaceID, toNodeID: target, text: "\(index)"))
        }
        _ = try store.append(ChatMessage(workspaceID: workspaceID, toNodeID: ULID.generate(), text: "other"))
        #expect(store.list(toNodeID: target, limit: 2).count == 2)
        #expect(store.list(toNodeID: target, limit: 2).last?.text == "4")
    }
}

private extension ChatMessage {
    func withText(_ value: String) -> ChatMessage {
        ChatMessage(id: id, workspaceID: workspaceID, fromNodeID: fromNodeID,
                    toNodeID: toNodeID, text: value, attachments: attachments, createdAt: createdAt)
    }
}
