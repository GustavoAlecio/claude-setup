---
name: orcamento
description: Gera uma proposta comercial (orçamento) da sua empresa (definida em company.json) em Markdown, HTML e PDF, a partir de uma conversa guiada com o usuário.
---

# /orcamento — Gerador de propostas comerciais

Conduz uma conversa para coletar os dados de um novo orçamento e gera três artefatos:
`orcamento.md`, `orcamento.html` e `orcamento.pdf` em `~/orcamentos/<cliente-slug>-<YYYY-MM-DD>/`.

Os dados fixos da empresa (CNPJ, endereço, contato, sócios, valor/hora, logo) vivem em
`~/.claude/skills/orcamento/company.json` (crie a partir de `company.example.json`). O template visual vive em `template.html`.

---

## 1. Carregar dados da empresa

```bash
SKILL_DIR="$HOME/.claude/skills/orcamento"
cat "$SKILL_DIR/company.json"
```

Leia o JSON. Se algum campo crítico estiver `null` (ex: `dados_bancarios`), você pode
seguir e omitir essa seção, ou perguntar ao usuário se quer preencher agora (a critério dele).

## 2. Conversa de coleta

Pergunte ao usuário, **em uma ou duas rodadas**, agrupando perguntas com `AskUserQuestion`
quando fizer sentido. Não faça interrogatório longo — peça em texto livre quando o campo é
descritivo.

Campos a coletar:

**Bloco A — identificação**
- Nome do cliente (pessoa/empresa)
- Nome do projeto
- Apresentação curta (1 parágrafo descrevendo a empresa/contexto da proposta) — você pode
  propor um texto padrão e o usuário ajusta
- Objetivo do projeto (1 parágrafo)
- Validade da proposta (default: 15 dias a partir de hoje)

**Bloco B — escopo**
- Lista de módulos/entregas. Para cada um: `nome`, `descricao`, `horas` (estimativa)
- Aceitar input em texto livre e estruturar você mesmo

**Bloco C — cronograma**
- Lista de fases. Para cada uma: `nome` (ex: "Fase 1 — Discovery"), `atividades`,
  `duracao` (ex: "2 semanas")
- Prazo total (calculado ou informado)

**Bloco D — investimento**
- Valor/hora (default: o `valor_hora_padrao` do company.json — confirmar)
- Desconto (opcional — valor absoluto ou %)
- Condições de pagamento (ex: "30% no início, 40% em milestone X, 30% na entrega")

**Bloco E — premissas & exclusões**
- Lista de premissas (ex: "cliente fornecerá acessos a APIs externas em até 5 dias úteis")
- Lista de itens fora do escopo (ex: "infraestrutura de produção", "design de marca")

**Dica:** se o usuário disser "monta um exemplo" ou for vago, **proponha** valores
plausíveis baseados no projeto descrito e peça confirmação — não fique pingando perguntas.

## 3. Calcular totais

- `total_horas` = soma das horas dos módulos
- `subtotal` = `total_horas * valor_hora`
- `total` = `subtotal - desconto` (se houver)
- Formatar todos os valores como `R$ X.XXX,XX` (locale pt-BR)

## 4. Preparar diretório de saída

```bash
CLIENTE_SLUG=$(echo "$CLIENTE_NOME" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
DATA_HOJE=$(date +%Y-%m-%d)
OUT_DIR="$HOME/orcamentos/${CLIENTE_SLUG}-${DATA_HOJE}"
mkdir -p "$OUT_DIR"
```

Número da proposta: `<SIGLA>-YYYY-MM-NN` onde `NN` é sequencial dentro do mês. Calcule
contando pastas existentes do mês:
```bash
MES=$(date +%Y-%m)
SEQ=$(printf "%02d" $(($(find "$HOME/orcamentos" -maxdepth 1 -type d -name "*-${MES}-*" 2>/dev/null | wc -l) + 1)))
PROPOSTA_NUMERO="<SIGLA>-${MES}-${SEQ}"
```

## 5. Gerar Markdown

Escreva `$OUT_DIR/orcamento.md` com a estrutura completa da proposta (mesmas 7 seções
do template HTML). Markdown é a fonte humanamente editável.

## 6. Gerar HTML

