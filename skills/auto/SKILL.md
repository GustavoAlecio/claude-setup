---
name: auto
description: Liga ou desliga o piloto automatico do Fluxo Smart
---

## Toggle Piloto Automatico

1. Verificar se o arquivo `~/.claude/workflow/auto_mode.flag` existe
2. Se **existe**: remover o arquivo e informar "Piloto automatico **desativado**. O fluxo smart voltara a pedir aprovacao em `/specify` e `/plan`."
3. Se **nao existe**: criar o arquivo com conteudo `on` e informar "Piloto automatico **ativado**. O fluxo smart avancara todas as etapas sem pedir aprovacao, incluindo phases. Seguranca inviolavel continua ativa."

Sempre mostrar o estado final apos o toggle.
