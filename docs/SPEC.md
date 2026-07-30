# Colmeia — Especificação do Sistema

**Status:** Normativa v1 — implementação em curso (Marco A entregue)
**Data:** 26/07/2026
**Propósito:** Definir o Colmeia como um canvas nativo para equipes humanas e agentes: um espaço visual onde missões, execução, decisões, dependências e entregas permanecem visíveis, auditáveis e organizáveis.

## Linguagem normativa

As palavras **DEVE**, **NÃO DEVE**, **OBRIGATÓRIO**, **DEVERIA**, **NÃO DEVERIA**, **RECOMENDADO**, **PODE** e **OPCIONAL** devem ser interpretadas conforme a RFC 2119.

“Definido pela implementação” significa que o comportamento é parte do contrato, mas esta especificação não impõe uma única política. A implementação DEVE documentar a política escolhida.

## 1. Declaração do problema

Agentes são bons em executar trabalho, mas uma equipe perde velocidade quando precisa reconstruir o contexto entre múltiplas janelas, logs, decisões e pessoas. O problema não é apenas encontrar um terminal. É responder rapidamente:

- Qual resultado estamos tentando alcançar?
- Qual parte do trabalho está sendo feita, por quem e para qual definição de pronto?
- Qual agente está trabalhando, bloqueado, aguardando uma pessoa ou aguardando aprovação?
- Que decisão impede o avanço?
- Que evidência demonstra uma entrega?
- Como outra pessoa entra no trabalho sem perder contexto nem tomar controle indevido?

Um canvas de terminais organiza a execução individual. Colmeia deve organizar a colaboração: a missão, os responsáveis, os acordos e o histórico de uma equipe humana mais agentes.

### 1.1 Fronteira de produto

Colmeia é:

- um canvas espacial para organizar trabalho vivo;
- uma sala de coordenação para pessoas e agentes;
- uma camada local-first que preserva estado, sessões e evidência;
- uma base para colaboração remota segura, quando explicitamente ativada.

Colmeia não é:

- um clone de terminal;
- um gerenciador genérico de backlog ou issue tracker;
- um mecanismo para expor PTY, arquivos, credenciais ou browser autenticado;
- um Worker remoto que interpreta chat como comando;
- uma substituição de Git, pull requests, editor ou ferramenta de tickets.

## 2. Objetivos e não-objetivos

### 2.1 Objetivos

- Manter o canvas infinito como o espaço principal de pensamento e organização.
- Tornar Missão, Frente de Trabalho, Agente, Decisão e Entrega objetos visíveis e conectáveis.
- Permitir notas, desenho, agrupamento, pan, zoom, minimapa e navegação espacial fluida.
- Mostrar atenção humana necessária sem exigir leitura de output de terminal.
- Construir briefings de agente a partir do trabalho real, em vez de apenas nome e papel.
- Registrar autoria, decisões, handoffs, evidências e aceites de maneira durável.
- Operar integralmente local sem Hub.
- Preparar o mesmo modelo para salas colaborativas, sem reescrever o engine.
- Manter terminal como detalhe local de execução, aberto sob demanda.

### 2.2 Não-objetivos da primeira versão

- Compartilhar terminal, shell, cookies, paths ou saída bruta entre máquinas.
- Fornecer execução remota pública.
- Resolver colaboração por Operational Transformation ou CRDT complexo.
- Transformar cada conversa em chat global sem vínculo com trabalho.
- Fazer gestão de roadmap, orçamento, RH, CRM ou backlog corporativo.
- Supor que conclusão textual de agente é evidência suficiente de entrega.
- Publicar Hub sem identidade, convite, autorização e recuperação testada.

## 3. Princípios de produto

### 3.1 O canvas é o centro

Canvas não é um fundo para cartões. Ele é a ferramenta de pensamento da equipe. A pessoa DEVE poder posicionar, conectar, agrupar, desenhar e criar contexto visual livremente.

A liberdade espacial NÃO DEVE substituir semântica estruturada. Proximidade visual não determina responsabilidade, dependência, decisão ou revisão.

### 3.2 A missão vem antes do terminal

O primeiro convite do produto deve ser criar uma Missão, não abrir um terminal. Um terminal pode existir antes de uma Missão para exploração pessoal, mas trabalho coordenado DEVE ser associado a uma Missão ou explicitamente marcado como não classificado.

