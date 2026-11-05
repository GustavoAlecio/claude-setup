import { test, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readdirSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { query as fakeQuery } from "./fixtures/fake-sdk.mjs";

// data.mjs e cwd.mjs resolvem as raizes no import: o ambiente tem que existir antes.
const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-org-"));
const claudeHome = tmpDir();
mkdirSync(path.join(claudeHome, "workflow"), { recursive: true });
process.env.CLAUDE_HOME = claudeHome;
process.env.CLAUDE_WEB_SCAN_ROOTS = tmpDir();

const { createEngine } = await import("../engine.mjs");

const servers = new Set();
const engines = new Set();

after(async () => {
  for (const engine of engines) await engine.sessions.shutdown({ waitMs: 200 });
  for (const server of servers) {
    server.closeAllConnections();
    server.close();
  }
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function start(sessionsDir = tmpDir()) {
  const calls = [];
  const query = (args) => {
    calls.push(args.options);
    return fakeQuery(args);
  };
  const engine = createEngine({ query, sessionsDir });
  engines.add(engine);
  await engine.sessions.restore();
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { engine, sessionsDir, port: server.address().port, calls };
}

async function api(port, method, url, body) {
  const res = await fetch(`http://127.0.0.1:${port}${url}`, {
    method,
    headers: body ? { "content-type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, body: await res.json().catch(() => null) };
}

async function waitFor(check, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await check();
    if (value) return value;
    await sleep(10);
  }
  throw new Error("condicao nao satisfeita a tempo");
}

const statusOf = async (port, id) => (await api(port, "GET", `/api/sessions/${id}`)).body.status;

test("sessao de org passa cwd e additionalDirectories ao SDK e os expoe no summary", async () => {
  const { port, calls } = await start();
  const [root, extra1, extra2] = [tmpDir(), tmpDir(), tmpDir()];
  const created = await api(port, "POST", "/api/sessions", {
    org: "ABM Soluções",
    command: "oi",
    cwd: root,
    additionalDirectories: [extra1, extra2],
  });
  assert.equal(created.status, 200, JSON.stringify(created.body));
  assert.equal(created.body.project, "");
  assert.equal(created.body.org, "ABM Soluções");
  assert.equal(created.body.cwd, root);
  assert.deepEqual(created.body.additionalDirectories, [extra1, extra2]);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].cwd, root);
  assert.deepEqual(calls[0].additionalDirectories, [extra1, extra2]);
});

test("sessao de org sem adicionais nao manda additionalDirectories ao SDK", async () => {
  const { port, calls } = await start();
  const root = tmpDir();
  const created = await api(port, "POST", "/api/sessions", { org: "acme", command: "oi", cwd: root });
  assert.equal(created.status, 200, JSON.stringify(created.body));
  assert.deepEqual(created.body.additionalDirectories, []);
  assert.equal(calls[0].cwd, root);
  assert.equal("additionalDirectories" in calls[0], false);
});

test("resume depois de shutdown reaplica cwd e additionalDirectories do snapshot", async () => {
  const first = await start();
  const [root, extra] = [tmpDir(), tmpDir()];
  const created = await api(first.port, "POST", "/api/sessions", {
    org: "acme",
    command: "oi",
    cwd: root,
    additionalDirectories: [extra],
  });
  const id = created.body.id;
  await waitFor(async () => (await statusOf(first.port, id)) === "idle");
  await first.engine.sessions.shutdown({ waitMs: 200 });

  const { port, calls } = await start(first.sessionsDir);
  const restored = (await api(port, "GET", `/api/sessions/${id}`)).body;
  assert.equal(restored.status, "detached");
  assert.equal(restored.project, "");
  assert.equal(restored.org, "acme");
  assert.equal(restored.cwd, root);
  assert.deepEqual(restored.additionalDirectories, [extra]);

  const resumed = await api(port, "POST", `/api/sessions/${id}/resume`);
  assert.equal(resumed.status, 200, JSON.stringify(resumed.body));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].cwd, root);
  assert.deepEqual(calls[0].additionalDirectories, [extra]);
  assert.ok(calls[0].resume);
});

test("org invalida, cwd ausente, adicionais invalidos e paths ruins dao 400 sem criar sessao", async () => {
  const { engine, port, sessionsDir, calls } = await start();
  const root = tmpDir();
  const missing = path.join(root, "nao-existe");
  const cases = [
    [{ org: "", command: "oi", cwd: root }, "org invalida"],
    [{ org: "   ", command: "oi", cwd: root }, "org invalida"],
    [{ org: 42, command: "oi", cwd: root }, "org invalida"],
    [{ org: "acme", command: "oi" }, "cwd ausente"],
    [{ org: "acme", command: "oi", cwd: root, additionalDirectories: "x" }, "additionalDirectories invalido"],
    [{ org: "acme", command: "oi", cwd: root, additionalDirectories: [root, 1] }, "additionalDirectories invalido"],
    [{ org: "acme", command: "oi", cwd: "relativo/dir" }, "diretorio invalido: relativo/dir"],
    [{ org: "acme", command: "oi", cwd: missing }, `diretorio invalido: ${missing}`],
    [{ org: "acme", command: "oi", cwd: root, additionalDirectories: ["rel"] }, "diretorio invalido: rel"],
    [{ org: "acme", command: "oi", cwd: root, additionalDirectories: [root, missing] }, `diretorio invalido: ${missing}`],
    [{ org: "acme", command: "oi", cwd: missing, additionalDirectories: ["rel"] }, `diretorio invalido: ${missing}`],
  ];
  for (const [body, error] of cases) {
    const res = await api(port, "POST", "/api/sessions", body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.deepEqual(res.body, { error }, JSON.stringify(body));
  }
  assert.deepEqual(engine.sessions.list(), []);
  assert.equal(calls.length, 0);
  await sleep(450);
  assert.deepEqual(readdirSync(sessionsDir), []);
});

test("sessao de projeto tem org null e additionalDirectories vazio, tambem no snapshot", async () => {
  const first = await start();
  const created = await api(first.port, "POST", "/api/sessions", { project: "demo", cwd: tmpDir(), command: "oi" });
  assert.equal(created.status, 200, JSON.stringify(created.body));
  assert.equal(created.body.project, "demo");
  assert.equal(created.body.org, null);
  assert.deepEqual(created.body.additionalDirectories, []);
  assert.equal("additionalDirectories" in first.calls[0], false);

  const id = created.body.id;
  await waitFor(async () => (await statusOf(first.port, id)) === "idle");
  await first.engine.sessions.shutdown({ waitMs: 200 });

  const { port } = await start(first.sessionsDir);
  const restored = (await api(port, "GET", `/api/sessions/${id}`)).body;
  assert.equal(restored.org, null);
  assert.deepEqual(restored.additionalDirectories, []);
});
