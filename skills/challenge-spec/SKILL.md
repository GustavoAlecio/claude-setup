---
name: challenge-spec
model: opus
description: Etapa 1b do Fluxo Smart — ataca a spec aprovada antes do /plan (critérios não verificáveis, regras ausentes, contradições com o código) via subagent spec-challenger e aplica as correções aceitas.
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
source ~/.claude/bin/get-project.sh
PROJECT_NAME=$(get-project-name)
WF_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
```

## 2. Pré-requisito

Leia `$WF_DIR/spec.md`. Se não existir, peça `/specify` primeiro.

Relatório: início da etapa

```bash
python3 ~/.claude/bin/wf-report.py stage-start challenge --workflow-dir "$WF_DIR" ${CLAUDE_FLOW_SESSION_ID:+--session "$CLAUDE_FLOW_SESSION_ID"} || true
```

## 3. Desafiar

Spawne o subagent `spec-challenger` (Agent tool, `subagent_type: spec-challenger`) com: caminho da spec, `PROJECT_PATH`, e o caminho de `docs/adr/INDEX.md` e `.claude/rules/` do repo se existirem. Não resuma a spec no prompt — ele lê.

## 4. Apresentar e aplicar

Mostre o relatório do agente sem reescrever.

- **OK** → registre `"challenge": {"verdict": "ok"}` no `current.json` e siga.
- **AJUSTES / BLOQUEANTE** → pergunte quais itens aplicar (por id: B1, A2…). Aplique os escolhidos direto na `spec.md`, incluindo os critérios reescritos. Registre `"challenge": {"verdict": "<v>", "applied": [...], "rejected": [...]}`.

Registre os achados (nunca interpole texto em shell): escreva com **Write** em `$WF_DIR/.findings.json` um objeto `{"accepted": [...], "rejected": [...]}` com `{"id": "B1", "text_md": "..."}` por item (listas vazias se o veredito foi OK) e rode:

```bash
python3 ~/.claude/bin/wf-report.py findings challenge --workflow-dir "$WF_DIR" --source spec-challenger --file "$WF_DIR/.findings.json" || true
```

Relatório: fim da etapa. Escreva com **Write** um resumo de 3 a 10 linhas em `$WF_DIR/.stage-summary.md` (nunca interpole texto em shell) e rode:

```bash
python3 ~/.claude/bin/wf-report.py stage-end challenge --workflow-dir "$WF_DIR" --summary-file "$WF_DIR/.stage-summary.md" || true
```

## 5. Parada incondicional e gate `spec`

```bash
test -f ~/.claude/workflow/auto_mode.flag && echo "AUTO_ON" || echo "AUTO_OFF"
```

- Veredito **BLOQUEANTE** (com auto on ou off): parada incondicional, fora do `gates.json`. Bloqueante significa que a spec contradiz o código ou o critério central não é verificável; não é decisão automatizável. Faça um `AskUserQuestion` com as opções "Aplicar os ajustes propostos (Recommended)", "Voltar ao `/specify`" e "Abortar", e só siga ao gate abaixo depois de resolvido.
- `AUTO_ON` e veredito **OK ou AJUSTES**: aplique todos os ajustes e os critérios reescritos.

Gate `spec` (decisão determinística; nunca leia `gates.json`):

```bash
python3 ~/.claude/bin/wf-report.py gate spec
```

- `skip`: atualize `status` para `"spec_approved"` no `current.json`, informe em 1 linha e execute `/plan`.
- `ask`: o `stage-end` acima já rodou; faça um `AskUserQuestion` ("Spec aprovada para planejar?") com as opções:
  - **Aprovar (Recommended)**: atualize `status` para `"spec_approved"` no `current.json`, execute `/plan` na mesma sessão.
  - **Ajustar**: o usuário escreve o ajuste em Other; aplique o texto e repita este mesmo gate.
  - **Rejeitar**: rode `stage-end challenge --status blocked` (mesmo `--summary-file`), mantenha o `status` do `current.json` e encerre o turno.
- A resposta do usuário vira decisão: escreva-a com **Write** em `$WF_DIR/.decision.md` e rode `python3 ~/.claude/bin/wf-report.py decision challenge --workflow-dir "$WF_DIR" --by user --text-file "$WF_DIR/.decision.md" || true`.
