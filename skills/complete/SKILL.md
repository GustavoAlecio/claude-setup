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

### Guarda de encerramento (determinística)

```bash
python3 ~/.claude/bin/wf_gate.py complete-check --workflow-dir "$WF_DIR" --repo "$PROJECT_PATH"
```

Saída 0: siga (`human_override: true` quer dizer que o ciclo fecha por exceção humana, não como verificado; diga isso no resumo e no PR). Saída 1: mostre `reason_code` e pare antes de qualquer outro passo. O arquivamento do passo 10 roda a mesma guarda e recusa sem ela; não existe caminho alternativo.

- `REVISION_CHANGED` → o código mudou depois do verify: rode `/verify` de novo.
- `NO_VERIFY`, `VERIFY_RESULT_UNREADABLE`, `VERIFY_INCONSISTENT` ou qualquer razão do verify (`G2_FAIL`, `QA_SKIPPED`, `CRITERIA_UNTESTED`…) → `AskUserQuestion` (parada incondicional, mesmo com auto on) com:
  - **Rodar /verify de novo (Recommended)**.
  - **Encerrar sem verificação**: só com o motivo e os riscos escritos pelo usuário em Other. Rode `python3 ~/.claude/bin/wf_gate.py accept-unverified --workflow-dir "$WF_DIR" --repo "$PROJECT_PATH" --reason "<motivo>" --risk "<risco>" [--risk ...]`: abre um diálogo no Mac que só o usuário confirma. Cancelado ou expirado = recusa; não tente outra via. Confirmado → rode o `complete-check` de novo e siga.
  - **Manter bloqueado**: encerre o turno; o ciclo fica como está, sem perder artefatos.

Nunca escreva `exec.override` nem `exec.verify` à mão, e nunca trate uma resposta sua ou de subagente como autorização humana.

Relatório: início da etapa

```bash
python3 ~/.claude/bin/wf-report.py stage-start complete --workflow-dir "$WF_DIR" ${CLAUDE_FLOW_SESSION_ID:+--session "$CLAUDE_FLOW_SESSION_ID"} || true
```

### Reentrada do gate `pr`

```bash
python3 ~/.claude/bin/wf-report.py show pr --workflow-dir "$WF_DIR" || true
```

`"status":"revising"` → **reentrada**: o ciclo voltou de `/implement` → `/verify` para aplicar os pontos `change` da rodada anterior. Pule os passos 3 (ADRs), 4 (Lessons) e 5 (Routing), que já rodaram na primeira passada, e no passo 8 o gate grava a rodada seguinte. Qualquer outra saída é a primeira passada: siga todos os passos.

## 2. Resumo do ciclo

A partir de `current.json` e `$WF_DIR/runs/*/result.json`:

```
## Ciclo: <feature>
- Tasks: N (S/M/L) · tentativas totais: X · escaladas: Y
- Tier final por task: T1 haiku, T2 haiku→sonnet, ...
- Verify: rodadas Z · <verdict> · <reason_code> · critérios PASS/FAIL/PARTIAL/UNTESTABLE · revisão <revision_id[:12]> · human_override <true|false>
- Custo aproximado: tokens de saída por papel (dev/g0/g1/g2) somados do trace
```

## 3. ADRs

Junte decisões candidatas:
- `adr_candidates` de `$WF_DIR/tot-plan.json` (se o plano foi via ToT);
- `decisions` de cada task nos `result.json`.

Invoque `/adr propose` com essa lista. Sem candidatas, pule. Se `docs/adr` for submódulo, o propose grava as candidatas em `$WF_DIR/adr-candidates.md` (o `/pr-open` as anexa ao PR no passo de abertura) em vez de criar ADRs.

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

Apresente em 3-5 linhas o que o PR conterá (feature, tasks, ADRs propostos). Com `human_override`, o corpo do PR diz que o ciclo **não** foi verificado, com o motivo e os riscos aceitos.

Repo sem `remote.origin` (`git config --get remote.origin.url` vazio) → não há onde abrir PR: sem candidatas, sem crítico e sem brief. Siga sem PR, diga isso no resumo e pule este gate.

O gate pergunta só os pontos do diff que o usuário pode querer mudar, não a aprovação do PR inteiro. Nunca leia `gates.json` nem o `report.json`: o script decide e entrega a pergunta pronta.

### 8a. Diff e candidatas

Gere a árvore e o diff do ciclo em shell (nenhum hash é digitado):

```bash
bash ~/.claude/bin/wf-checkpoint.sh create "$PROJECT_PATH" > "$WF_DIR/pr.tree"
BASE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["exec"]["base_checkpoint"])' "$WF_DIR/current.json")
git -C "$PROJECT_PATH" diff --no-renames "$BASE" "$(cat "$WF_DIR/pr.tree")" > "$WF_DIR/pr.diff"
```

