---
name: plan
model: opus
description: Etapa 2 do Fluxo Smart — gera plano tecnico detalhado baseado na especificacao aprovada
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
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

## 4. Reconhecimento do codebase (OBRIGATORIO)

Antes de planejar, explore o codigo real. Nao planeje no vacuo.

1. **Convencoes do projeto:** leia `CLAUDE.md` do projeto (se existir) e `DESIGN.md` (se existir). Esses documentos definem padroes obrigatorios.
2. **Arquitetura existente:** explore os diretorios e arquivos mencionados na secao "Estado atual" da spec. Leia os arquivos-chave para entender patterns, abstracoes e convencoes do codebase.
3. **Componentes reutilizaveis:** antes de propor criar algo novo, busque se ja existe componente similar no projeto (grep por nomes, patterns, widgets, services). Liste o que pode ser reutilizado.
4. **Contratos existentes:** se a feature toca APIs, models, ou interfaces existentes, leia-os para entender os contratos atuais.

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
```

## 8. Capturar metricas finais — EXECUTE AGORA (obrigatorio)
```bash
bash ~/.claude/bin/capture-metrics.sh end plan "$PROJECT_NAME" "$PROJECT_PATH"
```

## 9. Verificar piloto automatico e finalizar

```bash
test -f ~/.claude/workflow/auto_mode.flag && echo "AUTO_ON" || echo "AUTO_OFF"
```

- Se `AUTO_ON`: atualize `status` para `"plan_approved"` no `current.json`, apresente resumo do plano em 3-5 linhas e avance automaticamente executando `/tasks`
- Se `AUTO_OFF`: finalize com "Plano gerado. Esta ok? Se sim: `/tasks`"

> **Nota:** quando o usuario aprovar o plano (confirmando ou executando `/tasks`), o `/tasks` deve setar `status` para `"plan_approved"` antes de iniciar.
