---
name: challenge-spec
model: opus
description: Etapa 1b do Fluxo Smart — ataca a spec aprovada antes do /plan (critérios não verificáveis, regras ausentes, contradições com o código) via subagent spec-challenger e aplica as correções aceitas.
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
WF_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
```

## 2. Pré-requisito

Leia `$WF_DIR/spec.md`. Se não existir, peça `/specify` primeiro.

## 3. Desafiar

Spawne o subagent `spec-challenger` (Agent tool, `subagent_type: spec-challenger`) com: caminho da spec, `PROJECT_PATH`, e o caminho de `docs/adr/INDEX.md` e `.claude/rules/` do repo se existirem. Não resuma a spec no prompt — ele lê.

## 4. Apresentar e aplicar

Mostre o relatório do agente sem reescrever.

- **OK** → registre `"challenge": {"verdict": "ok"}` no `current.json` e siga.
- **AJUSTES / BLOQUEANTE** → pergunte quais itens aplicar (por id: B1, A2…). Aplique os escolhidos direto na `spec.md`, incluindo os critérios reescritos. Registre `"challenge": {"verdict": "<v>", "applied": [...], "rejected": [...]}`.

## 5. Piloto automático

```bash
test -f ~/.claude/workflow/auto_mode.flag && echo "AUTO_ON" || echo "AUTO_OFF"
```

- `AUTO_ON` e veredito **OK ou AJUSTES**: aplique todos os ajustes e os critérios reescritos, informe em 1 linha e avance para `/plan`.
- `AUTO_ON` e veredito **BLOQUEANTE**: **pare** mesmo com auto. Bloqueante significa que a spec contradiz o código ou o critério central não é verificável — não é decisão automatizável.
- `AUTO_OFF`: finalize com "Spec desafiada. Seguir para o plano? `/plan`".
