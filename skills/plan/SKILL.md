---
name: plan
model: opus
description: Etapa 2 do Fluxo Smart — gera plano tecnico detalhado baseado na especificacao aprovada
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
source ~/.claude/bin/get-project.sh
PROJECT_NAME=$(get-project-name)
WF_DIR="$HOME/.claude/workflow/$PROJECT_NAME"
```

## 2. Verificar pre-requisito

Leia `~/.claude/workflow/$PROJECT_NAME/spec.md`. Se nao existir, peca `/specify` primeiro.
Leia `~/.claude/workflow/$PROJECT_NAME/current.json` para contexto do ciclo.

## 3. Marcar spec como aprovada e capturar metricas

Atualize `status` para `"spec_approved"` no `current.json` (a aprovação da spec é o gate `spec` do `/challenge-spec`, ou a invocação direta do `/plan`).

```bash
bash ~/.claude/bin/capture-metrics.sh start plan "$PROJECT_NAME" "$PROJECT_PATH"
```
Guarde o output como `STEP_START_TS`.

Relatório: início da etapa

```bash
python3 ~/.claude/bin/wf-report.py stage-start plan --workflow-dir "$WF_DIR" ${CLAUDE_FLOW_SESSION_ID:+--session "$CLAUDE_FLOW_SESSION_ID"} || true
```

## 4. Reconhecimento do codebase (OBRIGATORIO)

Antes de planejar, explore o codigo real. Nao planeje no vacuo.

1. **Convencoes do projeto:** leia `CLAUDE.md` do projeto (se existir) e `DESIGN.md` (se existir). Esses documentos definem padroes obrigatorios. **Mapa da org:** se existir `.map/index.md` no repo ou numa pasta acima (nunca procure abaixo), leia o índice e as notas/gerados relevantes antes de grep/`Explore`. Nota marcada STALE não é confiável: confira as âncoras. O mapa descreve `origin/development`; confira o diff da branch por cima.
2. **Arquitetura existente:** explore os diretorios e arquivos mencionados na secao "Estado atual" da spec. Leia os arquivos-chave para entender patterns, abstracoes e convencoes do codebase.
3. **Componentes reutilizaveis:** antes de propor criar algo novo, busque se ja existe componente similar no projeto (grep por nomes, patterns, widgets, services). Liste o que pode ser reutilizado.
4. **Contratos existentes:** se a feature toca APIs, models, ou interfaces existentes, leia-os para entender os contratos atuais.
5. **Rules e ADRs:** leia `.claude/rules/` do repo (as que casam com os paths prováveis) e rode `python3 ~/.claude/bin/adr-index.py match "$PROJECT_PATH" <arquivos prováveis>`. ADR `accepted` é restrição do plano; contrariar um exige propor supersede (`/adr supersede`), não ignorar.

> O plano deve ser fundamentado no codigo real, nao em suposicoes.

## 5. Consultar lessons learned

Se `~/.claude/projects/$PROJECT_NAME/lessons.md` existir, leia-o e aplique as regras como constraints do plano. Erros documentados nao devem ser repetidos.

> Lessons sao cross-cycle (propriedade do projeto, nao do ciclo). Por isso vivem em `projects/`, nao em `workflow/` — sobrevivem ao `archive-cycle.sh`.

## 6. Verificar coerencia com a spec (backtrack check)

Apos explorar o codebase, verifique se a spec ainda faz sentido:

- **A spec assume algo que nao existe no codigo?** (ex: menciona um componente que foi removido)
- **Faltam regras de negocio que ficaram evidentes ao ler o codigo?**
- **Algum criterio de aceite e inviavel dado o estado atual?**

**Se encontrar gaps:**
1. Liste os gaps encontrados claramente
2. Proponha as correcoes necessarias na spec
3. Pergunte: "Encontrei gaps na spec apos analisar o codebase. Posso atualizar a spec com as correcoes acima antes de prosseguir?"
4. Se aprovado, atualize `spec.md` e continue
5. Se rejeitado, siga com a spec original

Se a spec foi atualizada por gaps do código, registre quais. Registre como decisão do orquestrador (best-effort): escreva o texto com **Write** em `$WF_DIR/.decision.md` e rode (acrescente `--mistake` se for um erro seu):

```bash
python3 ~/.claude/bin/wf-report.py decision plan --workflow-dir "$WF_DIR" --by orchestrator --text-file "$WF_DIR/.decision.md" || true
```

## 6b. Modo ToT (Tree of Thoughts orquestrado)

Use o workflow `tot-plan` em vez de planejar sozinho quando **qualquer** um valer:
- usuário passou `--tot`;
- mudança de contrato (API, gRPC, WebSocket, schema, evento) ou novo módulo/package;
- estimativa > 8 arquivos impactados;
- a spec pede uma decisão estrutural que merece ADR (estado, cache, sincronização real-time, navegação).

Sem gatilho, siga para a seção 7. Com gatilho, anuncie em 1 linha ("Plano via ToT: <motivo>") e chame a ferramenta **Workflow** com `name: "tot-plan"` e `args`:
```json
{ "project_path": "<PROJECT_PATH>", "spec_path": "<WF_DIR>/spec.md", "plan_path": "<WF_DIR>/plan.md",
  "rules_dir": ".claude/rules", "adr_dir": "docs/adr", "lessons_path": "<se existir>" }
