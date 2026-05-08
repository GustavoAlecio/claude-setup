---
name: implement
model: opus
description: Etapa 4 do Fluxo Smart — executa as tasks em ordem, seguindo o plano tecnico aprovado
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
```

## 2. Verificar pre-requisitos e detectar retomada

Leia `~/.claude/workflow/$PROJECT_NAME/plan.md` e `~/.claude/workflow/$PROJECT_NAME/tasks.md`. Se algum nao existir, informe qual etapa esta faltando.
Leia `~/.claude/workflow/$PROJECT_NAME/current.json` para contexto.

> Nao leia spec.md — plan.md ja contem o contexto suficiente.

### Checkpointing — retomar de onde parou

Verifique `tasks.items` no `current.json`. Se houver tasks com status `"done"`:

1. **Pule tasks ja concluidas** — nao re-execute
2. Se houver uma task com status `"in_progress"` (`tasks.current_task_id` preenchido):
   - Verifique no codigo se a implementacao foi parcial (arquivos criados/editados mas incompletos)
   - Se completa → marque como `"done"` e avance
   - Se parcial → retome do ponto onde parou
   - Se nenhuma evidencia → comece a task do zero
3. Avise: "Retomando implementacao — N tasks ja concluidas, continuando a partir de Task #ID"

Apenas tasks com status `"pending"` ou `"in_progress"` serao executadas.

### Context budget
Se o `plan.md` tiver mais de 200 linhas, leia apenas: "Visao geral", "Arquivos impactados", "Ordem de execucao" e "Estrategia de testes". Use o `tasks.md` como guia primario — ele ja referencia as secoes relevantes do plano.

## 3. Consultar lessons learned

Se `~/.claude/workflow/$PROJECT_NAME/lessons.md` existir, leia-o. Aplique as regras como constraints durante a implementacao. Se uma task pode repetir um erro documentado, evite-o proativamente.

## 4. Capturar metricas de inicio — EXECUTE AGORA
```bash
bash ~/.claude/bin/capture-metrics.sh start implement "$PROJECT_NAME" "$PROJECT_PATH"
```
Guarde o output como `STEP_START_TS`.

## 5. Registrar estado git inicial
```bash
git rev-parse HEAD
```
Guarde como `GIT_START_SHA` — sera usado no resumo de impacto.

## 6. Executar tasks

Liste tasks pendentes com `TaskList`. Execute na ordem do `tasks.md`.

Para cada task:
1. Anuncie: "**Task #ID — Titulo** `[S/M/L]`"
2. Atualize `current.json`: set `tasks.current_task_id` para o ID da task e `tasks.items[n].status` para `"in_progress"`
3. Implemente seguindo o `plan.md`
4. **Validacao imediata:** se a task tem teste mapeado na tabela "Estrategia de testes (TDD)" do `plan.md`, execute-o agora. Registre resultado no `tasks.items[n]`:
   ```json
   { "id": "T2", "status": "done", "test_result": "pass" }
   ```
   - Se o teste falhar (`"test_result": "fail"`), corrija antes de avancar
   - Se nao ha teste mapeado, registre `"test_result": "no_test"`
5. Atualize status com `TaskUpdate`
6. Marque `[x]` no `tasks.md`
7. Atualize `current.json`: set `tasks.items[n].status` para `"done"` e incremente `tasks.completed`
8. Resumo de 1 linha do que foi feito

### Protocolo de desvio (backtrack)

Se durante a implementacao voce encontrar algo que invalida o plano:

1. **Pare a execucao** — nao force uma implementacao que nao faz sentido
2. **Documente o problema:** descreva claramente o que encontrou e por que o plano e inviavel nesse ponto
3. **Proponha a correcao:** sugira o ajuste necessario no plan.md (e na spec.md se for o caso)
4. **Aguarde aprovacao:** pergunte "Encontrei um desvio necessario. Posso atualizar o plano e continuar?"
5. **Se aprovado:** atualize os artefatos, registre em `current.json` no campo `backtracks`:
   ```json
   "backtracks": [{"task": "#ID", "reason": "...", "resolution": "..."}]
   ```
6. **Se rejeitado:** siga com o plano original ou pare conforme o usuario decidir

Regras gerais:
- Nunca desvie do plano sem consultar o usuario
- Pause se encontrar algo inesperado
- Aguarde confirmacao para tasks com risco alto

## 7. Resumo de impacto — EXECUTE AGORA

Apos todas as tasks:

```bash
git diff --stat <GIT_START_SHA>..HEAD
```

Se alguma task teve `test_result: "no_test"`, execute a suite de testes completa do projeto como safety net:
```bash
# Adapte ao projeto — ex: flutter test, npm test, etc.
```

Apresente o resumo:
```
## Resumo de impacto
- **Arquivos criados:** N
- **Arquivos editados:** N
- **Arquivos removidos:** N
- **Testes por task:** X pass / Y fail / Z sem teste
- **Suite completa:** PASS/FAIL/nao executada
- **Feature:** <nome> implementada
```

## 8. Capturar metricas finais — EXECUTE AGORA (obrigatorio)
```bash
bash ~/.claude/bin/capture-metrics.sh end implement "$PROJECT_NAME" "$PROJECT_PATH"
```

Atualize `current.json`: set `tasks.current_task_id` para `null` e `status` para `"implemented"`.

## 9. Verificar phases pendentes

Verifique se `~/.claude/workflow/$PROJECT_NAME/phases.md` existe.

**Se existir:**
1. Marque a phase recem-concluida como `[x]`
2. Verifique se ainda ha phases com `[ ]`:
   - **Sim, ha phases pendentes:** exiba o resumo e pergunte:
     "Phase N concluida! Phases restantes:
     - [ ] Phase N+1: <nome>

     Deseja verificar a implementacao? Execute `/verify`.
     Ou iniciar a proxima phase? Execute `/specify`."
   - **Nao, todas concluidas:** delete `phases.md` e informe que o projeto foi implementado por completo.

**Se nao existir:** avance automaticamente executando `/verify`.
