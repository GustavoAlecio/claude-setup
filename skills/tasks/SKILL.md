---
name: tasks
model: sonnet
description: Etapa 3 do Fluxo Smart — cria tasks ordenadas e atomicas baseadas no plano tecnico aprovado
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
source ~/.claude/bin/get-project.sh
PROJECT_NAME=$(get-project-name)
WF_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
```

## 2. Verificar pre-requisito

Leia `~/.claude/workflow/$PROJECT_NAME/plan.md`. Se nao existir, peca `/plan` primeiro.
Leia `~/.claude/workflow/$PROJECT_NAME/current.json` para contexto.

> Nao leia spec.md — o plan.md ja contem o contexto necessario.

### Context budget
Se o `plan.md` tiver mais de 200 linhas, leia apenas: "Visao geral", "Arquivos impactados", "Ordem de execucao" e "Estrategia de testes". Ignore secoes verbose como reconhecimento de codebase.

## 3. Marcar plano como aprovado e capturar metricas

Atualize `status` para `"plan_approved"` no `current.json` (gate de aprovacao implicito — o usuario invocou `/tasks`).

```bash
bash ~/.claude/bin/capture-metrics.sh start tasks "$PROJECT_NAME" "$PROJECT_PATH"
```
Guarde o output como `STEP_START_TS`.

Relatório: início da etapa

```bash
python3 ~/.claude/bin/wf-report.py stage-start tasks --workflow-dir "$WF_DIR" ${CLAUDE_FLOW_SESSION_ID:+--session "$CLAUDE_FLOW_SESSION_ID"} || true
```

## 4. Criar tasks

Use `TaskCreate` para cada unidade de trabalho. Regras:
- 1 responsabilidade por task
- Ordenadas por dependencia (infra → feature → testes); `depends_on` lista os ids anteriores de que a task depende
- Cada task termina com seus testes passando: o G0 roda os `tests` da task e reprova teste vermelho. TDD acontece **dentro** da task (escreve o teste, ve falhar, implementa, ve passar). Nunca crie task cujo resultado seja teste falhando (Red-only) seguida de outra que o faz passar: junte as duas
- Task so de teste e valida quando o teste passa ao fim dela (regressao de bug ja corrigido, cobertura de codigo existente)
- Titulo objetivo, descricao no formato de 4 blocos (ver `description` abaixo)

**Estimativa de complexidade por task:**
Classifique cada task como:
- **S** (small) — 1 arquivo, mudanca pontual, sem logica complexa
- **M** (medium) — 2-3 arquivos, logica moderada, pode envolver integracao
- **L** (large) — 4+ arquivos, logica complexa, multiplas dependencias

Baseie a classificacao na tabela "Arquivos impactados" do plano e no tipo de mudanca.

**Campos que a escada de modelos consome** (o `/implement` recusa task sem eles):
- `affects` — paths/globs que a task deve tocar (da tabela "Arquivos impactados"). Usado no G1 e no match de ADRs.
- `tests` — arquivos de teste da task (da tabela "Estrategia de testes"), relativos ao repo. O G0 roda exatamente esses e todos precisam passar ao fim da task. Teste novo precisa estar no `affects` desta task ou de uma anterior. Task sem teste aplicavel: `[]`.
- `risk` — `high` se mexe em contrato (API, gRPC, WebSocket, schema), estado compartilhado/real-time, auth/assinatura, migracao, ou codigo citado por ADR; senao `low`.
- `tier0` — modelo inicial: `S→haiku`, `M→sonnet`, `L→opus`. `risk: high` sobe um degrau (max `opus`). Override aprendido: se `~/.claude/projects/$PROJECT_NAME/routing.json` tiver `overrides["<S|M|L>:<low|high>"].tier0`, ele vence — diga quando aplicar.
- `description` — autocontida (o dev-implementer le o plano, mas nao le esta conversa), com **exatamente 4 blocos nesta ordem**, separados por uma linha em branco:
  - `**Contexto:** ...` — 1-2 linhas, com ponteiros para plano/spec (secoes, passo do plano).
  - `**O que fazer:**` + bullets — o que mudar e onde.
  - `**Testes:**` + bullets — os arquivos de teste (ou o comando, se nao houver teste novo).
  - `**Concluído quando:**` + bullets verificaveis.

**Restricoes do renderer do app** (ele so entende paragrafo, `- `, `**negrito**` e `` `codigo` ``):
- bullets so `- ` na coluna 0; sem aninhar e sem lista numerada
- sem blocos de codigo cercados, cabecalhos, tabelas ou links
- paths, simbolos e comandos entre crases simples, sem crase interna

Exemplo literal de `description` (e a fixture do teste de renderizacao do app):

```markdown
**Contexto:** Passo 2 do plano.

