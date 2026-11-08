---
name: app
description: Leva a sessao atual do terminal para o app Claude Flow e a abre la, com o historico, para continuar a conversa ou partir para a execucao no app.
---

Rode:

```bash
python3 ~/.claude/bin/to-app.py
```

- Saiu com 0: responda em uma frase que a sessao foi aberta no app e que, enquanto este terminal estiver com ela aberta, o app continua num ramo novo (o terminal nao ve o que for feito la). Para continuar no mesmo transcript, o usuario faz `/exit` aqui antes de clicar em Retomar no app.
- Saiu com 1: repita o motivo do stderr em uma frase e pare. Nao tente contornar abrindo o app ou chamando o engine por outro caminho.

Nao faca mais nada neste turno: o resto da conversa acontece no app.