### 3.3 Atenção humana é finita

Itens aguardando pessoa devem ser raros, explícitos e fáceis de resolver. A interface Agora não é um feed de tudo; é uma fila priorizada de bloqueios, aprovações, decisões e entregas.

### 3.4 Sessão não é identidade

Um Agente pode reiniciar, trocar de engine ou não estar executando. Seu papel na equipe e seu trabalho atual não podem desaparecer com uma janela de terminal.

### 3.5 Handoff não é acesso

Trocar responsabilidade por um agente ou frente transfere contexto e autoridade definida pela política. Não concede shell, credencial ou capacidade de digitar no terminal de outra pessoa.

### 3.6 Progresso precisa de evidência

Saída de terminal, resumo de agente e declaração de sucesso são sinais de progresso. Eles não são, sozinhos, aceitação de entrega.

## 4. Visão geral do sistema

### 4.1 Componentes

1. **Aplicativo Canvas**
   - Aplicativo macOS em SwiftUI.
   - Renderiza Canvas, Agora, Linha do tempo, detalhes e terminais locais.
   - É cliente comum do engine e, quando habilitado, do Hub.

2. **Engine local**
   - Processo headless dono de PTYs, sessões, journals, workspaces, andares, aprovações, rotinas e operações locais do documento.
   - Expõe protocolo local e persiste estado durável.
   - Continua rodando quando a UI fecha, conforme política definida pela implementação.

3. **Modelo de Missão**
   - Conjunto de entidades e operações versionadas que descrevem o trabalho humano mais agentes.
   - É a fonte de verdade de Missões, Frentes, Decisões, Entregas e Relações.

4. **Adapters de agente**
   - Conhecem como iniciar e observar Claude Code, Codex, Gemini CLI, OpenCode, shell ou outro executor.
   - O engine NÃO DEVE conter heurísticas específicas de agentes fora desses adapters.

5. **CLI Colmeia**
   - Canal pelo qual um agente local consulta seu contexto, publica atualização, pede decisão, propõe entrega e cria artefato permitido.
   - É autenticada pelo contexto da sessão gerenciada.

6. **Hub de Sala**
   - Opcional na fase local.
   - Autentica, autoriza, ordena e replica estado compartilhável.
   - Não executa comandos, não recebe PTY bruto e não é dono de arquivos locais.

7. **Worker remoto**
   - Fora do piloto.
   - Só pode existir após política de grants, allowlist, isolamento e auditoria.

### 4.2 Camadas

| Camada | Responsabilidade | Dono |
| --- | --- | --- |
| Persistência local | snapshots, operações, journals, notas, índices | Engine |
| Execução | PTY, adapter, worktree, sessão, replay | Engine |
| Coordenação | missão, frentes, decisões, entregas, aprovações | Modelo de Missão |
| Protocolo | requests, eventos, identidade, erros | Kit compartilhado |
| Colaboração | autorização, sala, log remoto, snapshot e delta | Hub |
| Apresentação | Canvas, Agora, Linha do tempo, detalhes | Aplicativo |

### 4.3 Fluxo principal

1. Uma pessoa cria ou abre uma Sala local.
2. Ela cria uma Missão e define seu resultado.
3. No Canvas, cria Frentes, agentes, notas e conexões.
4. Atribui uma Frente a pessoa, agente ou ambos.
5. Inicia o Agente com briefing derivado do contexto.
6. O agente trabalha e publica atualização ou proposta.
7. Bloqueios e aprovações aparecem em Agora.
8. O agente propõe Entrega com evidência.
9. A pessoa aceita, reabre ou redireciona.
10. A Linha do tempo preserva a história.

## 5. Modelo de domínio

### 5.1 Sala

Sala é o contexto colaborativo com membros, política e Canvas.

Campos:

- id: identificador estável.
- name: nome humano.
- owner_id: membro administrador.
- policy: regras de revisão, convite e dados permitidos.
- state: active ou archived.
- created_at e updated_at.

Regras:

- Sala PODE conter muitas Missões.
- Uma instalação local PODE criar Sala pessoal automaticamente.
- Sala archived é somente leitura, salvo reabertura explícita por owner.
- Sala NÃO DEVE ser listada para identidade não autorizada.