Escreva com **Write** em `$WF_DIR/.gate-pr.candidates.json` uma lista JSON de pontos a partir das `decisions` do relatório e dos achados menores do último verify (lista vazia, `[]`, se não houver). Cada ponto aponta o trecho do `pr.diff`:

```json
[{"id": "C1", "text": "<o ponto, em uma frase>", "why": "<por que o usuário deveria olhar>",
  "anchor": {"path": "<arquivo>", "start": 10, "end": 20},
  "options": [{"id": "ok", "label": "Está ok", "consequence": "Segue para o PR"},
              {"id": "change", "label": "Mudar", "consequence": "Vira task e o ciclo volta ao /implement"}],
  "assumed": "ok", "prefers": {"author": "ok"}}]
```

### 8b. Crítico

Spawne o agente `gate-critic` (Agent tool, `subagent_type: gate-critic`) com: gate `pr`, artefato `pr.diff` (em `$WF_DIR`), candidatas `$WF_DIR/.gate-pr.candidates.json` e saída `$WF_DIR/.gate-pr.json`. Na reentrada, diga também o que mudou desde a rodada anterior (as tasks `P*` implementadas), que vira `changes` (1 a 3 linhas). Não resuma o diff no prompt; ele lê.

### 8c. Brief

Sem `|| true`: a recusa é o sinal para o reenvio. O `--tree` vai por referência ao arquivo; o `base` o script lê do `current.json`.

```bash
python3 ~/.claude/bin/wf-report.py brief pr --workflow-dir "$WF_DIR" --file "$WF_DIR/.gate-pr.json" --candidates "$WF_DIR/.gate-pr.candidates.json" --tree "@$WF_DIR/pr.tree"
```

- Saída 0: siga ao gate.
- Saída 2 com `rodadas esgotadas` no stderr: vá para "Rodadas esgotadas" (8f).
- Outra saída 2: reenvie o stderr ao `gate-critic` uma única vez (mesmo prompt + o stderr) e rode o `brief` de novo. Na segunda recusa siga sem bloco: o gate devolve `ask` e você faz a pergunta única do ramo sem perguntas, avisando "resumo indisponível".

### 8d. Gate

```bash
python3 ~/.claude/bin/wf-report.py gate pr --workflow-dir "$WF_DIR"
```

Qualquer saída diferente de `skip` é `ask`. Nos dois casos leia o bloco pronto:

```bash
python3 ~/.claude/bin/wf-report.py show pr --workflow-dir "$WF_DIR"
```

O diff completo fica em `$WF_DIR/pr.diff` para quem quiser ler; não o exija.

- `skip`: imprima o `text_md` do `show` e a linha `Gate pr: passed, sem decisão em aberto`, e siga como em "Abrir o PR" abaixo. Se o `/pr-open` parar, siga sem PR e diga o motivo no resumo (`/pr-open` avulso abre depois); não espere o usuário.
- **`ask` com perguntas** (`questions` do `show` não vazio): imprima o `text_md` e faça um `AskUserQuestion` com as `questions` do `show` como vieram (`header`, `question`, `options` com `label`/`description`, `multiSelect: false`); não reescreva, não reordene e não marque recomendação, o script já resolveu. Para cada resposta, ache o `id` da opção (`ok` ou `change`) pelo `label` escolhido e grave:
  ```bash
  python3 ~/.claude/bin/wf-report.py answer pr --workflow-dir "$WF_DIR" --question <id da pergunta> --option ok
  ```
  Opção `change`: antes de gravar, pergunte ao usuário o que mudar naquele ponto (texto livre, citando a pergunta) e espere a resposta; ela vira o `O que fazer` da task. Escreva-a com **Write** em `$WF_DIR/.gate-answer.md` e grave opção e texto juntos (`reopen pr` recusa `change` sem texto):
  ```bash
  python3 ~/.claude/bin/wf-report.py answer pr --workflow-dir "$WF_DIR" --question <id da pergunta> --option change --text-file "$WF_DIR/.gate-answer.md"
  ```
  Texto livre (Other): escreva-o com **Write** em `$WF_DIR/.gate-answer.md` e troque `--option <id>` por `--text-file "$WF_DIR/.gate-answer.md"`. Depois rode o `show` de novo: `approved` → "Abrir o PR"; `revising` → o PR não abre: vá para "Ponto `change` no gate `pr`", depois do passo 10.