**O que fazer:**
- Criar `lib/x.dart`

**Testes:**
- `test/x_test.dart`

**Concluído quando:**
- `flutter analyze` limpo
```

No `current.json` a string vai com `\n` nas quebras de linha (ver exemplo do passo 6).

## 5. Salvar tasks.md

Crie `~/.claude/workflow/$PROJECT_NAME/tasks.md` — **checklist com complexidade**:

```markdown
# Tasks: <Feature>

- [ ] `S` `haiku` #ID — Titulo da task
- [ ] `M` `sonnet` #ID — Titulo da task
- [ ] `L` `opus` #ID — Titulo da task
```

## 6. Capturar metricas finais — EXECUTE AGORA (obrigatorio)
```bash
bash ~/.claude/bin/capture-metrics.sh end tasks "$PROJECT_NAME" "$PROJECT_PATH"
```

Atualize o objeto `tasks` no `current.json`:

```json
"tasks": {
  "total": <numero total de tasks>,
  "completed": 0,
  "current_task_id": null,
  "items": [
    {
      "id": "T1", "title": "<titulo>", "description": "**Contexto:** Passo 2 do plano.\n\n**O que fazer:**\n- Criar `lib/x.dart`\n\n**Testes:**\n- `test/x_test.dart`\n\n**Concluído quando:**\n- `flutter analyze` limpo",
      "complexity": "S", "risk": "low", "tier0": "haiku", "tier": "haiku", "attempts": 0,
      "affects": ["lib/features/auth/bloc/**"], "tests": ["test/features/auth/auth_bloc_test.dart"],
      "status": "pending"
    }
  ]
}
```

Cada item deve ter todos os campos acima; `tier` comeca igual a `tier0` e e a escada que o altera.

### Validar o plano (obrigatorio, deterministico)

```bash
python3 ~/.claude/bin/wf_gate.py tasks-check --workflow-dir "$WF_DIR" --repo "$PROJECT_PATH"
```

Saida 1 lista erros por task (`RED_ONLY`, `TEST_NOT_PRODUCED`, `BAD_DEPENDENCY`, `DESCRIPTION_BLOCKS`, `MISSING_FIELD`). Corrija as tasks (no `current.json` e no `tasks.md`) e rode de novo ate sair 0. Nao siga para o gate com erro.

Relatório: fim da etapa. Escreva com **Write** um resumo de 3 a 10 linhas em `$WF_DIR/.stage-summary.md` (nunca interpole texto em shell) e rode:

```bash
python3 ~/.claude/bin/wf-report.py stage-end tasks --workflow-dir "$WF_DIR" --summary-file "$WF_DIR/.stage-summary.md" || true
```

## 7. Gate `tasks`

Apresente o resumo: "N tasks criadas (Xs S, Xm M, Xl L) · tier0: Xh haiku, Ys sonnet, Zo opus · K de risco alto."

O gate pergunta só as decisões em aberto das tasks, não a aprovação do documento. Nunca leia `gates.json` nem o `report.json`: o script decide e entrega a pergunta pronta.

### 7a. Candidatas

Escreva com **Write** em `$WF_DIR/.gate-tasks.candidates.json` uma lista JSON com as escolhas da quebra em tasks que o usuário pode querer mudar (recorte ou ordem com alternativa real, task de risco alto que poderia ser dividida, override de `tier0` aplicado). Lista vazia (`[]`) se não houver:

```json
[{"id": "C1", "text": "<a decisão, em uma frase>",
  "options": [{"id": "a", "label": "<curto>", "consequence": "<o que muda>"}, {"id": "b", "label": "...", "consequence": "..."}],
  "assumed": "a", "prefers": {"author": "a"}}]
