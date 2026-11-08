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
bash ~/.claude/bin/wf-checkpoint.sh create "$PROJECT_PATH" > "$RUN_DIR/revision-start.tree"
```

`revision-start.tree` é a árvore que o verify vai julgar. O `persist` compara com a árvore no fim: se alguém mexeu no repo durante o verify, o resultado cai para `unverified` (`REVISION_CHANGED`). Não edite o repo entre o disparo e o `persist`.

Relatório: início da etapa

```bash
python3 ~/.claude/bin/wf-report.py stage-start verify --workflow-dir "$WF_DIR" ${CLAUDE_FLOW_SESSION_ID:+--session "$CLAUDE_FLOW_SESSION_ID"} || true
```

Antes de disparar, audite o harness na fase verify (inclui o `g2_device`: plataforma existe no repo e device conectado):

```bash
python3 ~/.claude/bin/harness-audit.py --repo "$PROJECT_PATH" --stack <stack> --phase verify --quick --text
```

- **FAIL** → não dispare: o G2 voltaria `inconclusive` e gastaria a rodada. Mostre os findings; device desconectado → peça para conectar e espere o OK; `G2-PLATFORM` → o `g2_device` do profile não serve para este repo, decisão do usuário. `--fix` só com OK.
- **major** → mostre e siga.

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
  "revision_start": "@<RUN_DIR>/revision-start.tree",
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

Grave em `$RUN_DIR/workflow-result.json` exatamente como veio (não edite `status`, `reason` nem `decision`) e persista e importe o run no relatório. O `persist` vincula o resultado à revisão e grava `exec.verify` no `current.json`; o status que vale é o do `result.json` persistido, não o que o workflow devolveu:

```bash
python3 ~/.claude/bin/wf-event.py persist --run-dir "$RUN_DIR" --workflow-dir "$WF_DIR" --result-file "$RUN_DIR/workflow-result.json"
python3 ~/.claude/bin/wf-report.py import-run verify --workflow-dir "$WF_DIR" --run-dir "$RUN_DIR" || true
```

Relatório:

```markdown
## Verify — <status> · <decision.reason_code> (rodadas: N)

Critérios: X PASS · Y FAIL · Z PARTIAL · W UNTESTABLE · revisão <decision.revision_id[:12]>

### G1 — arquitetura
| Reviewer | Veredito | Bloqueantes |
|---|---|---|

### G2 — critérios de aceite
| # | Critério | Status | Evidência |
|---|---|---|---|

### Reentradas
- r1: T2, V1 → done (T2 sonnet→opus)
```

A decisão é do código (`decide` no `smart-verify.js`, fail-closed); você só relata. `verified` exige G1 todo `pass`, G2 `pass`, ao menos um critério PASS com evidência, nenhum FAIL/PARTIAL/UNTESTABLE e nenhum finding critical/major. Rode `capture-metrics.sh end verify` em qualquer status: ele grava `verified` só quando `exec.verify.status` é `verified`, senão `unverified`.

Por `status` do `result.json` persistido:

- **verified** → marque os critérios PASS como `[x]` na `spec.md`. Auto on: siga para `/complete`. Auto off: "Verificado. Fechar o ciclo? `/complete`".
- **unverified** → mostre `decision.reasons` e o que cada um pede: `QA_SKIPPED`/`CRITERIA_UNTESTED`/`NO_POSITIVE_EVIDENCE` → QA humano dos critérios listados; `G2_INCONCLUSIVE`/`G1_INCONCLUSIVE` → resolver ambiente (device, backend, credencial) e rodar de novo; `G2_MALFORMED`/`NO_CRITERIA` → o QA não devolveu critérios válidos, rode de novo; `G2_FAIL`/`G1_FAIL`/`CRITERIA_FAILED` sem findings → o gate reprovou sem dizer onde, rode de novo ou investigue; `REVISION_CHANGED`/`REVISION_UNBOUND` → o repo mudou durante o verify, rode de novo. Não marque nada na spec. Parada incondicional (`AskUserQuestion`, mesmo com auto on): rodar `/verify` de novo, ou seguir para `/complete` sabendo que ele só fecha com exceção humana.
- **blocked / backtrack** → mesmo tratamento do `/implement` (diagnosis ToT, protocolo de desvio), sempre como `AskUserQuestion` (parada incondicional, mesmo com auto on). Nunca decida sozinho.

Findings minor/nit dos reviewers: liste no fim como "não bloqueantes", sem abrir task.

Relatório: fim da etapa. Escreva com **Write** um resumo de 3 a 10 linhas em `$WF_DIR/.stage-summary.md` (nunca interpole texto em shell) e rode (acrescente `--status blocked` em tudo que não for `verified`):

```bash
python3 ~/.claude/bin/wf-report.py stage-end verify --workflow-dir "$WF_DIR" --summary-file "$WF_DIR/.stage-summary.md" || true
```
