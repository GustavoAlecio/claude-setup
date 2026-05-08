---
name: tasks
model: sonnet
description: Etapa 3 do Fluxo Smart — cria tasks ordenadas e atomicas baseadas no plano tecnico aprovado
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
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

## 5. Salvar tasks.md

Crie `~/.claude/workflow/$PROJECT_NAME/tasks.md` — **checklist com complexidade**:

```markdown
# Tasks: <Feature>

- [ ] `S` #ID — Titulo da task
- [ ] `M` #ID — Titulo da task
- [ ] `L` #ID — Titulo da task
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
    { "id": "T1", "title": "<titulo>", "complexity": "S|M|L", "status": "pending" },
    { "id": "T2", "title": "<titulo>", "complexity": "M", "status": "pending" }
  ]
}
```

Cada item deve ter o ID, titulo, complexidade e status `"pending"`.

## 7. Finalizar

Apresente resumo: "N tasks criadas (Xs S, Xm M, Xl L). Avancando para implementacao."

Avance automaticamente executando `/implement`.
