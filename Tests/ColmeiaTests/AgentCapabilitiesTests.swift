import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaEngine

/// Aceitação por socket: nenhum teste chama handlers privados diretamente.
@Suite("Capacidades de agentes — notas, nós e portal", .serialized)
struct AgentCapabilitiesTests {
    @Test func papelLegadoMigraParaRainhaNoBoot() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("role-migration-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ColmeiaPaths(root: root)

        let firstEngine = Engine(paths: paths)
        try firstEngine.start()
        let human = SocketClient()
        try human.connect(to: paths.engineSocket.path)
        _ = try await human.hello(client: "role-migration-human")
        let workspace = try await human.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "Migração", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self).workspace
        let legacyNode = TerminalNode(
            id: ULID.generate(), posicao: Ponto(x: 0, y: 0), tamanho: Tamanho(w: 400, h: 280),
            criadoEm: Date(), nome: "Legada", papel: "maestro", adapter: "shell", cwd: root.path)
        _ = try await human.call(.docApply, params: DocApplyParams(workspaceID: workspace.id, ops: [
            DocOp(opID: ULID.generate(), author: .humanoLocal, ts: Date(),
                  payload: .nodeAdd(NodeAddOpPayload(node: .terminal(legacyNode))))
        ]), expecting: DocApplyResult.self)
        human.close()
        firstEngine.stop()