### 5.2 Missão

Missão representa um resultado de trabalho, não uma tarefa genérica.

Campos:

- id e room_id.
- title: resultado desejado expresso em linguagem humana.
- context: referências, restrições e material compartilhável.
- definition_of_done: condições verificáveis.
- owner_id: responsável humano pela direção.
- state: draft, active, blocked, in_review, completed ou archived.
- created_at, updated_at e completed_at opcional.

Regras:

- Missão DEVE aparecer como frame ou grupo visual no Canvas.
- Nós podem ficar visualmente fora do frame para apoiar raciocínio, mas sua associação lógica deve permanecer explícita.
- Missão active DEVE ter ao menos uma Frente.
- Missão completed DEVE ter todas as Entregas obrigatórias aceitas.

### 5.3 Frente de Trabalho

Frente é uma parte coerente da Missão, com objetivo e definição de pronto.

Campos:

- id e mission_id.
- title e objective.
- definition_of_done.
- assignee: referência a pessoa, agente ou ambos.
- state: not_started, active, blocked, waiting_for_review, completed ou canceled.
- depends_on: referências a Frentes.
- blocked_by: referências a Frentes ou Decisões.
- created_at, updated_at e completed_at opcional.

Regras:

- Cada Frente DEVE ser um nó próprio no Canvas.
- Arrastar a Frente altera posição, não escopo ou responsabilidade.
- Mudar assignee, state ou objetivo é operação auditável.
- Frente completed DEVE ter ao menos uma Entrega aceita ou uma exceção registrada pela política.

### 5.4 Agente

Agente é participante não humano com papel e capacidades. Sessão é apenas uma possível execução atual.

Campos:

- id, room_id opcional e local_node_id opcional.
- name e role.
- capabilities: conjunto de capacidades declaradas.
- status: idle, working, waiting_for_human, approval_pending, blocked, stopped ou unavailable.
- current_workstream_id opcional.
- last_summary opcional.
- last_update_at opcional.
- session_reference opcional e privada por padrão.

Regras:

- O Canvas DEVE mostrar agente como membro da equipe, não como terminal reduzido.
- Status exibido DEVE ter origem em sessão, evento ou atualização explícita.
- A TUI abre apenas em máquina autorizada por ação deliberada.
- Agente não pode aceitar uma Entrega que a política exige aceite humano.

### 5.5 Pessoa

Pessoa é membro humano da Sala.

Campos:

- id, display_name e avatar opcional.
- roles: owner, editor ou viewer.
- presence: online, away ou offline, com expiração efêmera.
- created_at e updated_at.

Regras:

- owner administra membros e política.
- editor altera objetos autorizados e faz propostas.
- viewer somente lê.
- conductor e executor são responsabilidades de sessão; não substituem papel de autorização da Sala.

### 5.6 Decisão

Decisão é uma pergunta com responsável e resultado registrado.

Campos:

- id, mission_id e workstream_id opcional.
- question.
- options: alternativas e consequências opcionais.
- requested_by.
- decider_id.
- state: open, decided, superseded ou canceled.
- decision e rationale opcionais.
- due_at e decided_at opcionais.

Regras:

- Aprovação técnica detectada pelo engine DEVE poder criar ou atualizar Decisão.
- Uma Frente bloqueada por Decisão open deve refletir o bloqueio no Canvas e em Agora.
- decision e rationale não podem mudar após estado decided sem evento de supersede ou reabertura.

### 5.7 Entrega

Entrega é resultado verificável de Missão ou Frente.

Campos:

- id, mission_id e workstream_id opcional.
- summary.
- evidence: links, diff, teste, artefato ou outra prova permitida.
- submitted_by e reviewed_by opcional.
- state: draft, proposed, accepted, partial, blocked, failed ou reopened.
- created_at, updated_at e accepted_at opcional.

Regras:

- Entrega accepted exige evidência válida.
- Se a Sala exigir revisão humana, accepted exige reviewed_by humano.
- Declaração de sucesso de agente não é aceite.
- Reabertura deve preservar evidência e motivo anterior.

### 5.8 Relação de Canvas

Relação conecta objetos com significado explícito.

Campos:

- id, from_id, to_id.
- kind: depends_on, assigned_to, produces, requires_decision, reviews ou informs.
- author e created_at.
- label_position opcional.

Regras:

- Canvas DEVE revelar kind em seleção, hover ou zoom adequado.
- depends_on não pode criar ciclo não declarado sem alerta visível.
- assigned_to deve ligar Frente a Pessoa ou Agente.
- produces deve ligar Frente a Entrega.

### 5.9 Nota, desenho e portal

Nota e desenho são objetos de contexto livre. Portal é visão de recurso web local.

Regras:

- Nota e desenho NÃO substituem estado estruturado de Missão, Frente, Decisão ou Entrega.
- Portal não é automaticamente compartilhável.
- Conteúdo de portal autenticado NÃO DEVE ser replicado.
- O Canvas pode conter objetos não classificados; o produto DEVERIA convidar a vinculá-los a Missão quando pertinente.

## 6. Experiência de Canvas

### 6.1 Requisitos de interação

Canvas DEVE suportar:

- pan e zoom ancorado;
- minimapa;
- seleção e foco;
- criação, arrasto e redimensionamento de nós;
- criação de frames e grupos;
- desenho livre;
- notas;
- conexões tipadas;
- filtros por Missão, estado, responsável e relação;
- navegação do item em Agora ao nó correspondente;
- retorno ao panorama após foco.

### 6.2 Camadas de detalhe

Em zoom distante, nó mostra tipo, título, estado e responsável.

Em zoom intermediário, nó mostra dependências, última atualização, prioridade de atenção e relações essenciais.

Em foco, nó mostra descrição, thread contextual, evidências, histórico e controles autorizados.

Terminal aparece apenas no último nível de detalhe de um Agente e somente localmente.

### 6.3 Visões derivadas

Canvas DEVE oferecer:

- visão da Missão: Frentes, Decisões, Entregas e dependências;
- visão da equipe: Pessoas e Agentes agrupados por papel;
- visão de atenção: objetos bloqueados ou aguardando pessoa;
- visão de execução: agentes e sessões locais, como detalhe operacional;
- visão livre: organização espacial definida pela pessoa.

### 6.4 Acessibilidade

A semântica de cada nó e conexão DEVE estar disponível sem depender exclusivamente de cor ou posição. A pessoa deve poder navegar itens relevantes via teclado, encontrar atenção pendente e abrir detalhes sem gesto preciso.

## 7. Agora e Linha do tempo

### 7.1 Agora

Agora deve responder sem abrir terminal:

- quem está aguardando ação;
- o que está bloqueado e por quê;
- quais Decisões estão abertas;
- quais Entregas aguardam revisão;
- que agente não atualiza há tempo acima da política;
- que mudanças ocorreram desde a última visita;
- se a Sala está online, sincronizando, offline com fila ou em erro.

Agora NÃO DEVE ser uma lista de todos os logs. Deve priorizar ação humana e permitir ir ao nó ou detalhe correspondente.

### 7.2 Linha do tempo

Eventos relevantes:

- Missão, Frente, Decisão, Entrega e Relação criada, alterada ou removida;
- atribuição e desatribuição;
- início, pausa, término ou falha de sessão;
- atualização de resumo de agente;
- aprovação;
- proposta, aceite, rejeição ou expiração de handoff;
- convite, entrada, remoção ou alteração de membro;
- sincronização, erro ou recuperação de Sala.

Cada evento DEVE conter autor, tempo, alvo e resultado. Payloads privados podem ser resumidos ou omitidos da superfície compartilhada.

## 8. Execução local e briefing

### 8.1 Engine local

Engine deve ser processo separado da UI e dono do estado autoritativo de PTY, journal e arquivos de sessão. Todas as mutações devem passar por protocolo local; a UI não deve tocar PTY ou journal diretamente.

### 8.2 Adapters

Cada adapter define:

- comando de lançamento;
- ambiente seguro;
- classificação de atividade;
- detecção de aprovação, quando confiável;
- injeção de resposta, quando documentada;
- degradação quando observação não é suportada.

Engine não deve espalhar conhecimento de agente por vários módulos.

### 8.3 Briefing de Frente

Antes de iniciar Agente para uma Frente, o engine DEVE compor briefing com:

- título, contexto e definição de pronto da Missão;
- objetivo, escopo e critério de pronto da Frente;
- relações depends_on e Decisões abertas relevantes;
- papel e capacidades do Agente;
- artefatos explicitamente permitidos;
- instruções para publicar progresso, pedir decisão, propor Entrega e escalar bloqueio.

Briefing NÃO DEVE incluir segredo, cookie, path de outra máquina, saída bruta irrelevante ou contexto privado não publicado.

Falha de renderização ou campo obrigatório ausente deve impedir início visivelmente. Agente não deve iniciar em silêncio com briefing incompleto.

### 8.4 Atualização de agente

Agente pode publicar:

- resumo de progresso;
- mudança de status;
- pedido de decisão;
- risco ou bloqueio;
- proposta de Entrega;
- referência de evidência permitida.

Atualização de agente deve ter autoria do agente, sessão de origem quando houver e vínculo com Frente ou Missão. Não pode concluir Frente automaticamente.

## 9. Máquinas de estado

### 9.1 Missão

Fluxo principal:

draft → active → in_review → completed

Transições:

- draft → active exige owner, objetivo, definição de pronto e ao menos uma Frente.
- active → blocked ocorre quando Decisão ou dependência impede o resultado geral.
- blocked → active ocorre ao resolver todos os bloqueios impeditivos.
- active → in_review exige Entregas propostas para Frentes obrigatórias.
- in_review → completed exige Entregas obrigatórias aceitas.
- completed → active exige reabertura explícita e motivo.
- estado não arquivado pode ir a archived por owner autorizado.

### 9.2 Frente

Fluxo principal:

not_started → active → waiting_for_review → completed

Transições adicionais:

- active → blocked por dependência ou Decisão impeditiva;
- blocked → active ao resolver bloqueio;
- waiting_for_review → active ao reabrir Entrega;
- qualquer estado não concluído pode ir a canceled;
- completed não volta sem reabertura auditada.

### 9.3 Decisão

open → decided

open ou decided pode ir a superseded ou canceled. Decisão decided não deve ser silenciosamente editada.

### 9.4 Entrega

draft → proposed → accepted

proposed pode ir a partial, blocked ou failed. accepted pode ir a reopened apenas por ação auditada.

### 9.5 Sessão de agente

Sessão local usa estados de execução definidos pelo engine. Estados que exigem humano, incluindo waiting_for_human e approval_pending, DEVEM alimentar Agora. Sessão encerrada não deve apagar Agente, Frente, Entrega ou Linha do tempo.

## 10. Colaboração remota

### 10.1 Dados compartilháveis

Podem ser replicados:

- Sala, membros e política pública;
- Missões, Frentes, Decisões, Entregas e Relações;
- posições e agrupamentos do Canvas;
- comentários ancorados em objeto;
- presença efêmera;
- resumos e artefatos sanitizados de Agente.

Não podem ser replicados no piloto:

- terminal, shell, comando livre e output PTY;
- credenciais, cookie, .env, token ou segredo;
- conteúdo de worktree;
- path absoluto;
- browser autenticado;
- raciocínio privado não publicado.

### 10.2 Identidade e convite

Hub DEVE autenticar instalação por prova de posse de chave. O cliente não escolhe livremente seu autor efetivo.

Entrada em Sala exige convite válido ou associação prévia. Convite deve ser aleatório, de uso único, revogável, com expiração e papel mínimo.

### 10.3 Autorização

Cada leitura, mutação, presença e broadcast deve validar room_id e papel. Hub não pode substituir Sala solicitada por outra Sala existente. Evento de Sala nunca deve alcançar assinante de outra Sala.

### 10.4 Handoff

Participante não executor pode propor direção. Executor ou condutor aceita, rejeita ou pede esclarecimento.

Handoff deve registrar origem, destino, escopo, briefing de entrada e resultado. A responsabilidade anterior só é revogada quando a nova responsabilidade é confirmada. Handoff não concede acesso a shell.

### 10.5 Papel do Hub

Hub:

- autentica;
- autoriza;
- ordena eventos;
- persiste log e snapshots;
- distribui delta;
- mantém presença efêmera;
- expõe estado operacional mínimo.

Hub não:

- executa comandos;
- recebe PTY;
- armazena segredos do executor;
- interpreta mensagem ou evento como shell.

