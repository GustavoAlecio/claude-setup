# Melhorias

Backlog do app (Claude Flow) e da engine. Cada item diz o que falta, por que importa e onde começa.

## Maturidade de IA: do nível 5 (System Builder) ao 6 (Steward)

Avaliação de 2026-10-07, comparada com LangGraph/LangSmith. O app já tem:
- orquestração projetada (Fluxo Smart, escada de modelos, gates G0/G1/G2);
- dois providers atrás de uma interface só;
- orgs e contas por org;
- ADRs, artefatos e relatório por ciclo.

Falta a camada de confiança e governança.

| # | Melhoria | Por que importa | Por onde começar |
|---|---|---|---|
| M1 | **Evals do Fluxo Smart** — métricas comparáveis por ciclo, task e modelo (taxa de aprovação nos gates, retries, escaladas, falso-aprovado no G2) | Sem medição, "a escada funciona" é impressão, não dado | `trace.jsonl`, routing stats e `metrics_parser.dart` já existem |
| M2 | **Orçamento e alerta de cota por org** — limite, aviso antes de esgotar e bloqueio opcional | Hoje a cota só é exibida; não há política | Cota do Antigravity em `/api/agy/models`; custo Claude no `result` |
| M3 | **Trilha de auditoria pesquisável** — sessões, aprovações, decisões de gate e trocas de modelo/modo num índice | O histórico existe, mas fica espalhado em snapshots locais, sem busca nem retenção | Eventos das sessões e `report.json` |
| M4 | **Execução durável entre etapas do fluxo** — retomar do passo exato após queda, com o working tree amarrado ao checkpoint | Uma etapa que cai no meio recomeça | `wf-checkpoint.sh` |
| M5 | **Política declarativa** — o que cada org/modo permite, num arquivo verificável | As regras estão espalhadas em prompts, skills e modos | Gate do `agy` e `canUseTool` já centralizam a decisão |
| M6 | **Dados sensíveis** — scan de segredos e PII no que vai para os modelos | Só o token do GitHub é redigido (ADR 0017) | `redact` em `gh_env.mjs` |
| M7 | **Multiusuário / RBAC** — se o app virar ferramenta de time | Hoje é local e de um usuário só | Decisão de produto antes de técnica |

## Experiência (revisão de produto/UX de 2026-10-07)

Avaliação do agente `product-ux-reviewer`, feita com o app rodando com dados de exemplo e cruzada com o código. Persona: usuário médio de tecnologia, vários projetos em paralelo. Notas: usabilidade 6, visual 7,5, features 6. Esforço: P/M/G.

Itens marcados com ✅ estão feitos (2026-10-07).

### Crítico
| # | Problema | Recomendação | Esforço |
|---|---|---|---|
| U1 ✅ | "Piloto automático on" fixo no código (`shell_page.dart:274`), contradizendo o "Piloto off" do ciclo | Ligar ao estado real e virar toggle, ou remover | P |
| U2 ✅ | Ciclo bloqueado com diagnóstico pendente não conta como "aguardando você" e fica abaixo da dobra no Fluxo | Contar bloqueio e verify reprovado nos badges; banner vermelho no topo com as ações | M |
| U3 ✅ | `bypass` é o padrão de tudo (`kDefaultPermissionMode`), inclusive no review aberto pela inbox | Padrão "aceitar edições" no primeiro uso; bypass vira opt-in com confirmação | P |

### Alto
| # | Problema | Recomendação | Esforço |
|---|---|---|---|
| U4 ✅ | Não há visão consolidada de vários projetos; a lateral não mostra sessões rodando | "Minha fila" da org: Aguardando / Rodando / Bloqueado / Pronto para PR; contadores na lateral | G |
| U5 ✅ | Sem notificação do macOS nem badge no Dock | Notificar permissão, pergunta, bloqueio e fim de etapa; badge com o total | M |
| U6 ✅ | "Revisar" da inbox abre projeto não cadastrado, com ações desabilitadas sem explicação | Review no escopo da org, ou associar o repo antes; tooltip em todo desabilitado | M |
| U7 ✅ | Reviews / PRs / Para revisar espalhados; o review é só leitura | Área "PRs" com Minhas / Para revisar; Aprovar e Publicar no app | M |
| U8 ✅ | Jargão interno (tier0, G0/G1, ToT, lente…) e status em inglês | Glossário na interface, siglas só em tooltip, status em PT-BR | M |
| U9 ✅ | Configurações descarta alterações sem aviso | Indicador de "não salvo" e confirmação ao sair, ou autosave | P |
| U10 ✅ | Kickoff não avisa que já existe ciclo ativo | Banner com o ciclo atual e confirmação | P |

