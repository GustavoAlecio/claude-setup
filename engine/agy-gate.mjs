#!/usr/bin/env node
// Hook PreToolUse do `agy` nos HOMEs sombra: entrega a chamada ao engine e espera a decisão.
// Fora de uma sessão do engine (login manual no terminal com o HOME sombra), devolve "ask" e o `agy`
// segue o fluxo interativo dele. Qualquer falha sai com código 1, e o `agy` nega a tool.

const { CLAUDE_FLOW_GATE_URL: url, CLAUDE_FLOW_GATE_SECRET: secret, CLAUDE_FLOW_SESSION_ID: session } = process.env;

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const call = JSON.parse(Buffer.concat(chunks).toString("utf8"));

if (!url || !secret || !session) {
  process.stdout.write(JSON.stringify({ decision: "ask" }));
  process.exit(0);
}

const res = await fetch(url, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ session, secret, call }),
});
if (!res.ok) {
  process.stderr.write(`gate ${res.status}: ${await res.text()}\n`);
  process.exit(1);
}
const { decision, reason } = await res.json();
process.stdout.write(JSON.stringify({ decision, ...(reason ? { reason } : {}) }));