## 11. Protocolo, sincronização e recuperação

### 11.1 Operações do documento

Estado estruturado deve ser persistido como operações versionadas com IDs estáveis. Operações devem carregar autor, timestamp lógico, alvo e versão de protocolo.

Objetos de produto não devem depender de um blob de UI para sobreviver a reinício.

### 11.2 Operação remota

Toda mutação remota deve ter:

- room_id;
- operation_id gerado pelo cliente;
- author derivado da identidade autenticada;
- protocol_version;
- payload tipado;
- sent_at.

Hub atribui room_seq monotônico por Sala.

### 11.3 Idempotência

Repetir operation_id com mesmo payload deve devolver o ack original. Repetir ID com payload diferente deve falhar como conflito de idempotência.

### 11.4 Snapshot e delta

Cliente entra na Sala por:

1. autenticação;
2. autorização e entrada;
3. snapshot;
4. aplicação de deltas em room_seq;
5. reenvio de fila local sem ack.

Cliente deve manter fila local durável antes de envio. Interface deve mostrar alterações aguardando sincronização.

### 11.5 Conflitos

Campos escalares usam LWW por relógio lógico e autor. Exclusão vence versão anterior do mesmo objeto. Relações e eventos append-only não devem ser tratados como sobrescrita cega.

### 11.6 Recuperação

Reinício do Hub deve recuperar snapshots e eventos confirmados. Rede intermitente não pode duplicar operação nem remover mutação confirmada. Engine local continua útil sem Hub.

## 12. Segurança, privacidade e confiança

### 12.1 Limites

Engine local é ambiente de confiança da pessoa operadora. Hub é ambiente de coordenação, não ambiente de execução. Worker remoto, quando existir, deve ser ambiente isolado de menor privilégio.

### 12.2 Requisitos para Hub público

Antes de uso externo, Hub deve:

- usar WSS;
- rodar como usuário dedicado;
- ouvir somente em loopback atrás de proxy TLS;
- não expor porta interna;
- ter limites de tamanho e taxa;
- registrar logs estruturados sem conteúdo sensível;
- ter backup criptografado;
- ter restauração testada;
- ter health check e alerta de disco baixo.

### 12.3 Worker remoto futuro

Worker só pode receber job tipado, autenticado e autorizado. Deve usar allowlist, grant com escopo e expiração, isolamento por job, usuário sem privilégios e secret manager. Mensagem de Sala nunca é comando.

## 13. Persistência local

Persistência local deve conter:

- índice de Salas e Missões;
- snapshots de documento;
- log de operações;
- journals de sessão;
- notas e evidências permitidas;
- metadados de sessão;
- arquivos de configuração;
- fila de sincronização, quando habilitada.

Persistência deve permitir reconstruir Canvas, Agora e Linha do tempo. Escrita deve ser atômica ou protegida contra corrupção parcial. Rotação e compactação não podem quebrar auditoria exigida pela política.

## 14. Observabilidade

Logs estruturados devem incluir contexto suficiente para diagnóstico:

- room_id;
- mission_id opcional;
- object_id opcional;
- session_id opcional;
- author;
- ação;
- resultado;
- motivo conciso de falha.

Métricas recomendadas:

- número de Missões ativas, bloqueadas e em revisão;
- agentes por status;
- tempo entre pedido e decisão;
- tempo entre Entrega proposta e aceite;
- fila offline;
- lag de réplica;
- falha de autenticação e autorização;
- disco, reinícios e falhas de snapshot;
- idade da última atualização de agente.

Logs e métricas não devem conter segredo, PTY bruto ou arquivo privado.

## 15. Requisitos não funcionais

### 15.1 Desempenho

Canvas deve permanecer navegável com dezenas de objetos. Zoom distante deve usar representação semântica barata. Engine e UI não devem competir desnecessariamente por recursos dos agentes.

Metas iniciais devem ser medidas em máquina de referência:

- abertura de Canvas em menos de dois segundos quando engine está pronto;
- cold boot do engine em menos de dois segundos;
- transição de andar e operações de documento com latência visível baixa;
- interação de pan e zoom sem travamento perceptível;
- reconexão de Sala sem perda de operação confirmada.

### 15.2 Acessibilidade

