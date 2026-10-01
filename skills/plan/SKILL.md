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

Atualize `status` para `"spec_approved"` no `current.json` (gate de aprovacao implicito — o usuario invocou `/plan`).

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

1. **Convencoes do projeto:** leia `CLAUDE.md` do projeto (se existir) e `DESIGN.md` (se existir). Esses documentos definem padroes obrigatorios.
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
Ao receber o resultado: grave-o em `$WF_DIR/tot-plan.json` (o `/complete` usa os `adr_candidates`), mostre vencedor + placar + enxertos em 3 linhas, confira que o `plan.md` segue o template abaixo e pule para a seção 8.

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

## 9. Verificar piloto automatico e finalizar

```bash
test -f ~/.claude/workflow/auto_mode.flag && echo "AUTO_ON" || echo "AUTO_OFF"
```

- Se `AUTO_ON`: atualize `status` para `"plan_approved"` no `current.json`, apresente resumo do plano em 3-5 linhas e avance automaticamente executando `/tasks`
- Se `AUTO_OFF`: finalize com "Plano gerado. Esta ok? Se sim: `/tasks`"

> **Nota:** quando o usuario aprovar o plano (confirmando ou executando `/tasks`), o `/tasks` deve setar `status` para `"plan_approved"` antes de iniciar.
