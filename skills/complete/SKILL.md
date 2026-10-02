---
name: complete
model: sonnet
description: Etapa final do Fluxo Smart — após verify aprovado, propõe ADRs, gera lessons a partir de falhas recorrentes, atualiza routing stats da escada, registra QA e dados reais no relatório, abre o PR atrás de um gate e arquiva o ciclo.
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
source ~/.claude/bin/get-project.sh
PROJECT_NAME=$(get-project-name)
WF_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
```

Leia `$WF_DIR/current.json`. Se `status` não for `"verified"`, pare e aponte `/verify`.

Relatório: início da etapa

```bash
python3 ~/.claude/bin/wf-report.py stage-start complete --workflow-dir "$WF_DIR" ${CLAUDE_FLOW_SESSION_ID:+--session "$CLAUDE_FLOW_SESSION_ID"} || true
```

## 2. Resumo do ciclo

A partir de `current.json` e `$WF_DIR/runs/*/result.json`:

```
## Ciclo: <feature>
- Tasks: N (S/M/L) · tentativas totais: X · escaladas: Y
- Tier final por task: T1 haiku, T2 haiku→sonnet, ...
- Verify: rodadas Z · critérios PASS/UNTESTABLE
- Custo aproximado: tokens de saída por papel (dev/g0/g1/g2) somados do trace
```

## 3. ADRs

Junte decisões candidatas:
- `adr_candidates` de `$WF_DIR/tot-plan.json` (se o plano foi via ToT);
- `decisions` de cada task nos `result.json`.

Invoque `/adr propose` com essa lista. Sem candidatas, pule.

Registre os ADRs propostos e as lessons gravadas. Registre como decisão do orquestrador (best-effort): escreva o texto com **Write** em `$WF_DIR/.decision.md` e rode (acrescente `--mistake` se for um erro seu):

```bash
python3 ~/.claude/bin/wf-report.py decision complete --workflow-dir "$WF_DIR" --by orchestrator --text-file "$WF_DIR/.decision.md" || true
```

## 4. Lessons

Leia os `trace.jsonl` dos runs do ciclo. Um finding vira lesson quando o **mesmo `rule_ref`** reprovou em 2+ tentativas (mesma task ou tasks diferentes) — foi o que custou escalada.

Para cada um, proponha 1 linha em `~/.claude/projects/$PROJECT_NAME/lessons.md`:
```
- [<categoria>] <regra no imperativo> — origem: <rule_ref>, <ciclo>
```
Se a lesson já é uma rule ou ADR existente, não duplique: sugira reforçar a rule. Peça OK antes de gravar (auto on: grave).

## 5. Routing

```bash
python3 ~/.claude/bin/routing-stats.py --project "$PROJECT_NAME" --write
```
Mostre a tabela e as sugestões de tier0 que mudaram.

## 6. Roteiro de QA

Junte os critérios `UNTESTABLE` do último verify (`$WF_DIR/runs/*/result.json`) e os itens "QA manual" da spec. Escreva um array JSON de strings com **Write** em `$WF_DIR/.qa.json` (array vazio se não houver) e rode:

```bash
python3 ~/.claude/bin/wf-report.py qa --workflow-dir "$WF_DIR" --file "$WF_DIR/.qa.json" || true
```

## 7. Teste com dados reais

Com a evidência de runtime do G2 do último verify, escreva um resumo em markdown com **Write** em `$WF_DIR/.real-data.md` e rode:

```bash
python3 ~/.claude/bin/wf-report.py real-data --workflow-dir "$WF_DIR" --file "$WF_DIR/.real-data.md" || true
```

Sem evidência de runtime: `python3 ~/.claude/bin/wf-report.py real-data --workflow-dir "$WF_DIR" --not-run || true`.

## 8. Gate `pr`

Apresente em 3-5 linhas o que o PR conterá (feature, tasks, ADRs propostos).

Gate `pr` (decisão determinística; nunca leia `gates.json`):

```bash
python3 ~/.claude/bin/wf-report.py gate pr
```

- `skip`: trate como Aprovar.
- `ask`: faça um `AskUserQuestion` ("Abrir o PR deste ciclo?") com as opções:
  - **Aprovar (Recommended)**: invoque `/pr-open --from-complete` (passe o `ado_id` do `current.json` se houver). A última linha do resultado é a URL do PR; grave-a:
    ```bash
    python3 ~/.claude/bin/wf-report.py pr --workflow-dir "$WF_DIR" --url "<URL>" || true
    ```
    Se o `/pr-open` parar (ex.: mudanças não commitadas), avise e repita este gate depois de o usuário resolver.
  - **Ajustar**: o usuário escreve o ajuste em Other; aplique o texto e repita este mesmo gate.
  - **Rejeitar**: siga sem PR; não grave `pr` no relatório.
- A resposta do usuário vira decisão: escreva-a com **Write** em `$WF_DIR/.decision.md` e rode `python3 ~/.claude/bin/wf-report.py decision complete --workflow-dir "$WF_DIR" --by user --text-file "$WF_DIR/.decision.md" || true`.

## 9. Fechar relatório

Relatório: fim da etapa. Escreva com **Write** um resumo de 3 a 10 linhas em `$WF_DIR/.stage-summary.md` (nunca interpole texto em shell) e rode:

```bash
python3 ~/.claude/bin/wf-report.py stage-end complete --workflow-dir "$WF_DIR" --summary-file "$WF_DIR/.stage-summary.md" || true
```

## 10. Arquivar

O archive copia o `report.json`, por isso vem depois do `stage-end`.

```bash
bash ~/.claude/bin/archive-cycle.sh completed "$PROJECT_NAME"
```
(O archive copia `runs/` para o histórico — o dashboard e o routing continuam lendo de lá.)

## 11. Próximo passo

"Ciclo concluído." Com PR aberto, acompanhe com `/pr-status`; sem PR, `/pr-open` abre depois (avulso, sem gravar relatório). Não commite aqui.