```

`assumed` é a opção que o `tasks.md` já assume.

### 7b. Crítico

Spawne o agente `gate-critic` (Agent tool, `subagent_type: gate-critic`) com: gate `tasks`, artefato `tasks.md` (em `$WF_DIR`; as descrições completas estão em `tasks.items` do `current.json`), candidatas `$WF_DIR/.gate-tasks.candidates.json` e saída `$WF_DIR/.gate-tasks.json`. Não resuma as tasks no prompt; ele lê.

### 7c. Brief

Sem `|| true`: a recusa é o sinal para o reenvio.

```bash
python3 ~/.claude/bin/wf-report.py brief tasks --workflow-dir "$WF_DIR" --file "$WF_DIR/.gate-tasks.json" --candidates "$WF_DIR/.gate-tasks.candidates.json"
```

- Saída 0: siga ao gate.
- Saída 2 com `rodadas esgotadas` no stderr: vá para "Rodadas esgotadas" (7f).
- Outra saída 2: reenvie o stderr ao `gate-critic` uma única vez (mesmo prompt + o stderr) e rode o `brief` de novo. Na segunda recusa siga sem bloco: o gate devolve `ask` e você faz a pergunta única do ramo sem perguntas, avisando "resumo indisponível".

### 7d. Gate

```bash
python3 ~/.claude/bin/wf-report.py gate tasks --workflow-dir "$WF_DIR"
```

Qualquer saída diferente de `skip` é `ask`. Nos dois casos leia o bloco pronto:

```bash
python3 ~/.claude/bin/wf-report.py show tasks --workflow-dir "$WF_DIR"
```

- `skip`: imprima o `text_md` do `show` e a linha `Gate tasks: passed, sem decisão em aberto` e execute `/implement`.
- **`ask` com perguntas** (`questions` do `show` não vazio): imprima o `text_md` e faça um `AskUserQuestion` com as `questions` do `show` como vieram (`header`, `question`, `options` com `label`/`description`, `multiSelect: false`); não reescreva, não reordene e não marque recomendação, o script já resolveu. Para cada resposta, ache o `id` da opção pelo `label` escolhido e grave:
  ```bash
  python3 ~/.claude/bin/wf-report.py answer tasks --workflow-dir "$WF_DIR" --question <id da pergunta> --option <id da opção>
  ```
  Texto livre (Other): escreva-o com **Write** em `$WF_DIR/.gate-answer.md` e troque `--option <id>` por `--text-file "$WF_DIR/.gate-answer.md"`. Depois rode o `show` de novo: `approved` → execute `/implement`; `revising` → 7e.
- **`ask` sem perguntas** (`questions` vazio, ou `{"status":"absent"}`): imprima o `text_md` (ou "resumo indisponível" sem bloco) e faça a pergunta única `AskUserQuestion` ("Tasks aprovadas para implementar?"):
  - **Aprovar (Recomendado)**: `answer tasks --workflow-dir "$WF_DIR" --approve` e execute `/implement` na mesma sessão.
  - **Ajustar**: o usuário escreve o ajuste em Other; grave-o com **Write** em `$WF_DIR/.gate-answer.md`, rode `answer tasks --workflow-dir "$WF_DIR" --text-file "$WF_DIR/.gate-answer.md"` (leva a `revising`) e siga para 7e.
  - **Rejeitar**: `answer tasks --workflow-dir "$WF_DIR" --reject`, rode `stage-end tasks --status blocked` (mesmo `--summary-file`), mantenha o `status` do `current.json` e encerre o turno.
  - Sem bloco ("resumo indisponível") não há o que gravar com `answer`: Aprovar e Rejeitar seguem igual sem ele, e Ajustar aplica o texto nas tasks (`current.json` e `tasks.md`, rodando o `tasks-check` de novo) e repete o gate desde 7a.
- Toda resposta do usuário também vira decisão: escreva-a com **Write** em `$WF_DIR/.decision.md` e rode `python3 ~/.claude/bin/wf-report.py decision tasks --workflow-dir "$WF_DIR" --by user --text-file "$WF_DIR/.decision.md" || true`.

### 7e. Revising

Revise as tasks (`current.json` e `tasks.md`, com o `tasks-check` saindo 0) com as respostas (opções diferentes de `assumed` e textos livres), reescreva as candidatas (7a) e chame o `gate-critic` (7b) dizendo o que mudou desde a rodada anterior, que vira `changes` (1 a 3 linhas). Rode o `brief` (7c), que grava a rodada seguinte, e o gate (7d) de novo.

### 7f. Rodadas esgotadas

O `brief` recusou a quarta rodada. Faça um `AskUserQuestion` com:
- **Aprovar como está**: siga sem chamar o gate de novo e execute `/implement`.
- **Voltar à etapa anterior**: rode `stage-end tasks --status blocked` (mesmo `--summary-file`) e indique `/plan` para rever o plano.
- **Abortar**: rode `stage-end tasks --status blocked` e encerre o turno.

A escolha vira `decision --by user` como acima.