```
Ao receber o resultado: grave-o inteiro em `$WF_DIR/tot-plan.json` (o `/complete` usa os `adr_candidates`; o resto é a trilha de auditoria dos juízes). Mostre em até 5 linhas:
- vencedor + placar por ângulo (+ `tie_break` se houver);
- por juiz: escolha, nº de afirmações verificadas / refutadas (`agreement.claims_checked` / `claims_refuted`);
- concordância: `same_winner` e o maior `total_spread`;
- enxertos: aplicados / sugeridos (`grafts_applied`);
- se `degraded`, diga o motivo (juiz faltando, `scored_all: false` ou `invalid_scores`) — o placar ficou menos confiável.

A visão agregada entre ciclos (os juízes valem o custo?) sai de `python3 ~/.claude/bin/tot-stats.py [--project NAME] [--list]`.

Confira que o `plan.md` segue o template abaixo e pule para a seção 8.

## 7. Gerar plano tecnico

Crie `~/.claude/workflow/$PROJECT_NAME/plan.md` com exatamente este formato — **seja conciso, max 5 items por secao**:

```markdown
# Plano: <Nome da Feature>

## Visao geral
<1-2 frases sobre abordagem>

## Componentes reutilizados
- <componente existente> — <como sera usado>
- <ou "Nenhum — tudo sera criado do zero">

## Arquivos impactados
| Arquivo | Acao | Motivo |
|---------|------|--------|
| path/arquivo.ts | criar/editar/remover | motivo |

## Mudancas de contrato
- <APIs, schemas, tipos alterados — ou "Nenhum">

## Breaking changes
- <ou "Nenhum">

## Ordem de execucao
1. <passo>

## Riscos
- <risco>: <mitigacao>

## Estrategia de testes (TDD)
| Criterio de aceite | Teste | Arquivo |
|--------------------|-------|---------|
| <da spec> | <describe/it> | <path> |

## Decisoes
- <decisao> — segue [[NNNN-adr]] | nova (candidata a ADR): <alternativas descartadas>
- <ou "Nenhuma decisao estrutural">
```

Os paths da "Estrategia de testes" viram o campo `tests` das tasks e são executados literalmente pelo G0 — use caminhos reais relativos ao repo.

## 8. Capturar metricas finais — EXECUTE AGORA (obrigatorio)
```bash
bash ~/.claude/bin/capture-metrics.sh end plan "$PROJECT_NAME" "$PROJECT_PATH"
```

Relatório: fim da etapa. Escreva com **Write** um resumo de 3 a 10 linhas em `$WF_DIR/.stage-summary.md` (nunca interpole texto em shell) e rode:

```bash
python3 ~/.claude/bin/wf-report.py stage-end plan --workflow-dir "$WF_DIR" --summary-file "$WF_DIR/.stage-summary.md" || true
```

## 9. Gate `plan`

Apresente o resumo do plano em 3-5 linhas.

O gate pergunta só as decisões em aberto do plano, não a aprovação do documento. Nunca leia `gates.json` nem o `report.json`: o script decide e entrega a pergunta pronta.

### 9a. Candidatas

Escreva com **Write** em `$WF_DIR/.gate-plan.candidates.json` uma lista JSON com as escolhas do plano que o usuário pode querer mudar (decisões da seção "Decisoes" com alternativa real, riscos cuja mitigação depende de preferência, desvios declarados da spec). Lista vazia (`[]`) se não houver:

```json
[{"id": "C1", "text": "<a decisão, em uma frase>",
  "options": [{"id": "a", "label": "<curto>", "consequence": "<o que muda>"}, {"id": "b", "label": "...", "consequence": "..."}],
  "assumed": "a", "prefers": {"author": "a"}}]
