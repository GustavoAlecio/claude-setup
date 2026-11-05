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

## 4. Criar tasks

Use `TaskCreate` para cada unidade de trabalho. Regras:
- 1 responsabilidade por task
- Ordenadas por dependencia (infra → feature → testes)
- Se TDD: task de teste (Red) antes da task de implementacao (Green)
- Titulo objetivo, descricao com: o que + onde + criterio de conclusao

**Estimativa de complexidade por task:**
Classifique cada task como:
- **S** (small) — 1 arquivo, mudanca pontual, sem logica complexa
- **M** (medium) — 2-3 arquivos, logica moderada, pode envolver integracao
- **L** (large) — 4+ arquivos, logica complexa, multiplas dependencias

Baseie a classificacao na tabela "Arquivos impactados" do plano e no tipo de mudanca.

**Campos que a escada de modelos consome** (o `/implement` recusa task sem eles):
- `affects` — paths/globs que a task deve tocar (da tabela "Arquivos impactados"). Usado no G1 e no match de ADRs.
- `tests` — arquivos de teste da task (da tabela "Estrategia de testes"), relativos ao repo. O G0 roda exatamente esses. Task de teste (Red) lista o proprio teste; task Green lista o teste que deve passar. Task sem teste aplicavel: `[]`.
- `risk` — `high` se mexe em contrato (API, gRPC, WebSocket, schema), estado compartilhado/real-time, auth/assinatura, migracao, ou codigo citado por ADR; senao `low`.
- `tier0` — modelo inicial: `S→haiku`, `M→sonnet`, `L→opus`. `risk: high` sobe um degrau (max `opus`). Override aprendido: se `~/.claude/projects/$PROJECT_NAME/routing.json` tiver `overrides["<S|M|L>:<low|high>"].tier0`, ele vence — diga quando aplicar.
- `description` — o que + onde + criterio de conclusao, autocontido: o dev-implementer le o plano, mas nao le esta conversa.

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
      "id": "T1", "title": "<titulo>", "description": "<o que + onde + criterio>",
      "complexity": "S", "risk": "low", "tier0": "haiku", "tier": "haiku", "attempts": 0,
      "affects": ["lib/features/auth/bloc/**"], "tests": ["test/features/auth/auth_bloc_test.dart"],
      "status": "pending"
    }
  ]
}
```

Cada item deve ter todos os campos acima; `tier` comeca igual a `tier0` e e a escada que o altera.

## 7. Verificar piloto automatico e finalizar

```bash
test -f ~/.claude/workflow/auto_mode.flag && echo "AUTO_ON" || echo "AUTO_OFF"
```

Apresente o resumo: "N tasks criadas (Xs S, Xm M, Xl L) · tier0: Xh haiku, Ys sonnet, Zo opus · K de risco alto."

- Se `AUTO_ON`: avance automaticamente executando `/implement`.
- Se `AUTO_OFF`: **pare** e finalize com "Tasks criadas. Seguir para implementacao? Se sim: `/implement`".

> Este gate existe pelo mesmo motivo do `/specify` e do `/plan`: `/implement`
> escreve codigo. Encadear sem OK com auto off era inconsistente com as outras
> etapas do fluxo.
