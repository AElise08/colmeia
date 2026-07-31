import Foundation
import ColmeiaKit

enum WorkersCommand {
    static let usage = "uso: colmeia workers acquire --role <papel> --adapter <adapter> [--new]"
    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        do {
            guard args.first == "acquire" else { throw CLIFailure(code: CLIExit.uso, message: usage) }
            let identity = try context.requireAgentIdentity(subcomando: "workers")
            var role: String?; var adapter: String?; var newIdentity = false; var i = 1
            while i < args.count {
                switch args[i] {
                case "--role": i += 1; guard i < args.count else { throw CLIFailure(code: CLIExit.uso, message: usage) }; role = args[i]
                case "--adapter": i += 1; guard i < args.count else { throw CLIFailure(code: CLIExit.uso, message: usage) }; adapter = args[i]
                case "--new": newIdentity = true
                default: throw CLIFailure(code: CLIExit.uso, message: usage)
                }; i += 1
            }
            guard let role, let adapter else { throw CLIFailure(code: CLIExit.uso, message: usage) }
            let client = try await connectEngine(context); defer { client.close() }
            let result: WorkerAcquireResult = try await client.call(.workerAcquire, params: WorkerAcquireParams(workspaceID: identity.workspaceID, role: role, adapter: adapter, newIdentity: newIdentity), expecting: WorkerAcquireResult.self)
            print("\(result.reused ? "reused" : "created") \(result.node.id.string)\t\(result.node.nome)\t\(result.session.id.string)")
            return CLIExit.ok
        } catch let error as CLIFailure { printErr(error.message); return error.code }
        catch { printErr("colmeia workers: \(error)"); return CLIExit.contexto }
    }
}
