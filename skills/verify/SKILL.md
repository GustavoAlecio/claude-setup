---
name: verify
model: opus
description: Etapa 5 do Fluxo Smart — G1 arquitetural do ciclo inteiro + G2 QA (critérios de aceite, testes, app rodando) via workflow smart-verify; reprovou → reentra na escada automaticamente
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
source ~/.claude/bin/get-project.sh
PROJECT_NAME=$(get-project-name)
WF_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
```

## 2. Pré-requisitos

Leia `$WF_DIR/current.json`, `spec.md`, `plan.md`, `tasks.md`.
- Tasks pendentes → "Há tasks pendentes. Rode `/implement` primeiro."
- Sem `exec.base_checkpoint` → o ciclo não passou pelo `/implement` novo; pare e explique.

Mesmo profile de stack do `/implement` (seção 3 de lá).

## 3. Preparar run

```bash
bash ~/.claude/bin/capture-metrics.sh start verify "$PROJECT_NAME" "$PROJECT_PATH"
RUN_ID="verify-$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$WF_DIR/runs/$RUN_ID"
mkdir -p "$RUN_DIR"
```

Relatório: início da etapa

```bash
python3 ~/.claude/bin/wf-report.py stage-start verify --workflow-dir "$WF_DIR" ${CLAUDE_FLOW_SESSION_ID:+--session "$CLAUDE_FLOW_SESSION_ID"} || true
```

Para G2 com runtime, o device do profile (`g2_device`) precisa estar disponível. Cheque com o dart MCP (`list_devices`); se não estiver, avise antes de disparar — o QA vai voltar `inconclusive`.

## 4. Disparar

Ferramenta **Workflow** com `name: "smart-verify"` e `args`:

```json
{
  "project_path": "<PROJECT_PATH>",
  "workflow_dir": "<WF_DIR>",
  "run_dir": "<RUN_DIR>",
  "stack_name": "flutter",
  "stack": { "...profile..." },
  "base_checkpoint": "<exec.base_checkpoint>",
  "checkpoint": "<exec.checkpoint>",
  "plan_path": "<WF_DIR>/plan.md",
  "spec_path": "<WF_DIR>/spec.md",
  "lessons_path": "<se existir>",
  "tasks": [ "...todos os tasks.items, com tier/tier0/attempts/files_changed/tests/affects..." ],
  "max_rounds": 2,
  "max_attempts": 5,
  "per_tier": 2
}
```

Informe em 1 linha e encerre o turno.

## 5. Ao receber o resultado

Grave em `$RUN_DIR/workflow-result.json` e persista e importe o run no relatório:

```bash
python3 ~/.claude/bin/wf-event.py persist --run-dir "$RUN_DIR" --workflow-dir "$WF_DIR" --result-file "$RUN_DIR/workflow-result.json"
python3 ~/.claude/bin/wf-report.py import-run verify --workflow-dir "$WF_DIR" --run-dir "$RUN_DIR" || true
```

Relatório:

```markdown
## Verify — <status> (rodadas: N)

### G1 — arquitetura
| Reviewer | Veredito | Bloqueantes |
|---|---|---|

### G2 — critérios de aceite
| # | Critério | Status | Evidência |
|---|---|---|---|

### Reentradas
- r1: T2, V1 → done (T2 sonnet→opus)
```

Por `status`:

- **verified** → marque os critérios PASS como `[x]` na `spec.md`, rode `capture-metrics.sh end verify` (seta `verified`). Liste os UNTESTABLE explicitamente — são o que o QA humano precisa olhar. Auto on: siga para `/complete`. Auto off: "Verificado. Fechar o ciclo? `/complete`".
- **inconclusive** → o QA não conseguiu validar (device, backend, credencial). Mostre o motivo; não marque nada. Ofereça rodar de novo depois de resolver o ambiente.
- **blocked / backtrack** → mesmo tratamento do `/implement` (diagnosis ToT, protocolo de desvio). Nunca decida sozinho.

Findings minor/nit dos reviewers: liste no fim como "não bloqueantes", sem abrir task.

Relatório: fim da etapa. Escreva com **Write** um resumo de 3 a 10 linhas em `$WF_DIR/.stage-summary.md` (nunca interpole texto em shell) e rode (acrescente `--status blocked` em `inconclusive`/`blocked`/`backtrack`):

```bash
python3 ~/.claude/bin/wf-report.py stage-end verify --workflow-dir "$WF_DIR" --summary-file "$WF_DIR/.stage-summary.md" || true
```