Leia `template.html`, substitua todos os placeholders `{{VAR}}` pelos valores coletados/calculados.

Placeholders a substituir:
- `{{CLIENTE_NOME}}`, `{{PROJETO_NOME}}`, `{{PROPOSTA_NUMERO}}`
- `{{DATA_EMISSAO}}` (dd/mm/yyyy), `{{DATA_EMISSAO_EXTENSO}}` ("19 de maio de 2026"), `{{VALIDADE}}`
- `{{CIDADE_EMISSAO}}` = "Cuiabá - MT"
- `{{APRESENTACAO}}`, `{{OBJETIVO}}`
- `{{ESCOPO_ROWS}}` → linhas `<tr><td>nome</td><td>descricao</td><td class="num">Xh</td></tr>`
- `{{CRONOGRAMA_ROWS}}` → linhas `<tr><td>Fase N</td><td>atividades</td><td class="num">duracao</td></tr>`
- `{{TOTAL_HORAS}}`, `{{VALOR_HORA}}`, `{{SUBTOTAL}}`, `{{TOTAL}}`, `{{PRAZO_TOTAL}}`
- `{{DESCONTO_ROW}}` → `<tr><td>Desconto</td><td class="num">-R$ X</td></tr>` ou string vazia
- `{{CONDICOES_PAGAMENTO}}` (pode conter `<p>` ou `<ul>`)
- `{{PREMISSAS}}` e `{{EXCLUSOES}}` → `<li>...</li>` concatenados
- `{{COR_PRIMARIA}}`, `{{COR_SECUNDARIA}}` (do company.json)
- `{{LOGO_PATH}}` → use o caminho absoluto do logo (`$SKILL_DIR/assets/logo_preta.jpg` para
  fundo claro). No header da capa o fundo é colorido, então use **logo_preta** apenas se
  for a versão com fundo branco; para a capa em gradiente, gere uma versão branca por
  CSS ou use texto com a sigla da empresa estilizado. Por simplicidade, use `logo_preta.jpg` e adicione
  `filter: brightness(0) invert(1);` inline no `<img>` se quiser invertê-lo. Use o caminho
  absoluto via `file://$SKILL_DIR/assets/logo_preta.jpg`.
- `{{RAZAO_SOCIAL}}`, `{{NOME_FANTASIA}}`, `{{CNPJ}}`, `{{ENDERECO_COMPLETO}}`,
  `{{EMAIL}}`, `{{TELEFONE}}`, `{{SITE}}`, `{{RESPONSAVEL_TECNICO}}`

Salve em `$OUT_DIR/orcamento.html`.

## 7. Gerar PDF via Chrome headless

```bash
CHROME=""
for candidate in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"; do
  [ -x "$candidate" ] && CHROME="$candidate" && break
done

if [ -z "$CHROME" ]; then
  echo "Chrome não encontrado — gerei MD e HTML. Abra o HTML no browser e use 'Imprimir → Salvar em PDF'."
else
  "$CHROME" --headless --disable-gpu --no-pdf-header-footer \
    --print-to-pdf="$OUT_DIR/orcamento.pdf" \
    "file://$OUT_DIR/orcamento.html"
fi
```

Se a flag `--no-pdf-header-footer` não for suportada na versão do Chrome, tente
`--print-to-pdf-no-header`.

## 8. Apresentar resultado

Mostre ao usuário:
- Caminho dos 3 arquivos gerados
- Resumo: cliente, total de horas, total R$, prazo
- Comando para abrir o PDF: `open "$OUT_DIR/orcamento.pdf"`

Pergunte se ele quer ajustar algo. Edições pontuais → edite o `.md` e regere HTML+PDF.

---

## Regras operacionais

- **Não invente** valores bancários, CNPJ ou dados que não estejam no `company.json`.
  Se faltar algo crítico, pergunte ou omita.
- **Português brasileiro** em todo o output. Valores em `R$` com separador de milhar `.` e
  decimal `,`.
- **Não use emojis** no PDF/HTML final.
- Se o usuário pedir uma seção extra (ex: "garantia", "SLA"), adicione no MD e replique no HTML.
- Se já existir `$OUT_DIR`, pergunte: sobrescrever ou criar com sufixo `-v2`?
