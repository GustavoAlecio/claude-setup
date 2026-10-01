---
id: 0017
title: GitHub pelo engine com conta por org, token por processo, ambiente limpo, identidade SSH pela URL efetiva e redação
status: accepted
date: 2026-10-01
affects: ["engine/gh_env.mjs", "engine/github.mjs", "engine/engine.mjs", "engine/sessions.mjs", "app/lib/data/github_parser.dart", "app/lib/data/http_github_repository.dart", "app/lib/features/prs/**", "app/lib/features/inbox/**", "app/lib/features/settings/**"]
supersedes: ["0016"]
superseded_by: []
tags: [engine, github, security, flutter]
---

# 0017 — GitHub pelo engine com conta por org, token por processo, ambiente limpo, identidade SSH pela URL efetiva e redação

## Contexto
A 0016 pôs o `gh` no engine, mas com a conta ativa do keyring. Há mais de uma conta logada, e cada org do app trabalha com uma delas. Com a conta errada, PRs e Para revisar caem em "cache" ou ficam vazios, e as sessões (Resolver, Revisar) rodam `gh` como a conta errada. O usuário exige que as identidades não se misturem: nem trocar a conta ativa, nem mexer em chave SSH, helper ou config global do git. O repo é público.

## Decisão
Continua valendo da 0016: o `gh` roda só no engine, com cache de 60 s que guarda a promise e as falhas, mensagens fixas, fallback para o `prs.json` e `cwd` validado pelo `remote.origin.url`.

Muda:
- **Conta por chamada:** rotas e sessões recebem `account`/`githubAccount` opaco (o engine não lê a config, ADR 0014). O token vem de `gh auth token --user <login>`, fica em memória por 5 min (promise compartilhada; 401 invalida) e entra como `GH_TOKEN` só no ambiente daquele processo. A conta ativa nunca muda. Falha vira a mensagem fixa "conta <login> não está logada no gh (gh auth login)".
- **Ambiente limpo:** todo `gh` do engine roda sem `GH_TOKEN`, `GITHUB_TOKEN`, `GH_HOST` e os tokens de Enterprise herdados, e com `GH_PROMPT_DISABLED=1`. As sessões recebem o mesmo ambiente mais `GIT_TERMINAL_PROMPT=0`, e `SSH_AUTH_SOCK`, `GIT_SSH_COMMAND` e o helper ficam como estão. O `git` do engine leva `-c credential.helper=`.
- **Entrada:** `account` e `owner` passam pelo regex de login antes de virar argumento (400 "parâmetro inválido"). As chaves de cache incluem a conta e os owners normalizados (`pr:<conta|->:<url>`, `inbox:<conta|->:<owners>`).
- **Identidade SSH:** a URL efetiva vem do próprio git (`ls-remote --get-url` por owner; `remote get-url --push` por checkout validado), sem parser de `insteadOf`. O engine roda `ssh -T` com `BatchMode`, `ConnectTimeout=8`, `StrictHostKeyChecking=yes` e `UpdateHostKeys=no` e lê `Hi <login>!` no stderr. O cache é por `(user, host, port)`: 5 min para sucesso, 30 s para erro. Remote `https`/`git://` não é verificável e é reportado como tal.
- **Redação:** `redact` troca os tokens conhecidos e qualquer `gh[opsu]_…` por `***` antes de cachear, logar, responder e emitir evento de sessão (deltas incluídos). O snapshot guarda só `githubAccount`, e o resume pede o token de novo. Conta ausente no resume dá 409, nunca a conta ativa.

## Alternativas consideradas
- **`gh auth switch` por chamada:** muda estado global e disputa com o terminal do usuário.
- **Token gravado na config ou no snapshot:** credencial em disco num repo público e em arquivos que o app lê.
- **Parser de `insteadOf` no engine:** reimplementa regras do git (prefixo mais longo, `pushInsteadOf`) e diverge dele em silêncio.
- **Gerenciar chave SSH ou helper por sessão:** invade a config do usuário, que já separa as identidades via `~/.ssh/config`.

## Consequências
- O agente de uma sessão consegue ler o próprio `GH_TOKEN` (ameaça aceita), e o transcript do SDK em `~/.claude/projects` não é redigido.
- Token renovado por `gh auth refresh` não chega a uma sessão viva até o resume.
- Remote HTTPS segue o helper do usuário. O app só avisa.
- A verificação SSH depende de rede e do agent. Sem resposta, a UI mostra "não verificado" e não bloqueia.
- Versão do engine 0.4.0.

## Relacionados
- [[0014-sessao-de-org]]
- [[0016-github-pelo-engine]] (substituída por esta decisão)
- [[0007-engine-node-processo-filho]]
