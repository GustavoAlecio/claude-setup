---
name: specify
model: sonnet
description: Etapa 1 do Fluxo Smart — analisa a descricao do usuario e gera documentacao de especificacao de negocio para validacao
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
```
Diretorio de workflow: `~/.claude/workflow/$PROJECT_NAME/`

## 2. Verificar estado do fluxo

**Caso A — spec.md ja existe (fluxo em andamento):**
Pare e pergunte: "Ja existe um fluxo em andamento em **PROJECT_NAME**. Continuar (`/status`) ou Resetar?"
- Continuar → encerre, sugira `/status`
- Resetar → delete `spec.md`, `plan.md`, `tasks.md`, `current.json` e prossiga

**Caso B — phases.md existe mas spec.md nao (continuacao de phases):**
Leia `~/.claude/workflow/$PROJECT_NAME/phases.md`, encontre a primeira phase com `[ ]` e prossiga gerando spec para ela.
Avise: "Continuando com **Phase N: <nome>** do escopo dividido."

**Caso C — nada existe:** prossiga normalmente.

## 3. Capturar metricas de inicio — EXECUTE AGORA
```bash
bash ~/.claude/bin/capture-metrics.sh start specify "$PROJECT_NAME" "$PROJECT_PATH"
```
Guarde o output como `STEP_START_TS`.

## 4. Reconhecimento do codebase

Antes de gerar a spec, entenda o ponto de partida:

1. **Ler convencoes do projeto:** verifique se existe `CLAUDE.md` na raiz do projeto e `DESIGN.md`. Se existirem, leia-os para entender padroes e restricoes.
2. **Estrutura relevante:** faca um `ls` dos diretorios mais provaveis de serem impactados pela feature descrita pelo usuario. Entenda o que ja existe.
3. **Estado atual:** se a feature envolve modificar algo existente, leia o codigo atual para entender o ponto de partida. Se e nova, identifique onde ela se encaixaria na arquitetura.

> O objetivo NAO e planejar a implementacao (isso e do `/plan`), mas sim garantir que a spec reflete a realidade do projeto — nao uma abstracao desconectada.

## 5. Avaliar escopo — QUEBRAR EM PHASES SE NECESSARIO

Aplique os criterios:

**Quebrar em phases se qualquer um for verdadeiro:**
- Envolve 3+ dominios tecnicos distintos (ex: backend + frontend + infra + banco + seguranca)
- Estimativa de mais de 10 tasks
- Contem multiplas features independentes que poderiam ser entregues separadamente
- Ha dependencias sequenciais claras que dividem naturalmente o trabalho

**Se decidir quebrar:**
1. Avise: "O escopo e grande. Vou dividi-lo em phases para garantir documentacao completa e implementacao assertiva."
2. Mostre o plano de phases proposto e aguarde confirmacao do usuario
3. Apos confirmacao, crie `~/.claude/workflow/$PROJECT_NAME/phases.md`:

```markdown
# Phases: <Nome do Projeto/Feature>

- [ ] Phase 1: <nome> — <1 linha descrevendo o que entra>
- [ ] Phase 2: <nome> — <1 linha descrevendo o que entra>
- [ ] Phase 3: <nome> — <1 linha descrevendo o que entra>
```

4. Informe: "Gerando spec completa para **Phase 1: <nome>**. As demais serao feitas em ciclos subsequentes."
5. Gere a spec apenas para a Phase 1

**Se nao precisar quebrar:** gere a spec normalmente.

## 6. Gerar especificacao

Gere a spec para o escopo atual (feature inteira ou phase atual).

**Documentacao deve ser COMPLETA e ASSERTIVA** — nao superficial. Use bullets concisos mas cubra todos os detalhes relevantes. Max 7 bullets por secao se necessario.

Salve em `~/.claude/workflow/$PROJECT_NAME/spec.md`:

```markdown
# Spec: <Nome da Feature> [Phase N: <nome> se aplicavel]

## Estado atual
- <o que ja existe no codebase relevante a feature>
- <componentes, telas, modulos que serao tocados ou reutilizados>
- <ou "Greenfield — nada existe ainda">

## Contexto
- <bullet com contexto real e relevante>

## Objetivo
- <bullet>

## Regras de negocio
- <bullet por regra identificada>

## Pontos de atencao
- <riscos, dependencias, restricoes reais>

## Criterios de aceite
- [ ] <criterio verificavel e especifico>

## Fora do escopo
- <o que NAO sera feito — importante para delimitar>
```

## 7. Capturar metricas finais — EXECUTE AGORA (obrigatorio)
```bash
bash ~/.claude/bin/capture-metrics.sh end specify "$PROJECT_NAME" "$PROJECT_PATH"
```

## 8. Salvar current.json

Crie `~/.claude/workflow/$PROJECT_NAME/current.json` (o script de metricas ja criou/atualizou as phases, mas o arquivo pode nao existir ainda no specify). Se o arquivo nao existir, crie-o:

```json
{
  "feature": "<nome 2-4 palavras, inclua 'Phase N' se aplicavel>",
  "project": "<PROJECT_NAME>",
  "project_path": "<PROJECT_PATH>",
  "start_date": "<STEP_START_TS>",
  "end_date": null,
  "status": "specifying",
  "tokens_used": 0,
  "blockers": [],
  "tags": [],
  "phases": {},
  "tasks": {
    "total": 0,
    "completed": 0,
    "current_task_id": null,
    "items": []
  },
  "backtracks": []
}
```

> **Nota:** `tokens_used` e `_sessions` sao gerenciados exclusivamente pelo `track-tokens.py` (Stop hook). Nunca escreva esses campos manualmente.

Depois rode o script de metricas end novamente se o current.json nao existia antes (para popular a fase specify).

## 9. Verificar piloto automatico e finalizar

```bash
test -f ~/.claude/workflow/auto_mode.flag && echo "AUTO_ON" || echo "AUTO_OFF"
```

- Se `AUTO_ON`: atualize `status` para `"spec_approved"` no `current.json`, apresente resumo da spec em 3-5 linhas e avance automaticamente executando `/plan`
- Se `AUTO_OFF`: finalize com "Spec gerada. Esta correta? Se sim: `/plan`"

> **Nota:** quando o usuario aprovar a spec (confirmando ou executando `/plan`), o `/plan` deve setar `status` para `"spec_approved"` antes de iniciar.
