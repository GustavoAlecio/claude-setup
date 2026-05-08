---
name: status
description: Mostra o estado atual do Fluxo Smart — qual etapa foi concluida, o que esta pendente e o proximo passo
---

## Detectar projeto

Primeiro, detecte o nome do projeto atual:
```bash
basename $(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

Use esse nome como `PROJECT_NAME`. O diretorio de workflow deste projeto e `~/.claude/workflow/PROJECT_NAME/`.

## Verificar estado

Verifique o estado atual do Fluxo Smart lendo os artefatos em `~/.claude/workflow/PROJECT_NAME/`:

1. Se o diretorio nao existir ou estiver vazio → fluxo nao iniciado
2. Se `spec.md` existir mas `plan.md` nao → spec gerada, aguardando aprovacao do plano
3. Se `plan.md` existir mas `tasks.md` nao → plano gerado, aguardando criacao das tasks
4. Se `tasks.md` existir → leia `tasks` do `current.json` para progresso detalhado (`tasks.items` com status por task)
5. Se todas tasks done e status e `"implemented"` → aguardando verificacao
6. Se status e `"verified"` → ciclo completo

Se `tasks.items` existir no `current.json`, exiba progresso por task:
- T1 — Titulo `[S]` done
- T2 — Titulo `[M]` in_progress ← current
- T3 — Titulo `[L]` pending

Se `current.json` existir, leia-o para mostrar informacoes adicionais (feature name, start_date, status, phases, tokens, backtracks).

## Verificar piloto automatico
```bash
test -f ~/.claude/workflow/auto_mode.flag && echo "AUTO: ativado" || echo "AUTO: desativado"
```

## Exibir resumo

Exiba um resumo no formato:

---
**Fluxo Smart — Estado atual**
**Projeto:** PROJECT_NAME
**Feature:** <nome da feature do current.json, se disponivel>
**Iniciado em:** <start_date do current.json, se disponivel>
**Piloto automatico:** ativado / desativado

- [x] Specify — `spec.md` gerada
- [x] Plan — `plan.md` gerado
- [x] Tasks — N tasks criadas (X concluidas, Y pendentes) | Complexidade: Ns S, Nm M, Nl L
- [ ] Implement — em andamento / pendente
- [ ] Verify — pendente

### Metricas

Se `tokens_used` > 0, exiba: **Total tokens acumulados:** N

Se o `current.json` tiver o campo `phases`, exiba timing por fase:

| Fase | Duracao |
|------|---------|
| specify | Xm |
| plan | Xm |
| tasks | Xm |
| implement | Xm |
| verify | Xm |

> Nota: `tokens_used` e gerenciado pelo `track-tokens.py` (Stop hook) — fonte unica de verdade para custos.

### Backtracks

Se `current.json` tiver o campo `backtracks`, liste:
- Task #ID: <reason> → <resolution>

### Lessons learned

Se `~/.claude/workflow/$PROJECT_NAME/lessons.md` existir, exiba contagem: "N lessons registradas (X arquitetura, Y testes, Z logica...)"

**Proximo passo:** <comando a executar e breve descricao>
---

Se nao houver nenhum artefato, informe que nenhum fluxo esta em andamento **neste projeto** e sugira comecar com `/specify`.

Tambem liste outros projetos que tenham workflows ativos:
```bash
ls ~/.claude/workflow/ 2>/dev/null
```
Se houver outros diretorios, mencione: "Ha tambem fluxos ativos em: [lista de projetos]".
