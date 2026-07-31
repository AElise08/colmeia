import Foundation
import ColmeiaKit

enum DelegateCommand {
    static let usage = "uso: colmeia delegate --role <papel> --adapter <adapter> [--new] <tarefa>"
    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        do {
            let identity = try context.requireAgentIdentity(subcomando: "delegate")
            var role: String?; var adapter: String?; var newIdentity = false; var taskParts: [String] = []; var i = 0
            while i < args.count {
                switch args[i] {
                case "--role": i += 1; guard i < args.count else { throw CLIFailure(code: CLIExit.uso, message: usage) }; role = args[i]
                case "--adapter": i += 1; guard i < args.count else { throw CLIFailure(code: CLIExit.uso, message: usage) }; adapter = args[i]
                case "--new": newIdentity = true
                default: taskParts.append(args[i])
                }; i += 1
            }
            guard let role, let adapter, !taskParts.isEmpty else { throw CLIFailure(code: CLIExit.uso, message: usage) }
            let client = try await connectEngine(context)
            let created: DelegationResult
            do {
                created = try await client.call(
                    .delegationCreate,
                    params: DelegationCreateParams(
                        workspaceID: identity.workspaceID,
                        principalNodeID: identity.nodeID,
                        role: role,
                        adapter: adapter,
                        task: taskParts.joined(separator: " "),
                        newIdentity: newIdentity),
                    expecting: DelegationResult.self)
            } catch {
                client.close()
                throw error
            }
            client.close()
            let result = try await waitForDelegation(
                created.delegation.id, context: context)
            print(result.delegation.result ?? result.delegation.estado.rawValue)
            return result.delegation.estado == .completed ? CLIExit.ok : CLIExit.contexto
        } catch let error as CLIFailure { printErr(error.message); return error.code }
        catch { printErr("colmeia delegate: \(error)"); return CLIExit.contexto }
    }

    /// A espera é reconectável: se o engine reiniciar, a delegação já persistida
    /// continua sendo a mesma e a CLI apenas volta a aguardá-la.
    private static func waitForDelegation(
        _ delegationID: ULID,
        context: CLIContext
    ) async throws -> DelegationResult {
        var lastError: Error?
        while !Task.isCancelled {
            do {
                let client = try await connectEngine(context)
                defer { client.close() }
                return try await client.call(
                    .delegationWait,
                    params: DelegationWaitParams(delegationID: delegationID),
                    expecting: DelegationResult.self)
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError ?? CancellationError()
    }
}