- **`ask` sem perguntas** (`questions` vazio, ou `{"status":"absent"}`): imprima o `text_md` (ou "resumo indisponível" sem bloco) e faça a pergunta única `AskUserQuestion` ("Abrir o PR deste ciclo?"):
  - **Aprovar (Recomendado)**: `answer pr --workflow-dir "$WF_DIR" --approve` e siga como em "Abrir o PR".
  - **Ajustar**: o usuário escreve o ajuste em Other; grave-o com **Write** em `$WF_DIR/.gate-answer.md`, rode `answer pr --workflow-dir "$WF_DIR" --text-file "$WF_DIR/.gate-answer.md"` (leva a `revising`) e vá para "Ponto `change` no gate `pr`", depois do passo 10.
  - **Rejeitar**: `answer pr --workflow-dir "$WF_DIR" --reject` e siga sem PR; não grave `pr` no relatório.
  - Sem bloco ("resumo indisponível") não há o que gravar com `answer`: Aprovar e Rejeitar seguem igual sem ele, e Ajustar aplica o texto e repete o gate desde 8a.
- Toda resposta do usuário também vira decisão: escreva-a com **Write** em `$WF_DIR/.decision.md` e rode `python3 ~/.claude/bin/wf-report.py decision complete --workflow-dir "$WF_DIR" --by user --text-file "$WF_DIR/.decision.md" || true`.

**Abrir o PR:** invoque `/pr-open --from-complete` (ele lê o card do `tracker` do `current.json`). A última linha do resultado é a URL do PR; grave-a:

```bash
python3 ~/.claude/bin/wf-report.py pr --workflow-dir "$WF_DIR" --url "<URL>" || true
```

Se o `/pr-open` parar (ex.: mudanças não commitadas) depois de uma resposta do usuário, avise e repita este gate depois de o usuário resolver.

### 8e. Revising

No gate `pr`, `revising` não revisa o diff aqui: os pontos `change` viram tasks na seção "Ponto `change` no gate `pr`" e a rodada seguinte é gravada na reentrada do `/complete`.

### 8f. Rodadas esgotadas

O `brief` recusou a quarta rodada. Faça um `AskUserQuestion` com:
- **Aprovar como está**: siga sem chamar o gate de novo e vá para "Abrir o PR".
- **Voltar à etapa anterior**: escreva o resumo em `$WF_DIR/.stage-summary.md` como no passo 9, rode `stage-end complete --status blocked` com esse `--summary-file` e indique `/verify`.
- **Abortar**: o mesmo `stage-end complete --status blocked`, sem PR e sem arquivar; encerre o turno.

A escolha vira `decision --by user` como acima.

## 9. Fechar relatório

Relatório: fim da etapa. Escreva com **Write** um resumo de 3 a 10 linhas em `$WF_DIR/.stage-summary.md` (nunca interpole texto em shell) e rode:

```bash
python3 ~/.claude/bin/wf-report.py stage-end complete --workflow-dir "$WF_DIR" --summary-file "$WF_DIR/.stage-summary.md" || true
```

## 10. Arquivar

O archive copia o `report.json`, por isso vem depois do `stage-end`. Ele reroda o `complete-check`; se o repo mudou desde o passo 1 (ex.: commit do `/pr-open` com autofix), ele recusa: rode `/verify` de novo.

```bash
bash ~/.claude/bin/archive-cycle.sh completed "$PROJECT_NAME"
```
(O archive copia `runs/` para o histórico — o dashboard e o routing continuam lendo de lá.)

## 11. Próximo passo

"Ciclo concluído." Com PR aberto, acompanhe com `/pr-status`; sem PR, `/pr-open` abre depois (avulso, sem gravar relatório). Não commite aqui.

## Ponto `change` no gate `pr`

Só se chega aqui pelo passo 8 com o bloco `pr` em `revising`; os passos 9 e 10 não rodam. O PR não abre e o ciclo volta à implementação, sem passar pelo `smart-verify.js`.

1. Transforme cada resposta diferente de `ok` em task `P<rodada>.<n>` (determinístico e idempotente; grava `current.json` e `tasks.md`):
   ```bash
   python3 ~/.claude/bin/wf-report.py reopen pr --workflow-dir "$WF_DIR"
   ```
   Saída 2 porque o único ajuste é o texto livre do ramo sem perguntas (sem âncora para virar task): mostre o texto ao usuário e indique `/fix` com ele antes de `/verify` → `/complete`.
   Saída 2 com `resposta change sem texto do ajuste em <ids>`: pergunte ao usuário o que mudar em cada id citado, grave com `answer pr --question <id> --option change --text-file "$WF_DIR/.gate-answer.md"` como no passo 8d e rode o `reopen pr` de novo.
2. Escreva com **Write** em `$WF_DIR/.stage-summary.md` quais pontos voltaram para implementação e rode `stage-end complete --status blocked` com esse `--summary-file`.
3. Encerre o turno indicando `/implement` → `/verify` → `/complete`. Na volta, o `/complete` detecta a reentrada (`show pr` em `revising`) e grava a rodada seguinte no passo 8.