        let secondEngine = Engine(paths: paths)
        try secondEngine.start()
        defer { secondEngine.stop() }
        let agent = SocketClient()
        try agent.connect(to: paths.engineSocket.path)
        defer { agent.close() }
        _ = try await agent.hello(client: "role-migration-agent", author: .agente(legacyNode.id.string))
        let nodes = try await agent.call(.nodeList, params: NodeListParams(workspaceID: workspace.id), expecting: NodeListResult.self)
        #expect(nodes.first(where: { $0.id == legacyNode.id })?.papel == "rainha")
    }

    @Test func agenteOperaNoSeuWorkspaceComChecklistIdempotenteESemVazarOutroWorkspace() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccap-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = ColmeiaPaths(root: root)
        let engine = Engine(paths: paths)
        try engine.start()
        defer { engine.stop(); try? FileManager.default.removeItem(at: root) }

        let human = SocketClient()
        try human.connect(to: paths.engineSocket.path)
        defer { human.close() }
        _ = try await human.hello(client: "agent-capabilities-human")
        let workspaceA = try await human.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "A", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self).workspace
        let workspaceB = try await human.call(
            .workspaceCreate, params: WorkspaceCreateParams(nome: "B", caminhoRaiz: root.path),
            expecting: WorkspaceResult.self).workspace
        let agentNode = TerminalNode(
            id: ULID.generate(), posicao: Ponto(x: 0, y: 0), tamanho: Tamanho(w: 400, h: 280),
            criadoEm: Date(), nome: "Agente A", papel: "rainha", adapter: "shell", cwd: root.path)
        let otherNode = TerminalNode(
            id: ULID.generate(), posicao: Ponto(x: 0, y: 0), tamanho: Tamanho(w: 400, h: 280),
            criadoEm: Date(), nome: "Agente B", adapter: "shell", cwd: root.path)
        for (workspaceID, node) in [(workspaceA.id, agentNode), (workspaceB.id, otherNode)] {
            _ = try await human.call(.docApply, params: DocApplyParams(workspaceID: workspaceID, ops: [
                DocOp(opID: ULID.generate(), author: .humanoLocal, ts: Date(),
                      payload: .nodeAdd(NodeAddOpPayload(node: .terminal(node))))
            ]), expecting: DocApplyResult.self)
        }
        let noteB = try await human.call(.noteCreate, params: NoteCreateParams(
            workspaceID: workspaceB.id, conteudo: "segredo do workspace B"), expecting: NoteRecord.self)

        let agent = SocketClient()
        try agent.connect(to: paths.engineSocket.path)
        defer { agent.close() }
        _ = try await agent.hello(client: "agent-capabilities", author: .agente(agentNode.id.string))

        let note = try await agent.call(.noteCreate, params: NoteCreateParams(
            workspaceID: workspaceA.id, conteudo: "- [ ] revisar contrato"), expecting: NoteRecord.self)
        #expect(note.checklist.count == 1)
        let itemID = try #require(note.checklist.first?.id)
        #expect(note.checklist.first?.marcada == false)

        let firstSet = try await agent.call(.noteChecklistSet, params: NoteChecklistSetParams(
            workspaceID: workspaceA.id, nodeID: note.nodeID, itemID: itemID, marcada: true),
            expecting: NoteChecklistSetResult.self)
        #expect(firstSet.changed)
        #expect(firstSet.note.conteudo.contains("[x] revisar contrato"))
        let repeatedSet = try await agent.call(.noteChecklistSet, params: NoteChecklistSetParams(
            workspaceID: workspaceA.id, nodeID: note.nodeID, itemID: itemID, marcada: true),
            expecting: NoteChecklistSetResult.self)
        #expect(!repeatedSet.changed)

        // A forma curta aceita Markdown que veio serializado por outro agente. O
        // arquivo mostra o nome humano do nó, enquanto o evento preserva o Author.
        let appended = try await agent.call(.noteAppend, params: NoteAppendParams(
            workspaceID: workspaceA.id, nodeIDOrigem: agentNode.id,
            texto: "## Entrega\\n\\n- [x] pronta\\nCaminho: C:\\tmp\\arquivo"), expecting: NoteAppendResult.self)
        let appendedRecord = try await agent.call(.noteGet, params: NoteGetParams(
            workspaceID: workspaceA.id, nodeID: appended.notaNodeID), expecting: NoteRecord.self)
        #expect(appendedRecord.conteudo.contains("_Agente A —"))
        #expect(!appendedRecord.conteudo.contains("_agente:"))
        #expect(appendedRecord.ultimaFonte == .agente(agentNode.id.string))
        #expect(appendedRecord.conteudo.contains("## Entrega\n\n- [x] pronta\nCaminho: C:\\tmp\\arquivo"))
        let connected = try await agent.call(
            .noteConnected,
            params: NoteConnectedParams(workspaceID: workspaceA.id, nodeID: agentNode.id),
            expecting: NoteConnectedResult.self)
        #expect(connected.first?.nodeID == appended.notaNodeID)
        #expect(connected.first?.conteudo.contains("## Entrega") == true)

        let chain = try await agent.call(
            .noteChain,
            params: NoteConnectedParams(workspaceID: workspaceA.id, nodeID: agentNode.id),
            expecting: NoteChainResult.self)
        #expect(chain.contains { $0.note.nodeID == appended.notaNodeID })

        let assetData = Data("asset smoke test".utf8).base64EncodedString()
        let addedAsset = try await agent.call(
            .noteAssetAdd,
            params: NoteAssetAddParams(
                workspaceID: workspaceA.id, nodeID: note.nodeID, mime: "image/png",
                dataB64: assetData, alt: "smoke", filename: "smoke.png"),
            expecting: NoteAssetAddResult.self)
        #expect(addedAsset.markdown.contains(addedAsset.asset.id.string))

        let listedAssets = try await agent.call(
            .noteAssetList,
            params: NoteAssetListParams(workspaceID: workspaceA.id, nodeID: note.nodeID),
            expecting: NoteAssetListResult.self)
        #expect(listedAssets.contains { $0.id == addedAsset.asset.id })

        let fetchedAsset = try await agent.call(
            .noteAssetGet,
            params: NoteAssetGetParams(
                workspaceID: workspaceA.id, nodeID: note.nodeID, assetID: addedAsset.asset.id),
            expecting: NoteAssetGetResult.self)
        #expect(fetchedAsset.dataB64 == assetData)

        _ = try await agent.call(
            .noteAssetRm,
            params: NoteAssetRmParams(
                workspaceID: workspaceA.id, nodeID: note.nodeID, assetID: addedAsset.asset.id),
            expecting: EmptyResult.self)
        let assetsAfterRemoval = try await agent.call(
            .noteAssetList,
            params: NoteAssetListParams(workspaceID: workspaceA.id, nodeID: note.nodeID),
            expecting: NoteAssetListResult.self)
        #expect(!assetsAfterRemoval.contains { $0.id == addedAsset.asset.id })

        let connectedByRainha = try await agent.call(
            .nodeConnect,
            params: NodeConnectParams(workspaceID: workspaceA.id, de: agentNode.id, para: note.nodeID),
            expecting: EmptyResult.self)
        _ = connectedByRainha
        _ = try await agent.call(
            .nodeDisconnect,
            params: NodeDisconnectParams(workspaceID: workspaceA.id, de: agentNode.id, para: note.nodeID),
            expecting: EmptyResult.self)

        let listed = try await agent.call(.nodeList, params: NodeListParams(
            workspaceID: workspaceA.id, tipo: .nota), expecting: NodeListResult.self)
        #expect(listed.contains { $0.id == note.nodeID && $0.tipo == .nota })
        #expect(!listed.contains { $0.titulo.contains("revisar contrato") })

        let portal = try await agent.call(.portalOpen, params: PortalOpenParams(
            workspaceID: workspaceA.id, url: "https://example.com", nome: "Exemplo"), expecting: PortalOpenResult.self)
        #expect(portal.nodeID != note.nodeID)
        // Chrome/CDP é um smoke test separado; a suíte padrão permanece
        // determinística e não depende de um navegador instalado na máquina.
        guard ProcessInfo.processInfo.environment["COLMEIA_BROWSER_TESTS"] == "1" else { return }
        let navigation = try await agent.call(
            .portalCommand,
            params: PortalCommandParams(
                workspaceID: workspaceA.id, nodeID: portal.nodeID, acao: .navigate,
                url: "https://example.com"),
            expecting: PortalCommandResult.self)
        #expect(navigation.resultado.contains("https://example.com"))
        let evaluated = try await agent.call(
            .portalCommand,
            params: PortalCommandParams(
                workspaceID: workspaceA.id, nodeID: portal.nodeID, acao: .eval, code: "1 + 1"),
            expecting: PortalCommandResult.self)
        #expect(evaluated.resultado.contains("2"))
        _ = try await agent.call(
            .portalCommand,
            params: PortalCommandParams(
                workspaceID: workspaceA.id, nodeID: portal.nodeID, acao: .eval,
                code: "document.body.innerHTML='<button id=\"go\">go</button><input id=\"field\">'; document.querySelector('#go').onclick=()=>window.colmeiaTestClicked=true; document.querySelector('#field').onkeydown=(e)=>window.colmeiaTestKey=e.key; 'ready'"),
            expecting: PortalCommandResult.self)
        _ = try await agent.call(
            .portalCommand,
            params: PortalCommandParams(
                workspaceID: workspaceA.id, nodeID: portal.nodeID, acao: .click, selector: "#go"),
            expecting: PortalCommandResult.self)
        let clicked = try await agent.call(
            .portalCommand,
            params: PortalCommandParams(
                workspaceID: workspaceA.id, nodeID: portal.nodeID, acao: .eval, code: "window.colmeiaTestClicked"),
            expecting: PortalCommandResult.self)
        // JSONSerialization representa CFBoolean como 1 ao atravessar o bridge Any.
        #expect(clicked.resultado == "1")
        _ = try await agent.call(
            .portalCommand,
            params: PortalCommandParams(
                workspaceID: workspaceA.id, nodeID: portal.nodeID, acao: .fill,
                selector: "#field", value: "colmeia"),
            expecting: PortalCommandResult.self)
        let filled = try await agent.call(
            .portalCommand,
            params: PortalCommandParams(
                workspaceID: workspaceA.id, nodeID: portal.nodeID, acao: .eval,
                code: "document.querySelector('#field').value"),
            expecting: PortalCommandResult.self)
        #expect(filled.resultado.contains("colmeia"))
        _ = try await agent.call(
            .portalCommand,
            params: PortalCommandParams(
                workspaceID: workspaceA.id, nodeID: portal.nodeID, acao: .eval,
                code: "document.querySelector('#field').focus(); 'focused'"),
            expecting: PortalCommandResult.self)
        _ = try await agent.call(
            .portalCommand,
            params: PortalCommandParams(
                workspaceID: workspaceA.id, nodeID: portal.nodeID, acao: .key, keys: "Enter"),
            expecting: PortalCommandResult.self)
        let keyed = try await agent.call(
            .portalCommand,
            params: PortalCommandParams(
                workspaceID: workspaceA.id, nodeID: portal.nodeID, acao: .eval, code: "window.colmeiaTestKey"),
            expecting: PortalCommandResult.self)
        #expect(keyed.resultado.contains("Enter"))
        let shot = try await agent.call(
            .portalCommand,
            params: PortalCommandParams(
                workspaceID: workspaceA.id, nodeID: portal.nodeID, acao: .shot, selector: "#field"),
            expecting: PortalCommandResult.self)
        #expect(shot.dataB64?.isEmpty == false)
        let snapshot = try await agent.call(
            .portalCommand,
            params: PortalCommandParams(workspaceID: workspaceA.id, nodeID: portal.nodeID, acao: .snapshot),
            expecting: PortalCommandResult.self)
        #expect(snapshot.dataB64?.isEmpty == false)
        do {
            _ = try await agent.call(.portalOpen, params: PortalOpenParams(
                workspaceID: workspaceA.id, url: "file:///etc/passwd"), expecting: PortalOpenResult.self)
            Issue.record("portal.open deveria aceitar somente http/https")
        } catch let error as ProtocolError {
            #expect(error.known == .invalid_params)
        }

        do {
            _ = try await agent.call(.noteGet, params: NoteGetParams(
                workspaceID: workspaceB.id, nodeID: noteB.nodeID), expecting: NoteRecord.self)
            Issue.record("agente não pode ler nota de outro workspace")
        } catch let error as ProtocolError { #expect(error.known == .invalid_params) }
        do {
            _ = try await agent.call(.nodeList, params: NodeListParams(
                workspaceID: workspaceB.id), expecting: NodeListResult.self)
            Issue.record("agente não pode listar outro workspace")
        } catch let error as ProtocolError { #expect(error.known == .invalid_params) }
        do {
            _ = try await agent.call(
                .noteConnected,
                params: NoteConnectedParams(workspaceID: workspaceB.id, nodeID: otherNode.id),
                expecting: NoteConnectedResult.self)
            Issue.record("agente não pode consultar conexões de outro workspace")
        } catch let error as ProtocolError { #expect(error.known == .invalid_params) }
        do {
            _ = try await agent.call(.portalOpen, params: PortalOpenParams(
                workspaceID: workspaceB.id, url: "https://example.com"), expecting: PortalOpenResult.self)
            Issue.record("agente não pode criar portal em outro workspace")
        } catch let error as ProtocolError { #expect(error.known == .invalid_params) }
    }
}
