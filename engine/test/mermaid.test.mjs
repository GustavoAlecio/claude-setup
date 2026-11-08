import { test, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readdirSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { query } from "./fixtures/fake-sdk.mjs";

const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-mermaid-"));
const claudeHome = tmpDir();
mkdirSync(path.join(claudeHome, "workflow"), { recursive: true });
process.env.CLAUDE_HOME = claudeHome;
process.env.CLAUDE_WEB_SCAN_ROOTS = tmpDir();

const { createEngine } = await import("../engine.mjs");
const { createMermaid, repairMermaid } = await import("../mermaid.mjs");

const servers = new Set();
after(() => {
  for (const server of servers) {
    server.closeAllConnections();
    server.close();
  }
});

async function start(render) {
  const cacheDir = tmpDir();
  const calls = [];
  const mermaid = createMermaid({
    cacheDir,
    chromePath: "/fake/chrome",
    render: async (code, theme) => {
      calls.push([code, theme]);
      return render(code);
    },
  });
  const engine = createEngine({ query, sessionsDir: tmpDir(), mermaid });
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const post = async (body) => {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/api/mermaid`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    return { status: res.status, type: res.headers.get("content-type"), bytes: Buffer.from(await res.arrayBuffer()) };
  };
  return { post, calls, cacheDir };
}

test("devolve o PNG, renderiza cada (texto, tema) uma vez e guarda no cache", async () => {
  const { post, calls, cacheDir } = await start(async () => Buffer.from("PNGDATA"));
  const first = await post({ code: "graph TD; A-->B", theme: "light" });
  assert.equal(first.status, 200);
  assert.match(first.type, /image\/png/);
  assert.equal(first.bytes.toString(), "PNGDATA");

  await post({ code: "graph TD; A-->B", theme: "light" });
  await post({ code: "graph TD; A-->B" });
  assert.deepEqual(calls, [
    ["graph TD; A-->B", "light"],
    ["graph TD; A-->B", "dark"],
  ]);
  assert.equal(readdirSync(cacheDir).filter((f) => f.endsWith(".png")).length, 2);
});

test("sintaxe invalida e 422 com a mensagem do mermaid; corpo invalido e 400", async () => {
  const { post } = await start(async () => {
    throw new Error("Parse error on line 2:\ngraph TD; A-->\n---^");
  });
  const bad = await post({ code: "graph TD; A-->" });
  assert.equal(bad.status, 422);
  assert.match(JSON.parse(bad.bytes).error, /^Parse error on line 2/);
  assert.equal((await post({ code: " " })).status, 400);
  assert.equal((await post({ code: "graph TD; A", theme: "neon" })).status, 400);
});

test("sem Chrome e 501", async () => {
  const mermaid = createMermaid({ cacheDir: tmpDir(), chromePath: null });
  await assert.rejects(mermaid.png("graph TD; A-->B"), (err) => err.status === 501);
});

test("repairMermaid poe id e aspas em titulo de subgraph solto e preserva o resto", () => {
  const code = 'flowchart TD\n  subgraph Fase 1: Spec (Dev + IA)\n    A --> B\n  end\n  subgraph ok\n  end\n  subgraph x["ja certo"]\n  end';
  assert.equal(
    repairMermaid(code),
    'flowchart TD\n  subgraph sg1["Fase 1: Spec (Dev + IA)"]\n    A --> B\n  end\n  subgraph ok\n  end\n  subgraph x["ja certo"]\n  end'
  );
});

test("o reparo so roda depois de o original falhar e o resultado fica no cache do original", async () => {
  const seen = [];
  const { post } = await start(async (code) => {
    seen.push(code);
    if (code.includes("subgraph Fase")) throw new Error("Parse error on line 2");
    return Buffer.from("OK");
  });
  const res = await post({ code: "flowchart TD\nsubgraph Fase 1: X (Y)\nend" });
  assert.equal(res.status, 200);
  await post({ code: "flowchart TD\nsubgraph Fase 1: X (Y)\nend" });
  assert.deepEqual(seen, ["flowchart TD\nsubgraph Fase 1: X (Y)\nend", 'flowchart TD\nsubgraph sg1["Fase 1: X (Y)"]\nend']);
});
