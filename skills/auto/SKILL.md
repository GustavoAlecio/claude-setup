---
name: auto
description: Liga ou desliga o piloto automatico do Fluxo Smart
---

## Toggle Piloto Automatico

1. Verificar se o arquivo `~/.claude/workflow/auto_mode.flag` existe
2. Se **existe**: remover o arquivo e informar "Piloto automatico **desativado**. O fluxo smart voltara a parar em todos os gates (`spec`, `plan`, `tasks`, `pr`), como `AskUserQuestion` com Aprovar, Ajustar e Rejeitar."
3. Se **nao existe**: criar o arquivo com conteudo `on` e informar "Piloto automatico **ativado**. O fluxo smart avancara as etapas sem pedir aprovacao, incluindo phases, mas ainda para nos gates listados em `~/.claude/workflow/gates.json` (`{\"required\": [...]}`; sem o arquivo, `spec` e `pr`) e nas paradas incondicionais: bloqueante do challenger, `backtrack`/`blocked` do implement e do verify, checagem 4a do kickoff, reuso de branch existente, base `release/*`, `reset --hard`, push e force. Cada parada vira um `AskUserQuestion`. Seguranca inviolavel continua ativa."

Sempre mostrar o estado final apos o toggle.
