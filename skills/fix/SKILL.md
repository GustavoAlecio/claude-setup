---
name: fix
model: opus
description: Fluxo leve para bugs — investiga, diagnostica, corrige e verifica sem o pipeline completo de 5 etapas
---

## 1. Detectar projeto
```bash
PROJECT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
```

## 2. Consultar lessons learned

Se `~/.claude/projects/$PROJECT_NAME/lessons.md` existir, leia-o. O mesmo padrao de bug pode ja ter sido corrigido antes — aplique a regra existente.

## 3. Investigar

Dado o bug report do usuario, investigue autonomamente:

1. **Reproduzir mentalmente:** entenda o cenario descrito
2. **Localizar codigo relevante:** busque no codebase os arquivos, funcoes e fluxos envolvidos
3. **Ler logs/stack traces:** se o usuario forneceu, analise-os. Se nao, busque em arquivos de log do projeto
4. **Testes falhando:** execute a suite de testes para confirmar o que falha

> Regra: nao pergunte o que pode ser obtido do codigo ou dos logs. Investigue primeiro.

## 4. Diagnosticar

Identifique a **root cause** (nao o sintoma). Apresente o diagnostico em 2-3 linhas antes de corrigir:

```
**Diagnostico:** <o que esta errado e por que>
**Root cause:** <causa raiz no codigo — arquivo:linha>
**Impacto:** <N arquivos afetados>
```

### Avaliar complexidade

- **Se o fix afeta <= 3 arquivos e nao exige decisao arquitetural:** prossiga com o fix
- **Se o fix afeta > 3 arquivos ou exige mudanca arquitetural:** pare e avise:
  "Este bug e sintoma de um problema maior. Recomendo escalar para o Fluxo Smart (`/specify`) para tratar adequadamente."
  Aguarde decisao do usuario.

## 5. Corrigir

Aplique o fix com a menor superficie de mudanca possivel:

1. **Se nao existe teste para o cenario:** crie um teste que reproduz o bug ANTES do fix (Red)
2. **Aplique a correcao:** fix minimal e direto
3. **Confirme que o teste passa** (Green)
4. **Execute testes existentes** para garantir que nada quebrou

Regras:
- Fix no root cause, nao no sintoma
- Nao refatore codigo adjacente — foque apenas no bug
- Nao adicione features junto com o fix

## 6. Verificar

```bash
# Execute testes relevantes — adapte ao projeto:
# flutter test <path>
# npm test -- <path>
# pytest <path>
```

Apresente o resultado:

```
**Fix aplicado:**
- **Arquivo(s):** <lista de arquivos modificados>
- **Teste:** <nome do teste> — PASS
- **Regressao:** N testes existentes — todos PASS (ou detalhe falhas)
```

## 7. Registrar lesson (se aplicavel)

Se o bug revela um padrao que pode se repetir, registre em `~/.claude/projects/$PROJECT_NAME/lessons.md`:

```markdown
### <data> — <categoria>
**Erro:** <padrao que causou o bug>
**Correcao:** <o que foi feito>
**Regra:** <regra preventiva para o futuro>
```

Crie o arquivo se nao existir.

## 8. Finalizar

Apresente resumo do fix. Nao arquive ciclo (fix nao gera artefatos de workflow).
