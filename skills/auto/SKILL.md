---
name: auto
description: Liga ou desliga o piloto automatico do Fluxo Smart
---

## Toggle Piloto Automatico

1. Verificar se o arquivo `~/.claude/workflow/auto_mode.flag` existe
2. Se **existe**: remover o arquivo e informar "Piloto automatico **desativado**. As confirmacoes que dependem do piloto (como a classificacao do kickoff) voltam a ser pedidas. Os gates `spec`, `plan`, `tasks` e `pr` nao mudam: nao dependem do piloto."
3. Se **nao existe**: criar o arquivo com conteudo `on` e informar "Piloto automatico **ativado**. O fluxo smart avancara as etapas sem pedir confirmacao, incluindo phases, e para nas paradas incondicionais: bloqueante do challenger, `backtrack`/`blocked` do implement e do verify, checagem 4a do kickoff, reuso de branch existente, base `release/*`, `reset --hard`, push e force. Cada parada vira um `AskUserQuestion`. O piloto nao decide os gates `spec`, `plan`, `tasks` e `pr`: quem decide e `wf-report.py gate` (`spec` e `pr` sempre perguntam; `plan` e `tasks` so com decisao em aberto, ou se listados em `~/.claude/workflow/gates.json`). Seguranca inviolavel continua ativa."

Sempre mostrar o estado final apos o toggle.
