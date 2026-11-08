---
name: implement
model: opus
description: Etapa 4 do Fluxo Smart — executa as tasks via workflow smart-implement com escada de modelos (haiku→sonnet→opus→fable) e gates G0/G1 por task
---

Esta skill não implementa: ela prepara os args, dispara o workflow `smart-implement` e trata o resultado. Quem escreve código são os `dev-implementer` no tier que a escada decidir.

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
source ~/.claude/bin/get-project.sh
PROJECT_NAME=$(get-project-name)
WF_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
```

## 2. Pré-requisitos

Leia `$WF_DIR/plan.md`, `$WF_DIR/tasks.md` e `$WF_DIR/current.json`. Faltando algum, informe a etapa.

Valide o plano de tasks antes de disparar (campos da escada, Red-only, testes que nenhuma task cria):

```bash
python3 ~/.claude/bin/wf_gate.py tasks-check --workflow-dir "$WF_DIR" --repo "$PROJECT_PATH"
```

Saída 1: mostre os erros e pare, apontando `/tasks` — sem isso o G0 reprova por construção.

## 3. Stack

Escolha o profile em `~/.claude/stacks/*.json` cujo `detect` existe na raiz do repo ou no package root mais próximo dos `affects` (Flutter: `pubspec.yaml`; app em subdiretório como `app/` conta). Monorepo com mais de uma stack: use a do diretório onde a maioria dos `affects` cai. Nenhum profile casa → pare e diga qual stack falta (o motor não roda sem G0).

### 3a. Audit do harness

```bash
python3 ~/.claude/bin/harness-audit.py --repo "$PROJECT_PATH" --stack <stack> --phase kickoff --text
```

Roda os comandos do G0 num arquivo de controle e confere SDK, deps, codegen, submódulos e o profile contra o repo.
- **FAIL (critical)** → pare. Mostre os findings e ofereça `--fix` (link do SDK, `make setup`/pub get + build_runner, submódulo limpo). Só rode `--fix` com OK do usuário; depois, audite de novo.
- **major** → mostre numa linha cada e siga. Submódulo que guarda o `adr_dir` fora do commit registrado merece destaque: os ADRs lidos não são os desta branch.
- Falha de ambiente que escapar do audit e aparecer no G0 depois vira check novo no `harness-audit.py`, não lesson.

## 4. Preparar run

```bash
bash ~/.claude/bin/capture-metrics.sh start implement "$PROJECT_NAME" "$PROJECT_PATH"
RUN_ID="impl-$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$WF_DIR/runs/$RUN_ID"
mkdir -p "$RUN_DIR"
```

Relatório: início da etapa

```bash
python3 ~/.claude/bin/wf-report.py stage-start implement --workflow-dir "$WF_DIR" ${CLAUDE_FLOW_SESSION_ID:+--session "$CLAUDE_FLOW_SESSION_ID"} || true
```

Checkpoint base:
- `current.json.exec.checkpoint` existe (retomada ou execução anterior) → use-o.
- Senão: `bash ~/.claude/bin/wf-checkpoint.sh create "$PROJECT_PATH"` e grave em `exec.checkpoint` **e** `exec.base_checkpoint` (o verify usa o base para o diff do ciclo inteiro).

Grave o profile de stack que vai nos args (com overrides do run, ex.: `autofix: []` em repo não formatado) em `$RUN_DIR/stack.json`: o G0 lê esse arquivo via `--profile` e só cai no `~/.claude/stacks/<stack>.json` se ele não existir.

Atualize `status` para `"implementing"`.

## 5. Disparar o workflow

Chame a ferramenta **Workflow** com `name: "smart-implement"` e `args` (objeto JSON, não string):

```json
{
  "project_path": "<PROJECT_PATH>",
  "workflow_dir": "<WF_DIR>",
  "run_dir": "<RUN_DIR>",
  "stack_name": "flutter",
  "stack": { "...conteúdo de ~/.claude/stacks/flutter.json..." },
  "checkpoint": "<exec.checkpoint>",
  "plan_path": "<WF_DIR>/plan.md",
  "spec_path": "<WF_DIR>/spec.md",
  "lessons_path": "<~/.claude/projects/PROJECT_NAME/lessons.md, se existir>",
  "tasks": [ "...items com status != done, na ordem do tasks.md, com id/title/description/complexity/risk/tier0/tier/attempts/tests/affects..." ],
  "max_attempts": 5,
  "per_tier": 2
}
```

O workflow roda em background. Informe em 1 linha: "Rodando `smart-implement` (N tasks, run `<RUN_ID>`). Acompanhe em `/workflows`." e encerre o turno.

## 6. Ao receber o resultado

Grave o JSON retornado em `$RUN_DIR/workflow-result.json` e persista:

```bash
python3 ~/.claude/bin/wf-event.py persist --run-dir "$RUN_DIR" --workflow-dir "$WF_DIR" --result-file "$RUN_DIR/workflow-result.json"
python3 ~/.claude/bin/wf-report.py import-run implement --workflow-dir "$WF_DIR" --run-dir "$RUN_DIR" || true
bash ~/.claude/bin/capture-metrics.sh end implement "$PROJECT_NAME" "$PROJECT_PATH"
```

Marque `[x]` no `tasks.md` para as tasks `done`. Apresente:

```
## Implement — <status>
| Task | Cx | tier0 → final | Tentativas | Status |
|---|---|---|---|---|
- Escaladas: N · tokens de saída (trace): X
```

Relatório: fim da etapa. Escreva com **Write** um resumo de 3 a 10 linhas em `$WF_DIR/.stage-summary.md` (nunca interpole texto em shell) e rode (acrescente `--status blocked` em `backtrack`/`blocked`):

```bash
python3 ~/.claude/bin/wf-report.py stage-end implement --workflow-dir "$WF_DIR" --summary-file "$WF_DIR/.stage-summary.md" || true
```

Backtracks e blockers já entram pelo `import-run`; use `decision` só para escolhas suas fora disso.

Depois, por `status`:

- **done** → `status: "implemented"`. Auto on: siga para `/verify`. Auto off: "Implementado. Verificar? `/verify`".
- **backtrack** → o dev-implementer declarou o plano inviável na task `blocked_task`. Aplique o **protocolo de desvio**: mostre o `reason`, proponha o ajuste no `plan.md` (e `spec.md` se for o caso) e faça um `AskUserQuestion` (parada incondicional, mesmo com auto on) com "Aplicar o ajuste (Recommended)", "Ajustar" e "Rejeitar". Aprovado, registre em `backtracks` e rode `/implement` de novo (retoma das pendentes).
- **blocked** → escada esgotada, falha repetida entre tiers ou gate quebrado. Mostre o `reason` e as hipóteses do `diagnosis` ordenadas por confidence (lente, hipótese, evidência, ação recomendada). Parada incondicional: faça um `AskUserQuestion` com as opções corrigir spec → `/challenge-spec`; replanejar → `/plan`; corrigir ambiente e retomar → `/implement`; assumir a task manualmente. Não decida sozinho, nem com auto on.

## Não fazer

- Não implemente tasks no contexto principal "para adiantar" — isso fura a escada e a telemetria.
- Não commite. O checkpoint é tree object, não commit.
