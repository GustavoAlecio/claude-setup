---
name: refine
model: opus
description: Detalhamento tecnico standalone de uma tarefa — analisa contexto do projeto, entende a regra de negocio e refina os requisitos tecnicos. Nao faz parte do Fluxo Smart.
---

Skill standalone para refinamento tecnico de uma tarefa especifica. Diferente de `/specify` (spec de negocio) e `/plan` (plano de execucao do fluxo), aqui o foco e **traduzir uma necessidade descrita pelo usuario em um detalhamento tecnico fundamentado no codigo real**, sem gerar tasks nem entrar no pipeline.

## 0. Pre-requisitos

A entrada esperada e a descricao da tarefa nos argumentos da skill ou na ultima mensagem do usuario. Se a entrada estiver vaga ou faltar contexto critico, **pergunte antes de prosseguir** (1-3 perguntas objetivas).

Nao confunda escopo com `/specify` ou `/plan`:
- Se o usuario estiver claramente conduzindo o Fluxo Smart, sugira a skill correta e encerre.
- Esta skill nao le nem escreve `spec.md`, `plan.md`, `tasks.md`, `current.json`.

## 1. Detectar projeto

```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
source ~/.claude/bin/get-project.sh
PROJECT_NAME=$(get-project-name)
DETAILS_DIR="$HOME/.claude/workflow/$PROJECT_NAME/details"
mkdir -p "$DETAILS_DIR"
```

## 2. Reconhecimento do codebase (OBRIGATORIO)

Refine no concreto, nunca no abstrato. Antes de escrever uma linha do detalhamento:

1. **Convencoes:** leia `CLAUDE.md` do projeto (se existir) e `DESIGN.md` (se existir). Sao constraints, nao sugestoes.
2. **Estrutura relevante:** identifique os diretorios/arquivos mais provaveis de serem tocados pela tarefa. Faca `ls`/`tree` direcionado.
3. **Codigo existente:** leia os arquivos chave que a tarefa modifica ou se conecta. Patterns, abstracoes, contratos atuais.
4. **Reuso:** antes de propor algo novo, busque componente/servico/util similar via `grep`. Liste explicitamente o que da pra reaproveitar.
5. **Contratos:** se a tarefa toca APIs, models, eventos, interfaces — leia os contratos atuais para nao propor algo incompativel.

Se a busca for ampla (mais de ~3 queries), use o agent `Explore` em vez de poluir o contexto principal.

## 3. Entender a regra de negocio

O detalhamento tecnico sem entendimento de negocio vira lista de tarefas mecanicas. Antes de detalhar:

- **Qual e o problema real do usuario/produto?** Reformule com suas palavras.
- **Quais sao as regras de negocio implicitas?** (ex: "so usuarios com X podem Y", "se Z entao W")
- **Quais cenarios o usuario provavelmente nao mencionou?** (estados vazios, erro, concorrencia, offline, race condition no dominio)
- **Existe regra de negocio ja codificada que conflita com o pedido?** Aponte explicitamente.

Se algo de negocio estiver ambiguo, **pergunte agora** — nao adivinhe e siga.

## 4. Gerar o detalhamento tecnico

Crie o arquivo `$DETAILS_DIR/<slug>.md` onde:

```bash
SLUG="$(date +%Y%m%d-%H%M)-<titulo-em-kebab-case>"
```

O slug deve refletir a tarefa (ex: `20260525-1430-refresh-token-retry`).

### Estrutura do documento

```markdown
# <Titulo da tarefa>

> Gerado por /refine em <data>. Detalhamento tecnico standalone — nao e spec nem plan do Fluxo Smart.

## Contexto
- **O que o usuario pediu:** <descricao curta>
- **Problema de negocio:** <por que isso importa>
- **Estado atual do codigo:** <o que ja existe, com paths e arquivos relevantes>

## Regras de negocio
Lista das regras (explicitas e implicitas) que governam a tarefa. Cada regra como bullet objetiva.

## Escopo tecnico

### O que muda
- `path/para/arquivo.dart` — descricao da mudanca
- `path/para/outro.dart:linha` — descricao

### O que e criado
- Novos arquivos / classes / funcoes com responsabilidade de cada um.

### O que e reaproveitado
- Componentes/servicos existentes que ja resolvem parte da tarefa.

## Contratos e interfaces
- Mudancas em models, APIs, eventos, BLoC events/states, schemas.
- Compatibilidade com codigo existente (breaking change? feature flag?).

## Fluxos e estados
- Fluxo principal (happy path) — sequencia de eventos/chamadas.
- Estados intermediarios relevantes (loading, error, empty, partial).

## Edge cases tecnicos
- Concorrencia / race conditions
- Falhas de rede / timeout / retry
- Estados invalidos / null safety
- Permissoes / auth
- Performance / memoria / lista grande
- Offline / persistencia
- Concatenar so os que se aplicam — nao force.

## Riscos e trade-offs
- Decisoes arquiteturais locais com alternativas consideradas.
- Riscos conhecidos (regressao, escala, manutencao).

## Fora de escopo
- O que **nao** vai ser feito nessa tarefa, para evitar scope creep.

## Perguntas em aberto
- Itens de negocio ou tecnicos que precisam decisao antes de implementar.
```

Adapte as secoes ao escopo: tarefa pequena pode dispensar "Riscos" ou "Fluxos"; nao infle artificialmente.

## 5. Apresentar e parar

Apos gerar o arquivo:

1. Imprima o caminho absoluto do arquivo gerado.
2. Resuma em 3-5 bullets os pontos mais criticos do detalhamento (decisoes, riscos, perguntas em aberto).
3. **Pare.** Espere o usuario revisar. Nao chame outras skills, nao comece a implementar, nao gere tasks.

Se o usuario pedir ajustes apos a revisao, edite o arquivo no lugar — nao crie um novo slug.