### Médio e baixo
Feitos em 2026-10-07: origem da pergunta no card "Aguardando você" (etapa, título, abrir sessão) e mais altura sem sessão abaixo; "Sessão de apoio" para o `/fix`; etapa em andamento sem sessão com "Retomar /etapa"; "sem relatório" uma vez no cabeçalho (e nada nas etapas pendentes); cor própria para "aguardando resposta"; card de falha com título, renovação, "Tentar de novo" e troca de modelo (cota do Antigravity, limite e sobrecarga da Anthropic, login); tooltip do agente da org; Configurações e Como funciona no rodapé da lateral; plurais e espaçamento do CI em PRs; métricas em dois grupos com cards de altura fixa; busca, título em duas linhas e estado vazio nas sessões; H1 duplicado e "afeta" nos ADRs; `/kickoff` só como "Novo kickoff" e altura fixa na paleta; etapa e data nos artefatos.
Depois, no mesmo dia: "Responder" também no topo de cards de pergunta longos; PRs com comentários esperando na coluna "Aguardando você" da Minha fila; "Copiar" e "Mostrar no Finder" nos artefatos (só arquivos contidos no diretório do projeto) e "copiar" nos caminhos de "Como funciona"; custo das sessões do projeto nas Métricas.
Também feitos: orçamento por ciclo (global, com override por org, aviso a partir de 80% e banner ao passar), pausar, retomar e arquivar o ciclo como abandonado pelo Fluxo (`bin/wf-cycle.py` pela engine), e arrastar imagem para o composer e a paleta.

- **Fluxo, painel lateral:** o card "Aguardando você" não diz de qual sessão vem, e o "Responder" some no scroll.
- **Fluxo, banner:** o banner chama `/fix` de "etapa".
- **Fluxo, estado contraditório:** verify "em andamento" sem sessão e sem ação para destravar.
- **Fluxo, ruído:** "sem relatório desta etapa" repetido nas 8 linhas.
- **Status:** "aguardando resposta" e "aguardando permissão" usam a mesma cor.
- **Erros de sessão:** aparecem como texto cru; precisam virar card com "Tentar de novo", "Trocar modelo" e horário de reset. Falta também tratar cota e rate limit da Anthropic.
- **Provider da org:** precisa ficar claro que vale "só para conversas livres".
- **Configurações:** sem acesso visível (falta engrenagem); "git_protocol" exposto; carrossel com setas para só 2 cards.
- **PRs:** "1 PR(s)", data colada no pill de CI, comentário esperando que não conta como pendência.
- **Métricas:** KPI órfão, sem custo em $, jargão.
- **Sessões:** lista sem busca, títulos truncados, cabeçalho "Este projeto" vazio.
- **ADRs:** título duplicado; filtros em PT e badges em EN.
- **Paleta:** kickoff duplicado; altura muda ao filtrar.
- **Artefatos:** sem etapa, data nem "abrir no editor".
- **"Sobre o app":** vira "Como funciona", com uma camada introdutória.

### Lacunas de features
Feitas em 2026-10-07: 1 (Minha fila e ⌘J para a próxima pendência), 2 (notificações e badge), 3 (aprovar e publicar review), 5 (busca de sessões, artefatos e ADRs na ⌘K, a partir de 2 letras), 7 (checklist de primeiro uso).

1. Fila única entre projetos, com atalho "próxima pendência" e atalho para trocar de projeto.
2. Notificações nativas e badge no Dock.
3. Ações de review no app: aprovar, editar ou descartar comentário, publicar.
4. Ver as mudanças do ciclo (diff da branch, abrir no editor) e "Abrir PR" pelo Fluxo.
5. Busca global na paleta: sessões, artefatos, ADRs, PRs.
6. Custo por projeto e ciclo, com orçamento e alerta (liga com M2).
7. Checklist de primeiro uso: `claude` e `gh` logados, org, projeto.
8. Pausar, arquivar e retomar ciclo pela interface.

### Preservar
- Card de permissão com diff inline.
- Diagnóstico de bloqueio com hipóteses e ações (o conteúdo; só a linguagem muda).
- Validação do kickoff.
- Paleta com modos e chips.
- Explicação dos modos de permissão.
- Badges por org coerentes.
- Rodapé da engine com Reiniciar.
- Visual escuro consistente.

## Experiência — 2ª rodada: Configurações, Sobre e Nova org (2026-10-07)

Notas nestas áreas: usabilidade 6, visual 7, features 5,5. Evidências em `scratchpad/ux2/`.

### Crítico
| # | Problema | Recomendação | Esforço |
|---|---|---|---|
| R1 ✅ | Salvar a org fica desabilitado sem explicação sempre que há divergência de SSH no GitHub, mesmo quando a mudança é em outra seção (`org_form.dart` `_blocked`) | Bloquear só quando a lista de orgs do GitHub mudou; ao lado do botão, o motivo com link para a seção | P |
| R2 ✅ | "Remover org" sem confirmação e colado no Salvar | Diálogo com o impacto (projetos que ficam sem org); botão afastado | P |

