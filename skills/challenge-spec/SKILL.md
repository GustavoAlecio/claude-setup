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

Spawne o subagent `spec-challenger` (Agent tool, `subagent_type: spec-challenger`) com: caminho da spec, `PROJECT_PATH`, e o caminho de `docs/adr/INDEX.md`, `.claude/rules/` do repo e do mapa da org (`.map/index.md` no repo ou numa pasta acima) se existirem. Não resuma a spec no prompt — ele lê.

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

O gate pergunta só as decisões em aberto da spec, não a aprovação do documento. Nunca leia `gates.json` nem o `report.json`: o script decide e entrega a pergunta pronta.

### 5a. Candidatas

Escreva com **Write** em `$WF_DIR/.gate-spec.candidates.json` uma lista JSON com os achados do `spec-challenger` que não foram aplicados e as escolhas que a spec deixa em aberto. Lista vazia (`[]`) se não houver:

```json
[{"id": "C1", "text": "<a decisão, em uma frase>",
  "options": [{"id": "a", "label": "<curto>", "consequence": "<o que muda>"}, {"id": "b", "label": "...", "consequence": "..."}],
  "assumed": "a", "prefers": {"author": "a"}}]
```

`assumed` é a opção que a `spec.md` já assume (para um achado não aplicado, manter a spec como está).

### 5b. Crítico

Spawne o agente `gate-critic` (Agent tool, `subagent_type: gate-critic`) com: gate `spec`, artefato `spec.md` (em `$WF_DIR`, já com os ajustes aplicados), os achados do `spec-challenger` em `$WF_DIR/.findings.json` como fonte dos `risks` (`source: challenger:<id>`), candidatas `$WF_DIR/.gate-spec.candidates.json` e saída `$WF_DIR/.gate-spec.json`. Não resuma a spec no prompt; ele lê.

### 5c. Brief

Sem `|| true`: a recusa é o sinal para o reenvio.

```bash
python3 ~/.claude/bin/wf-report.py brief spec --workflow-dir "$WF_DIR" --file "$WF_DIR/.gate-spec.json" --candidates "$WF_DIR/.gate-spec.candidates.json"
```

- Saída 0: siga ao gate.
- Saída 2 com `rodadas esgotadas` no stderr: vá para "Rodadas esgotadas" (5f).
- Outra saída 2: reenvie o stderr ao `gate-critic` uma única vez (mesmo prompt + o stderr) e rode o `brief` de novo. Na segunda recusa siga sem bloco: o gate devolve `ask` e você faz a pergunta única do ramo sem perguntas, avisando "resumo indisponível".

### 5d. Gate

```bash
python3 ~/.claude/bin/wf-report.py gate spec --workflow-dir "$WF_DIR"
```

Qualquer saída diferente de `skip` é `ask`. Nos dois casos leia o bloco pronto:

```bash
python3 ~/.claude/bin/wf-report.py show spec --workflow-dir "$WF_DIR"
```

- `skip`: imprima o `text_md` do `show` e a linha `Gate spec: passed, sem decisão em aberto`; atualize `status` para `"spec_approved"` no `current.json` e execute `/plan`.
- **`ask` com perguntas** (`questions` do `show` não vazio): imprima o `text_md` e faça um `AskUserQuestion` com as `questions` do `show` como vieram (`header`, `question`, `options` com `label`/`description`, `multiSelect: false`); não reescreva, não reordene e não marque recomendação, o script já resolveu. Para cada resposta, ache o `id` da opção pelo `label` escolhido e grave:
  ```bash
  python3 ~/.claude/bin/wf-report.py answer spec --workflow-dir "$WF_DIR" --question <id da pergunta> --option <id da opção>
  ```
  Texto livre (Other): escreva-o com **Write** em `$WF_DIR/.gate-answer.md` e troque `--option <id>` por `--text-file "$WF_DIR/.gate-answer.md"`. Depois rode o `show` de novo: `approved` → atualize `status` para `"spec_approved"` e execute `/plan`; `revising` → 5e.
- **`ask` sem perguntas** (`questions` vazio, ou `{"status":"absent"}`): imprima o `text_md` (ou "resumo indisponível" sem bloco) e faça a pergunta única `AskUserQuestion` ("Spec aprovada para planejar?"):
  - **Aprovar (Recomendado)**: `answer spec --workflow-dir "$WF_DIR" --approve`, atualize `status` para `"spec_approved"` no `current.json` e execute `/plan` na mesma sessão.
  - **Ajustar**: o usuário escreve o ajuste em Other; grave-o com **Write** em `$WF_DIR/.gate-answer.md`, rode `answer spec --workflow-dir "$WF_DIR" --text-file "$WF_DIR/.gate-answer.md"` (leva a `revising`) e siga para 5e.
  - **Rejeitar**: `answer spec --workflow-dir "$WF_DIR" --reject`, rode `stage-end challenge --status blocked` (mesmo `--summary-file`), mantenha o `status` do `current.json` e encerre o turno.
  - Sem bloco ("resumo indisponível") não há o que gravar com `answer`: Aprovar e Rejeitar seguem igual sem ele, e Ajustar aplica o texto na `spec.md` e repete o gate desde 5a.
- Toda resposta do usuário também vira decisão: escreva-a com **Write** em `$WF_DIR/.decision.md` e rode `python3 ~/.claude/bin/wf-report.py decision challenge --workflow-dir "$WF_DIR" --by user --text-file "$WF_DIR/.decision.md" || true`.

### 5e. Revising

Revise a `spec.md` com as respostas (opções diferentes de `assumed` e textos livres), reescreva as candidatas (5a) e chame o `gate-critic` (5b) dizendo o que mudou desde a rodada anterior, que vira `changes` (1 a 3 linhas). Rode o `brief` (5c), que grava a rodada seguinte, e o gate (5d) de novo.

### 5f. Rodadas esgotadas

O `brief` recusou a quarta rodada. Faça um `AskUserQuestion` com:
- **Aprovar como está**: siga sem chamar o gate de novo; atualize `status` para `"spec_approved"` e execute `/plan`.
- **Voltar à etapa anterior**: rode `stage-end challenge --status blocked` (mesmo `--summary-file`) e indique `/specify` para refazer a spec.
- **Abortar**: rode `stage-end challenge --status blocked` e encerre o turno.

A escolha vira `decision --by user` como acima.
