# Draft para Show HN

Revise este texto em sua própria voz antes de publicar. As [regras do Hacker
News](https://news.ycombinator.com/newsguidelines.html) pedem conversa humana,
não texto gerado ou editado por IA.

## Title

Show HN: Colmeia — a local-first canvas for humans and AI agents

## URL

https://github.com/AElise08/colmeia

## Text

Hi HN, I built Colmeia because coordinating several coding agents usually
means reconstructing context from terminals, notes, chat windows, and half-
finished handoffs.

Colmeia is a macOS canvas for local-first work. A workspace can contain real
terminals, agents, notes, missions, decisions, deliveries, and connections.
The local Engine owns PTYs and files. An optional Hub lets invited identities
share sanitized room state without sharing shell output, cookies, credentials,
or private paths.

The public beta currently includes:

- persistent missions, decisions, deliveries, journals, and workspace state;
- agent handoffs and human approval gates;
- WebSocket rooms with invitations, roles, presence, and semantic canvas layout;
- durable offline replay with idempotent request IDs;
- a CLI for agents to inspect context, write notes, ask other agents, and
  report deliveries.

The project is intentionally macOS-first (macOS 15+, Swift 6). From source:

    git clone https://github.com/AElise08/colmeia.git
    cd colmeia
    swift build
    ./test.sh

The current suite has 203 tests in 43 suites. This is a public beta, not a
hosted service: the full workspace data-plane migration to CRDT is still a
later milestone, and remote Hub deployment requires the operator to configure
TLS and authentication.

I would especially like feedback on the boundary between local execution and
shared room state, and on whether the canvas makes multi-agent work easier to
understand than a collection of terminal tabs. What would you want to inspect
or change first?
