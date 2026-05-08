---
name: verify
model: opus
description: Etapa 5 do Fluxo Smart — valida a implementacao contra os criterios de aceite da spec
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
```

## 2. Verificar pre-requisitos

Leia os 3 artefatos:
- `~/.claude/workflow/$PROJECT_NAME/spec.md` — fonte dos criterios de aceite
- `~/.claude/workflow/$PROJECT_NAME/plan.md` — estrategia de testes mapeada
- `~/.claude/workflow/$PROJECT_NAME/tasks.md` — confirmar que todas estao `[x]`

Se algum nao existir, informe qual etapa esta faltando.
Leia `~/.claude/workflow/$PROJECT_NAME/current.json` para contexto.

### Context budget
Da spec.md, leia apenas: "Criterios de aceite". Do plan.md, leia apenas: "Estrategia de testes (TDD)". Nao carregue artefatos inteiros — foque no que e necessario para validar.

Se houver tasks `[ ]` pendentes no tasks.md, avise: "Ha tasks pendentes. Execute `/implement` primeiro ou deseja verificar parcialmente?"

## 3. Capturar metricas de inicio — EXECUTE AGORA
```bash
bash ~/.claude/bin/capture-metrics.sh start verify "$PROJECT_NAME" "$PROJECT_PATH"
```

## 4. Executar testes mapeados

Leia a tabela "Estrategia de testes (TDD)" do plan.md. Para cada teste mapeado:

1. Verifique se o arquivo de teste existe
2. Se existir, execute-o
3. Registre: PASS ou FAIL + motivo

```bash
# Adapte ao projeto — ex:
# flutter test <path_to_test>
# npm test -- <path_to_test>
# pytest <path_to_test>
```

Se nao houver testes mapeados ou o projeto nao tiver suite de testes configurada, pule esta etapa e registre "Sem testes automatizados mapeados".

## 5. Validar criterios de aceite

Para cada criterio de aceite `[ ]` da spec.md:

1. **Localize a evidencia no codigo:** busque no codebase o trecho que implementa o criterio
2. **Avalie:** o codigo atende ao criterio? Leia o codigo real, nao assuma.
3. **Classifique:**
   - **PASS** — criterio atendido, com evidencia (arquivo:linha)
   - **PARTIAL** — parcialmente atendido, descreva o que falta
   - **FAIL** — nao atendido, descreva o gap
   - **UNTESTABLE** — nao e verificavel por inspecao de codigo (ex: requer teste manual de UI)

## 6. Verificar lessons learned

Se `~/.claude/workflow/$PROJECT_NAME/lessons.md` existir, leia-o e verifique: "alguma regra documentada foi violada nesta implementacao?"

Se sim, registre como FAIL adicional no relatorio com referencia a lesson violada.

## 7. Gerar relatorio de verificacao

Apresente o resultado:

```markdown
## Verificacao: <Feature>

### Criterios de aceite
| # | Criterio | Status | Evidencia |
|---|----------|--------|-----------|
| 1 | <criterio> | PASS/PARTIAL/FAIL/UNTESTABLE | <arquivo:linha ou motivo> |

### Testes automatizados
| Teste | Arquivo | Status |
|-------|---------|--------|
| <nome> | <path> | PASS/FAIL/NOT_FOUND |

### Lessons learned
- <Nenhuma violacao encontrada> ou <lesson violada: detalhes>

### Resultado
- **Criterios:** X/Y PASS, Z PARTIAL, W FAIL
- **Testes:** X/Y passando
- **Veredicto:** APROVADO / APROVADO COM RESSALVAS / REPROVADO
```

## 8. Acao baseada no resultado

**APROVADO (todos PASS ou UNTESTABLE):**
1. Marque todos os criterios como `[x]` na spec.md
2. Atualize `current.json` status para `"verified"`
3. Arquive o ciclo:
   ```bash
   bash ~/.claude/bin/archive-cycle.sh completed "$PROJECT_NAME"
   ```
4. Finalize: "Implementacao verificada e aprovada. Ciclo arquivado."

**APROVADO COM RESSALVAS (tem PARTIAL ou UNTESTABLE, mas nenhum FAIL):**
1. Marque os PASS como `[x]` na spec.md
2. Liste as ressalvas (PARTIAL e UNTESTABLE) para o usuario decidir
3. Pergunte: "Ha ressalvas. Deseja aprovar assim mesmo e arquivar, ou corrigir os pontos pendentes?"
   - Se aprovar → arquive
   - Se corrigir → liste o que precisa ser feito e sugira `/implement` com tasks complementares

**REPROVADO (tem FAIL):**
1. Liste todos os FAILs com detalhes
2. Proponha tasks de correcao para cada FAIL
3. Pergunte: "A verificacao encontrou gaps. Deseja que eu crie tasks de correcao e execute?"
   - Se sim → crie tasks complementares no tasks.md e execute como no `/implement`
   - Se nao → mantenha o estado para revisao manual

## 9. Capturar metricas finais — EXECUTE AGORA (obrigatorio)
```bash
bash ~/.claude/bin/capture-metrics.sh end verify "$PROJECT_NAME" "$PROJECT_PATH"
```
