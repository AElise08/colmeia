import Foundation
import ColmeiaKit

// CLI companheira (§13): injetada no PATH das sessões gerenciadas, mas legítima
// também fora delas (humano:local). Exit codes em CLIExit (§13.2).

let cliUsage = """
colmeia \(ColmeiaVersion.string) — CLI companheira do Colmeia, o canvas local de agentes \
(protocolo v\(ColmeiaVersion.protocolVersion))

Cada terminal gerenciado pelo Colmeia é um nó do canvas. Esta CLI é o canal do
agente (ou do humano) com o canvas: anotar em notas, conversar com outros
agentes, ver quem está na sala e abrir sites em portais embutidos.

subcomandos:
  colmeia note "<texto>"           escreve NA NOTA CONECTADA ao seu nó — use para
                                   anotar/registrar qualquer coisa (sem nota
                                   conectada, uma é criada ao lado do seu nó);
                                   nunca use apps externos (Notas etc.)
  colmeia note -                   idem, lendo o texto do stdin
   colmeia note create|get|set|check cria, consulta e atualiza notas de modo explícito
   colmeia note connected [--json]  lê as notas conectadas ao seu nó, mais recente primeiro
    colmeia note chain <id>          percorre cadeia de notas (BFS) com profundidade
    colmeia note asset add|list|rm   gerencia imagens/arquivos anexos de notas
   colmeia nodes [--json]           lista metadados dos nós do seu workspace
   colmeia nodes create terminal    cria um novo terminal no canvas e inicia a sessão
       [--name <nome>] [--adapter <adapter>] [--role <papel>] [--no-start]
    colmeia nodes dismiss <node-id>  remove nó terminal (apenas Rainha)
    colmeia connect <a> <b>          conecta dois nós (apenas Rainha)
    colmeia disconnect <a> <b>       desconecta dois nós (apenas Rainha)
   colmeia ask "<nó>" "<mensagem>"  conversa com outro agente do canvas pelo nome
                                    do nó; espera a resposta dele
       [--timeout <seg>|--no-wait]  --no-wait dispara sem esperar
   colmeia status [--json]          lista os nós do workspace: nome, papel,
                                    adapter, estado, conexões e qual nó é você
   colmeia list [--json]            lista todos os nós com tipo, nome, adapter,
                                    papel e estado da sessão
   colmeia check "<nó>"             lê o output recente do nó (últimos 50 eventos)
       [--limit N] [--stream]       --stream: acompanha output ao vivo
  colmeia portal open <url>        abre um navegador embutido no canvas
       [--nome <apelido>] [--workspace <workspace-id>] [--floor <floor-id>]
  colmeia portal command <id> ...  automatiza portal: navigate, shot, snapshot,
                                  click, fill, key e eval
  colmeia memory show|propose|history memória curada; agentes só propõem
  colmeia done --status ... --summary ... declara entrega com evidências
  colmeia workers acquire --role <papel> --adapter <adapter> [--new]
  colmeia delegate --role <papel> --adapter <adapter> [--new] <tarefa>
  colmeia deliveries [--pending|--accepted] lista entregas do workspace
  colmeia mission ...              Missão / Frente / Decisão / briefing (§5)
  colmeia version | --version
  colmeia help    | --help

Dentro de uma sessão gerenciada, as envs COLMEIA_NODE_ID/COLMEIA_NODE_NOME/
COLMEIA_WORKSPACE_ID já identificam seu nó — nenhuma configuração é necessária.
"""

let cliArguments = Array(CommandLine.arguments.dropFirst())
let exitCode: Int32

switch cliArguments.first {
case nil:
    printErr(cliUsage)
    exitCode = CLIExit.uso
case "help", "--help", "-h":
    print(cliUsage)
    exitCode = CLIExit.ok
case "version", "--version":
    print("colmeia \(ColmeiaVersion.string) (protocolo v\(ColmeiaVersion.protocolVersion))")
    exitCode = CLIExit.ok
case "ask":
    exitCode = await AskCommand.run(Array(cliArguments.dropFirst()))
case "recruit":
    exitCode = await NodesCommand.run(["create", "terminal"] + Array(cliArguments.dropFirst()))
case "list":
    exitCode = await ListCommand.run(Array(cliArguments.dropFirst()))
case "check":
    exitCode = await CheckCommand.run(Array(cliArguments.dropFirst()))
case "connect", "disconnect":
    exitCode = await ConnectCommand.run(Array(cliArguments.dropFirst()))
case "note":
    exitCode = await NoteCommand.run(Array(cliArguments.dropFirst()))
case "status":
    exitCode = await StatusCommand.run(Array(cliArguments.dropFirst()))
case "nodes":
    exitCode = await NodesCommand.run(Array(cliArguments.dropFirst()))
case "portal":
    exitCode = await PortalCommand.run(Array(cliArguments.dropFirst()))
case "memory":
    exitCode = await MemoryCommand.run(Array(cliArguments.dropFirst()))
case "done":
    exitCode = await DoneCommand.run(Array(cliArguments.dropFirst()))
case "workers":
    exitCode = await WorkersCommand.run(Array(cliArguments.dropFirst()))
case "delegate":
    exitCode = await DelegateCommand.run(Array(cliArguments.dropFirst()))
case "deliveries":
    exitCode = await DeliveriesCommand.run(Array(cliArguments.dropFirst()))
case "room":
    exitCode = await RoomCommand.run(Array(cliArguments.dropFirst()))
case "mission":
    exitCode = await MissionCommand.run(Array(cliArguments.dropFirst()))
case "handoff":
    // §13.5 — nome reservado [FASE 2]; NÃO DEVE ser usado para outra coisa.
    printErr("colmeia handoff: nome reservado (§13.5), ainda não disponível nesta versão")
    exitCode = CLIExit.uso
case .some(let outro):
    printErr("subcomando desconhecido: \(outro)\n\n\(cliUsage)")
    exitCode = CLIExit.uso
}

exit(exitCode)