### Alto
| # | Problema | Recomendação | Esforço |
|---|---|---|---|
| R3 ✅ | Trocar a org de um projeto aplica na hora e muda em silêncio a conta do gh, o agente e a permissão | Confirmar mostrando o que muda; snackbar "Desfazer"; sinalizar pasta fora da raiz da org | P/M |
| R4 ✅ | ⌘1..9, ⌘I, ⌘, e fechar a janela descartam edição não salva (U9 só cobre Voltar e troca de card) | Estado "não salvo" acima do router, consultado pelos atalhos; "Salvar e sair" | M |
| R5 ✅ | O primeiro uso pede 4 seções técnicas (permissões, agente, GitHub, git_protocol) | Só nome + pasta; o resto em "Opções avançadas"; checklist `claude`/`gh` logados | M |
| R6 ✅ | "Adicionar projeto" é global e cai em "Sem org" | Adicionar por org (já atribuído); o global pergunta a org; destacar a linha nova | P/M |
| R7 ✅ | "Sobre o app" é um painel de engenharia (G0/G1, tier0, chaves cruas) | "Como funciona", com aba "Começar" (5 passos, atalhos, versão); internals em "Diagnóstico" | M |

### Médio e baixo
Feitos em 2026-10-07: permissões globais no topo, com o alcance do bypass e "herdar global (valor)"; cancelar login e aviso de timeout; aviso de modelo esgotado; sugestões do GitHub identificadas pela conta, mais o texto para lista vazia; pills legíveis, herança distinta, tooltip e "+ Nova org" no título; erros de nome e pasta no campo, e a pasta preenchendo o nome; "Adicionar projeto" na org vazia e na lateral; "Escolha uma org" com pendências, ⌘N, "Nova org" e Configurações; plural; Salvar só com alteração; colunas do editor; ocultos com caminho e "Desfazer"; git_protocol só como aviso quando é https.
Pendentes: "Salvar e sair" no diálogo e guard ao fechar a janela ou ⌘Q (precisa de código nativo); abrir os caminhos do "Sobre" (exige ampliar a política do opener para arquivos); "padrão do agy" sem o nome do modelo (o `agy` não informa); os dois atalhos de "Nova atividade" (os dois funcionam de propósito).

- **Permissões globais:** ficam no fim da página. "Herdar global" não mostra o valor herdado, e o diálogo de bypass não diz quais orgs são afetadas.
- **Login Antigravity:** não dá para cancelar, e o timeout de 5 min termina sem mensagem.
- **Modelo esgotado:** pode ser escolhido sem aviso; "padrão do agy" não diz qual modelo é; aparece o id em vez do rótulo.
- **Sugestões de orgs do GitHub:** vêm da conta ativa e vazam entre orgs. Também não fica dito que uma lista vazia significa "todas as orgs".
- **Cards do carrossel:** pills em jargão ("gh ativo", "agy abm"); "padrão" e "herda" com o mesmo visual; raiz truncada sem tooltip; "+ Nova org" cortado na borda.
- **Validação da nova org:** um erro por vez, na ordem errada e longe do campo. Escolher a pasta não preenche o nome.
- **Org recém-criada sem projetos:** a tela fica vazia, sem um "Adicionar projeto" acionável.
- **"Escolha uma org":** sem pendências por org, sem "Nova org" e sem acesso a Configurações.
- **Plural:** "1 projetos".
- **Salvar:** fica habilitado sem nenhuma alteração; a nova org não tem indicador de não salvo.
- **"Nova atividade":** aparece com dois atalhos (⌘K e ⌘⇧K).
- **Editor da org:** colunas desequilibradas.
- **Ocultos:** sem org nem caminho, e sem desfazer.
- **Caminhos em "Sobre":** não abrem nada.

### Lacunas de features
Feitas em 2026-10-07: 1, 2 (Duplicar, que copia permissões, agente e GitHub), 4 (Desfazer em mover e ocultar; remover org pede confirmação), 5 (Configurações › Avançado: pasta da engine, Node e skills da paleta) e 7 (cada projeto mostra agente, modo e conta do GitHub).

1. Checklist de prontidão: `claude` e `gh` logados (e com qual conta), engine, Node.
2. Duplicar uma org.
3. Adicionar projetos por org a partir dos repos encontrados sob a raiz.
4. Desfazer para mover projeto, ocultar e remover org.
5. Campos para engineDir, nodePath e paletteSkills em Configurações › Avançado.
6. Ajuda contextual ("?") nos formulários.
7. Configuração efetiva por projeto: com qual provider, modo e conta ele roda.

## Pendências conhecidas

- **Fluxo Smart em outros providers:** proposta na ADR 0026 (runner dos workflows na engine, escada por provider).
- **Conta Anthropic por org:** proposta na ADR 0027 (`CLAUDE_CONFIG_DIR` sombra), com spike do Keychain antes de aceitar.
- **Notificação de orçamento estourado:** hoje só o banner no Fluxo avisa.
- **Guard ao sair com alteração não salva:** ⌘Q e o botão de fechar passam pelo `onExitRequested`; testado em widget test, não ponta a ponta no app nativo.
- **Interrupção no meio do turno em sessões Antigravity:** hoje o processo é encerrado.