```

`assumed` é a opção que o `plan.md` já assume.

Mapa de arquitetura: só quando a tabela "Arquivos impactados" do `plan.md` tem ao menos uma linha, escreva também com **Write** o rascunho do mapa em `$WF_DIR/.gate-plan.map.json`, derivado do `plan.md` atual (nunca de uma rodada anterior). Tabela vazia: não há rascunho nesta rodada.

```json
{"summary": "<o desenho em uma frase>",
 "nodes": [{"id": "n1", "label": "<nome da peça>", "state": "new", "note": "<papel da peça>", "paths": ["bin/x.py"]}],
 "edges": [{"from": "n1", "to": "n2", "label": "<o que passa>"}],
 "approaches": [{"id": "a1", "label": "<forma de fazer>", "text": "<como seria>", "chosen": true}],
 "gains": ["<o que a escolhida ganha>"], "costs": ["<do que abre mão>"],
 "ignore": ["tests/**"]}
```

- `nodes`: peças que agrupam os arquivos da tabela por papel, não um nó por arquivo; `state` `new` (peça criada), `changed` (peça que muda) ou `existing` (já existe e só é usada). Peça `new` ou `changed` leva `paths`: 1 a 6 globs relativos à raiz do repo (`*` não atravessa `/`, `**` atravessa, `x/` cobre a pasta), sem `./`, `..` nem `\`, que casam os arquivos dela na tabela. `id` único, sem o prefixo `unplanned:`.
- `approaches`: a forma escolhida (`chosen: true`) e até duas alternativas descartadas da seção "Decisoes"; `gains` e `costs` da escolhida, até 3 cada.
- `ignore`: testes, fixtures e arquivos gerados que não são peça.

### 9b. Crítico

Spawne o agente `gate-critic` (Agent tool, `subagent_type: gate-critic`) com: gate `plan`, artefato `plan.md` (em `$WF_DIR`), candidatas `$WF_DIR/.gate-plan.candidates.json`, rascunho do mapa `$WF_DIR/.gate-plan.map.json` (só se você o escreveu nesta rodada) e saída `$WF_DIR/.gate-plan.json`. Não resuma o plano no prompt; ele lê.

### 9c. Brief

Sem `|| true`: a recusa é o sinal para o reenvio.

```bash
python3 ~/.claude/bin/wf-report.py brief plan --workflow-dir "$WF_DIR" --file "$WF_DIR/.gate-plan.json" --candidates "$WF_DIR/.gate-plan.candidates.json"
```

- Saída 0: siga ao gate.
- Saída 2 com `rodadas esgotadas` no stderr: vá para "Rodadas esgotadas" (9f).
- Outra saída 2: reenvie o stderr ao `gate-critic` uma única vez (mesmo prompt + o stderr) e rode o `brief` de novo. Na segunda recusa:
  - stderr começando com `wf-report: map`: rode o `brief` uma terceira vez, sem o mapa, e avise "mapa indisponível". Saída 0 segue ao gate; outra recusa segue sem bloco, como abaixo.
    ```bash
    python3 ~/.claude/bin/wf-report.py brief plan --workflow-dir "$WF_DIR" --file "$WF_DIR/.gate-plan.json" --candidates "$WF_DIR/.gate-plan.candidates.json" --drop-map
    ```
  - qualquer outra recusa: siga sem bloco. O gate devolve `ask` e você faz a pergunta única do ramo sem perguntas, avisando "resumo indisponível".

### 9d. Gate

```bash
python3 ~/.claude/bin/wf-report.py gate plan --workflow-dir "$WF_DIR"
```

Qualquer saída diferente de `skip` é `ask`. Nos dois casos leia o bloco pronto:

```bash
python3 ~/.claude/bin/wf-report.py show plan --workflow-dir "$WF_DIR"
```

- `skip`: imprima o `text_md` do `show` e a linha `Gate plan: passed, sem decisão em aberto`; atualize `status` para `"plan_approved"` no `current.json` e execute `/tasks`.
- **`ask` com perguntas** (`questions` do `show` não vazio): imprima o `text_md` e faça um `AskUserQuestion` com as `questions` do `show` como vieram (`header`, `question`, `options` com `label`/`description`, `multiSelect: false`); não reescreva, não reordene e não marque recomendação, o script já resolveu. Para cada resposta, ache o `id` da opção pelo `label` escolhido e grave:
  ```bash
  python3 ~/.claude/bin/wf-report.py answer plan --workflow-dir "$WF_DIR" --question <id da pergunta> --option <id da opção>
  ```
  Texto livre (Other): escreva-o com **Write** em `$WF_DIR/.gate-answer.md` e troque `--option <id>` por `--text-file "$WF_DIR/.gate-answer.md"`. Depois rode o `show` de novo: `approved` → atualize `status` para `"plan_approved"` e execute `/tasks`; `revising` → 9e.
- **`ask` sem perguntas** (`questions` vazio, ou `{"status":"absent"}`): imprima o `text_md` (ou "resumo indisponível" sem bloco) e faça a pergunta única `AskUserQuestion` ("Plano aprovado para gerar as tasks?"):
  - **Aprovar (Recomendado)**: `answer plan --workflow-dir "$WF_DIR" --approve`, atualize `status` para `"plan_approved"` no `current.json` e execute `/tasks` na mesma sessão.
  - **Ajustar**: o usuário escreve o ajuste em Other; grave-o com **Write** em `$WF_DIR/.gate-answer.md`, rode `answer plan --workflow-dir "$WF_DIR" --text-file "$WF_DIR/.gate-answer.md"` (leva a `revising`) e siga para 9e.
  - **Rejeitar**: `answer plan --workflow-dir "$WF_DIR" --reject`, rode `stage-end plan --status blocked` (mesmo `--summary-file`), mantenha o `status` do `current.json` e encerre o turno.
  - Sem bloco ("resumo indisponível") não há o que gravar com `answer`: Aprovar e Rejeitar seguem igual sem ele, e Ajustar aplica o texto no `plan.md` e repete o gate desde 9a.
- Toda resposta do usuário também vira decisão: escreva-a com **Write** em `$WF_DIR/.decision.md` e rode `python3 ~/.claude/bin/wf-report.py decision plan --workflow-dir "$WF_DIR" --by user --text-file "$WF_DIR/.decision.md" || true`.

### 9e. Revising

Revise o `plan.md` com as respostas (opções diferentes de `assumed` e textos livres), reescreva as candidatas e o rascunho do mapa `$WF_DIR/.gate-plan.map.json` a partir do `plan.md` revisado (9a) e chame o `gate-critic` (9b) dizendo o que mudou desde a rodada anterior, que vira `changes` (1 a 3 linhas). Rode o `brief` (9c), que grava a rodada seguinte, e o gate (9d) de novo.

### 9f. Rodadas esgotadas

O `brief` recusou a quarta rodada. Faça um `AskUserQuestion` com:
- **Aprovar como está**: siga sem chamar o gate de novo; atualize `status` para `"plan_approved"` e execute `/tasks`.
- **Voltar à etapa anterior**: rode `stage-end plan --status blocked` (mesmo `--summary-file`) e indique `/challenge-spec` para rever a spec.
- **Abortar**: rode `stage-end plan --status blocked` e encerre o turno.

A escolha vira `decision --by user` como acima.

> **Nota:** quando o usuario aprovar o plano (confirmando ou executando `/tasks`), o `/tasks` deve setar `status` para `"plan_approved"` antes de iniciar.
