import Foundation
import ColmeiaKit

/// `colmeia ask "<nome-do-nó>" "<mensagem>" [--timeout 300] [--no-wait]` (§13.2/§14).
enum AskCommand {
    static let usage = #"uso: colmeia ask "<nome-do-nó>" "<mensagem>" [--timeout 300] [--no-wait]"#

    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        do {
            try await execute(args, context: context)
            return CLIExit.ok
        } catch let failure as CLIFailure {
            printErr(failure.message)
            return failure.code
        } catch {
            printErr("colmeia ask: \(error)")
            return CLIExit.contexto
        }
    }

    private static func execute(_ args: [String], context: CLIContext) async throws {
        var timeoutSeg = 300
        var noWait = false
        var positionals: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--no-wait":
                noWait = true
            case "--timeout":
                index += 1
                guard index < args.count, let valor = Int(args[index]), valor > 0 else {
                    throw CLIFailure(code: CLIExit.uso, message: "--timeout exige um inteiro de segundos > 0\n\(usage)")
                }
                timeoutSeg = valor
            case let flag where flag.hasPrefix("--timeout="):
                guard let valor = Int(flag.dropFirst("--timeout=".count)), valor > 0 else {
                    throw CLIFailure(code: CLIExit.uso, message: "--timeout exige um inteiro de segundos > 0\n\(usage)")
                }
                timeoutSeg = valor
            case "--":
                positionals.append(contentsOf: args[(index + 1)...])
                index = args.count
            case let flag where flag.hasPrefix("-") && flag.count > 1:
                throw CLIFailure(code: CLIExit.uso, message: "flag desconhecida: \(flag)\n\(usage)")
            default:
                positionals.append(arg)
            }
            index += 1
        }
        guard positionals.count == 2 else {
            throw CLIFailure(code: CLIExit.uso, message: usage)
        }
        let paraNome = positionals[0]
        let texto = positionals[1]

        let identity = try context.requireAgentIdentity(subcomando: "ask")
        let client = try await connectEngine(context)
        defer { client.close() }

        // Contrato com o engine: timeout_seg == 0 → --no-wait (responde após entrega,
        // §14.1 passo 4, com {message_id}); > 0 (ou ausente) → bloqueante por N segundos.
        let params = MessageSendParams(
            workspaceID: identity.workspaceID,
            deNode: identity.nodeID,
            paraNome: paraNome,
            texto: texto,
            timeoutSeg: noWait ? 0 : timeoutSeg
        )

        // Watchdog local com folga: o timeout de verdade é do engine; isto só cobre engine morto.
        let watchdog = noWait ? 30.0 : Double(timeoutSeg) + 15.0
        let result: JSONValue
        do {
            result = try await racedCall(
                client: client,
                watchdogSeconds: watchdog,
                expiry: CLIFailure(
                    code: CLIExit.timeout,
                    message: "timeout: sem resposta do engine após \(Int(watchdog))s"
                )
            ) {
                try await client.call(.messageSend, params: params)
            }
        } catch {
            throw mapError(error, paraNome: paraNome, timeoutSeg: timeoutSeg)
        }

        if noWait {
            guard let messageID = result["message_id"]?.stringValue else {
                throw CLIFailure(code: CLIExit.contexto, message: "resposta do engine sem message_id")
            }
            print(messageID)
            return
        }

        // Timeout do lado do engine chega como ok {message_id, timeout: true} (extensão §0).
        if result["timeout"]?.boolValue == true {
            throw CLIFailure(
                code: CLIExit.timeout,
                message: "timeout: \"\(paraNome)\" não respondeu em \(timeoutSeg)s (mensagem já entregue)"
            )
        }

        // §14.1 passo 5 — o engine "devolve ao chamador" o trecho de output do destinatário.
        // O resultado tipado de message.send é {message_id} (§6.4); o texto da resposta viaja
        // no campo de extensão `resposta` (campos extras são permitidos, §0).
        if let resposta = result["resposta"]?.stringValue {
            print(resposta)
        } else if let messageID = result["message_id"]?.stringValue {
            printErr("aviso: engine não devolveu o campo `resposta`; mensagem entregue")
            print(messageID)
        } else {
            throw CLIFailure(code: CLIExit.contexto, message: "resposta do engine sem message_id")
        }
    }

    private static func mapError(_ error: Error, paraNome: String, timeoutSeg: Int) -> CLIFailure {
        if let failure = error as? CLIFailure { return failure }
        if let proto = error as? ProtocolError {
            if proto.known == .node_not_found {
                return CLIFailure(
                    code: CLIExit.destinoInexistente,
                    message: "destino \"\(paraNome)\" não existe ou está sem sessão viva: \(proto.message)"
                )
            }
            // §6.6 permite extensões; timeout de resposta não tem nome no inventário fixo.
            if proto.name.contains("timeout") {
                return CLIFailure(
                    code: CLIExit.timeout,
                    message: "timeout: \"\(paraNome)\" não respondeu em \(timeoutSeg)s (mensagem já entregue)"
                )
            }
            return CLIFailure(code: CLIExit.contexto, message: "colmeia ask: \(proto)")
        }
        return CLIFailure(code: CLIExit.contexto, message: "colmeia ask: \(error)")
    }
}
