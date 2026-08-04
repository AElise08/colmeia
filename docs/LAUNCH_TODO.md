# Colmeia — TODO de lançamento

Última revisão: 2026-08-04
Versão alvo: `0.3.0` / public beta

Use `[x]` para itens concluídos e `[ ]` para pendências. Os itens em
**Bloqueadores** precisam estar concluídos antes de enviar o produto.

## Bloqueadores antes do envio

- [x] Implementar sincronização persistente do layout semântico da Sala.
- [x] Implementar replay offline idempotente do outbox.
- [x] Validar WSS fail-closed sem certificado.
- [x] Rodar a suíte: **203 testes em 43 suites**.
- [x] Gerar `dist/Colmeia.app` em release e verificar assinatura local.
- [x] Smoke-testar uma cópia limpa do bundle (`colmeia` e `colmeia-engine`
      reportam a versão `0.3.0`).
- [ ] Assinar com certificado Apple de distribuição.
- [ ] Notarizar o app e validar a abertura em uma máquina limpa.
- [ ] Fazer instalação e smoke test em um segundo Mac.
- [x] Preparar release notes da versão `0.3.0` em
      `docs/RELEASE_NOTES_0.3.0.md`.
- [ ] Confirmar uma URL pública estável e contato de suporte para a página do
      Product Hunt.
- [x] Escrever a política de privacidade inicial em `docs/PRIVACY.md`.

## Se a demo usar colaboração remota

- [ ] Configurar certificado PKCS#12 real para WSS.
- [ ] Colocar o Hub atrás de reverse proxy e manter a porta do Engine privada.
- [ ] Configurar token por secret manager; não colocar segredo no repositório.
- [ ] Criar convite exclusivo para a demo.
- [ ] Testar entrada, reconexão, layout compartilhado e revogação do convite.
- [ ] Revogar o convite após a gravação ou publicação.

## Ensaio da demo

- [ ] Começar com workspace descartável sem dados pessoais.
- [ ] Repetir o roteiro: missão → dois agentes → handoff → aprovação →
      frame semântico → convite → entrega aceita.
- [ ] Confirmar que a demo funciona sem abrir logs privados de terminal.
- [ ] Manter um roteiro local-first de fallback caso o Hub remoto falhe.
- [ ] Revisar poster, vídeo e screenshots para remover tokens, paths, URLs
      locais, nomes de workspace e certificados.

## Publicação no Product Hunt

- [ ] Copiar nome, tagline e descrição de
      `docs/PRODUCT_HUNT_LAUNCH.md`.
- [ ] Anexar `docs/democolmeia-poster.png` e `docs/democolmeia.mov`.
- [ ] Publicar o link da landing page `docs/lumes.works.html` em um endereço
      público, se ele ainda não estiver hospedado.
- [ ] Escolher data/horário e preparar mensagem de lançamento e respostas.
- [ ] Monitorar comentários, crashes e feedback nas primeiras 24 horas.

## Pós-lançamento (não bloqueia o beta)

- [ ] Migrar gradualmente o data-plane do workspace para CRDT compatível.
- [ ] Automatizar assinatura, notarização e publicação de releases.
- [ ] Adicionar telemetria opt-in de erros e métricas de saúde do Hub.
- [ ] Documentar backup/restauração e procedimento de incidente.

## Comandos de verificação

```bash
./test.sh
./scripts/build-app.sh
codesign --verify --deep --strict dist/Colmeia.app
```

Para um release distribuível, use uma identidade Apple e um perfil previamente
configurado no `notarytool`:

```bash
COLMEIA_CODESIGN_IDENTITY='Developer ID Application: Equipe (TEAMID)' \
COLMEIA_NOTARY_PROFILE='colmeia-release' ./scripts/build-app.sh
```
