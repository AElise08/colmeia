# Colmeia — Nota de privacidade do beta

Última revisão: 2026-08-04

Esta é a nota de privacidade do beta público. Ela deve ser publicada em uma
URL estável antes do envio ao Product Hunt e revisada pela pessoa responsável
pelo lançamento conforme a jurisdição aplicável.

## O que fica local

Por padrão, o Colmeia mantém no Mac da pessoa operadora os workspaces, arquivos,
PTYs, journals, histórico de terminal, credenciais e cookies. O Engine local é
o dono desses dados e não os envia ao Hub automaticamente.

## O que pode ser compartilhado

Quando a pessoa habilita uma Sala e entra no Hub, o serviço recebe somente o
estado autorizado da Sala: identidade da colaboração, membros, presença,
missões, decisões, entregas, eventos e posições dos objetos semânticos. O
cliente não deve publicar PTY, shell, cookies, credenciais ou paths privados.

## Hub operado pela equipe

Quem opera um Hub pode acessar os dados compartilhados naquela Sala, além de
logs técnicos necessários para autenticação, rate limiting, disponibilidade e
backup. Convites, tokens, certificados e backups devem ser tratados como
segredos operacionais e armazenados fora do repositório.

## Telemetria e terceiros

Este beta não presume telemetria de produto. Qualquer coleta opcional, serviço
de analytics, hospedagem ou integração de terceiros deve ser declarada na
versão publicada desta nota antes de ativação.

## Direitos e contato

Para solicitar remoção, exportação ou esclarecer dúvidas, use o contato de
suporte publicado junto com o download. O endereço real de contato ainda deve
ser preenchido pelo responsável pelo lançamento.
