# Product Hunt — Colmeia

## Listing

**Name:** Colmeia

**Tagline:** A visual workspace where humans and AI agents keep the thread.

**Description:** Colmeia brings terminals, agents, notes, missions, decisions,
deliveries, and collaboration into one local-first canvas. Agents can work in
parallel while people keep ownership of context, approvals, and evidence. The
Engine keeps private PTYs and files local; invited Hub rooms share only the
sanitized work state.

## What to show in the launch demo

1. Open a workspace and create a Mission.
2. Start two agents with distinct roles on the canvas.
3. Show Agent Chat, a handoff, and a human approval.
4. Switch to Mission view and move a semantic frame.
5. Open Rooms, invite a second identity, and show the frame position and
   Mission event arriving through the Hub.
6. Show a Delivery with evidence and human acceptance.

Use `docs/democolmeia-poster.png` as the thumbnail and
`docs/democolmeia.mov` as the product video. The existing landing page is
`docs/lumes.works.html`.

## Launch checklist

O checklist operacional completo está em
`docs/LAUNCH_TODO.md`.
Antes do envio, publique também `docs/PRIVACY.md` em uma URL estável e
substitua o contato de suporte de placeholder pelo endereço real.

- [ ] Build the macOS app with `./scripts/build-app.sh`; sign/notarize it for
      distribution outside the development machine.
- [ ] Run `./test.sh` and keep the reported test count in the release note.
- [ ] Test a clean install on a second macOS machine.
- [ ] For remote rooms, configure a real TLS certificate and run the Hub behind
  a reverse proxy; never expose the Engine port.
- [ ] Create a fresh invite token for the demo and revoke it afterwards.
- [ ] Remove tokens, certificates, workspace data, and local URLs from screenshots.
- [ ] Confirm the demo can be completed without opening a private terminal log.

## Honest scope

The first public beta is local-first. The Hub synchronizes rooms, semantic
objects, presence, missions, decisions, deliveries, and layout positions, but
never exposes a user's PTY, shell, cookies, or private paths. The full CRDT
data-plane migration is intentionally a later compatibility milestone.