Produto deve fornecer navegação por teclado, texto selecionável, contraste suficiente, rótulos de estado e alternativa semântica para posição/cor.

### 15.3 Privacidade

Uso local não deve depender de conta ou telemetria. Colaboração remota deve declarar quais dados deixam a máquina antes de enviar qualquer conteúdo.

## 16. Plano de implementação

### 16.1 Marco A — modelo de missão local

- Introduzir Missão, Frente, Decisão, Entrega e Relação tipada no domínio e documento.
- Trocar estado vazio de Novo Terminal por Criar uma Missão.
- Criar molde Pesquisa → Construção → Revisão.
- Criar Canvas com frames de Missão e nós semânticos.

**Aceite:** captura sem terminal comunica resultado, responsáveis, bloqueio e próxima Entrega.

### 16.2 Marco B — atenção e execução contextual

- Construir briefing por Missão e Frente.
- Ligar estado de Agente a Frente sem inferir conclusão.
- Criar fluxo Entrega proposta → evidência → aceite ou reabertura.
- Projetar bloqueios, aprovações e Decisões em Agora.
- Criar Linha do tempo de Missão.

**Aceite:** três agentes trabalham em Frentes da mesma Missão e uma pessoa entende o estado em menos de um minuto.

### 16.3 Marco C — Canvas semântico completo

- Implementar relações tipadas, filtros e visões derivadas.
- Colapsar terminal em cartão de Agente e abrir TUI apenas sob demanda.
- Ancorar comentário em Frente, Decisão ou Entrega.
- Validar revisão de Missão sem troca obrigatória entre terminais.

**Aceite:** equipe revisa trabalho pelo Canvas e Linha do tempo, não pelo histórico de janelas.

### 16.4 Marco D — Sala remota segura

- Implementar WSS, identidade, convite, papéis e isolamento.
- Implementar operação idempotente, snapshot, delta e fila offline.
- Replicar modelo de Missão antes de qualquer sessão de agente.
- Testar duas identidades em navegadores e aplicativo macOS.

**Aceite:** duas pessoas convidadas convergem no mesmo Canvas e podem propor Decisão ou aceitar Entrega sem ver ambiente privado da outra.

### 16.5 Marco E — colaboração sobre execução

- Publicar resumo e artefato permitido de Agente.
- Implementar proposta de direção e handoff transacional.
- Adicionar grants e política antes de Worker remoto.

**Aceite:** alguém acompanha ou assume responsabilidade por Frente sem abrir ou controlar terminal de outra máquina.

### 16.6 Marco F — Worker remoto restrito

- Consumir somente jobs tipados e permitidos.
- Exigir grant, allowlist, isolamento e revogação.
- Sanitizar resultados publicados.
- Testar cancelamento, revogação e retenção.

## 17. Matriz de conformidade

| Área | Critério mínimo |
| --- | --- |
| Canvas | cria, organiza, conecta e filtra objetos sem perder semântica |
| Missão | reabrir app e explicar objetivo, dono, bloqueio e próximo passo sem terminal |
| Briefing | inclui objetivo, pronto, dependências e escalonamento; campo ausente falha |
| Agente | mudança de estado não conclui Frente automaticamente |
| Entrega | aceite exige evidência e autor quando necessário |
| Agora | bloqueio ou aprovação persistente aparece como ação humana |
| Linha do tempo | mudança relevante tem autor, tempo, alvo e resultado |
| Handoff | proposta não concede acesso; aceite transfere responsabilidade com briefing |
| Sala | viewer não altera; editor não administra; eventos não cruzam Sala |
| Recuperação | snapshot mais delta converge após rede intermitente ou reinício |
| Privacidade | transporte e log não contêm PTY, segredo, .env, cookie ou path absoluto |
| Worker futuro | texto de Sala nunca é executado como comando |

## 18. Fonte de verdade documental

Este arquivo é a única especificação normativa do produto e do sistema Colmeia.

Documentos futuros devem seguir esta regra:

- documentação de arquitetura ou API deve ser subseção, apêndice ou referência explícita desta spec;
- planos de release devem apontar para seções desta spec;
- auditorias devem ser datadas e arquivadas, nunca usadas como contrato;
- exemplos devem ser marcados como não normativos;
- mudança de comportamento deve atualizar esta spec e os testes correspondentes.
