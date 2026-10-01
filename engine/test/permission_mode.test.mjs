import { test, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spyQuery } from "./fixtures/fake-sdk.mjs";

// data.mjs e cwd.mjs resolvem as raizes no import: o ambiente tem que existir antes.
const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-permmode-"));
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

/** `wrap` deixa o teste alterar as options que chegam ao SDK falso. */
async function start({ sessionsDir = tmpDir(), wrap = (options) => options } = {}) {
  const spy = spyQuery();
  const engine = createEngine({ query: (args) => spy.query({ ...args, options: wrap(args.options) }), sessionsDir });
  engines.add(engine);
  await engine.sessions.restore();
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { engine, sessionsDir, port: server.address().port, spy };
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

const summaryOf = async (port, id) => (await api(port, "GET", `/api/sessions/${id}`)).body;

async function create(port, command, extra = {}) {
  const created = await api(port, "POST", "/api/sessions", { project: "demo", cwd: os.tmpdir(), command, ...extra });
  assert.equal(created.status, 200, JSON.stringify(created.body));
  return created.body.id;
}

async function createIdle(port, extra) {
  const id = await create(port, "oi", extra);
  await waitFor(async () => (await summaryOf(port, id)).status === "idle");
  return id;
}

const eventsOf = (engine, id, kind) => engine.sessions.get(id).events.filter((e) => e.kind === kind);

/** Frames SSE do stream global; `until` espera um `summary` que case o predicado. */
async function openGlobalStream(port) {
  const controller = new AbortController();
  const res = await fetch(`http://127.0.0.1:${port}/api/sessions/stream`, { signal: controller.signal });
  const summaries = [];
  (async () => {
    const decoder = new TextDecoder();
    let buffer = "";
    try {
      for await (const chunk of res.body) {
        buffer += decoder.decode(chunk, { stream: true });
        let cut;
        while ((cut = buffer.indexOf("\n\n")) >= 0) {
          const raw = buffer.slice(0, cut);
          buffer = buffer.slice(cut + 2);
          if (/^event: summary$/m.test(raw)) summaries.push(JSON.parse(/^data: (.*)$/m.exec(raw)[1]));
        }
      }
    } catch {}
  })();
  return {
    until: (predicate) => waitFor(() => summaries.find(predicate)),
    close: () => controller.abort(),
  };
}

test("criacao: sem modo e default; todo modo aceito vai ao SDK com a flag de bypass ligada; invalido e 400", async () => {
  const { port, spy } = await start();

  const id = await create(port, "oi");
  assert.equal((await summaryOf(port, id)).permissionMode, "default");
  assert.equal(spy.calls.at(-1).permissionMode, "default");
  assert.equal(spy.calls.at(-1).allowDangerouslySkipPermissions, true);

  for (const mode of ["default", "acceptEdits", "auto", "bypassPermissions"]) {
    const created = await create(port, "oi", { permissionMode: mode });
    assert.equal((await summaryOf(port, created)).permissionMode, mode);
    assert.equal(spy.calls.at(-1).permissionMode, mode);
    assert.equal(spy.calls.at(-1).allowDangerouslySkipPermissions, true);
  }

  const orgDir = tmpDir();
  const orgCreated = await api(port, "POST", "/api/sessions", { org: "acme", cwd: orgDir, command: "oi", permissionMode: "acceptEdits" });
  assert.equal(orgCreated.status, 200);
  assert.equal(orgCreated.body.permissionMode, "acceptEdits");
  assert.equal(spy.calls.at(-1).permissionMode, "acceptEdits");

  const before = spy.calls.length;
  for (const permissionMode of ["x", "plan", null]) {
    const invalid = await api(port, "POST", "/api/sessions", { project: "demo", cwd: os.tmpdir(), command: "oi", permissionMode });
    assert.equal(invalid.status, 400);
  }
  assert.equal(spy.calls.length, before);
});

test("troca ao vivo: setPermissionMode no SDK, evento permission_mode, summary no stream e proxima chamada sem card", async () => {
  const { engine, port, spy } = await start();
  const id = await createIdle(port);
  const query = spy.queries.at(-1);
  const sse = await openGlobalStream(port);

  const changed = await api(port, "POST", `/api/sessions/${id}/permission-mode`, { mode: "bypassPermissions" });
  assert.equal(changed.status, 200);
  assert.equal(changed.body.permissionMode, "bypassPermissions");
  assert.deepEqual(query.permissionModeCalls, ["bypassPermissions"]);
  assert.deepEqual(eventsOf(engine, id, "permission_mode").map((e) => e.mode), ["bypassPermissions"]);
  await sse.until((s) => s.id === id && s.permissionMode === "bypassPermissions");
  sse.close();

  await api(port, "POST", `/api/sessions/${id}/input`, { text: "perm:Edit" });
  await waitFor(() => eventsOf(engine, id, "result").at(-1)?.text === "Edit aplicado");
  assert.equal(eventsOf(engine, id, "permission").length, 0);

  assert.equal((await api(port, "POST", `/api/sessions/${id}/permission-mode`, { mode: "plan" })).status, 400);
  assert.equal((await api(port, "POST", "/api/sessions/nope/permission-mode", { mode: "default" })).status, 404);
});

test("troca recusada pelo SDK: 409 com a mensagem, nada gravado e nenhum evento", async () => {
  const { engine, port, spy } = await start({ wrap: (options) => ({ ...options, allowDangerouslySkipPermissions: false }) });
  const id = await createIdle(port);
  const before = engine.sessions.get(id).events.length;

  const refused = await api(port, "POST", `/api/sessions/${id}/permission-mode`, { mode: "bypassPermissions" });
  assert.equal(refused.status, 409);
  assert.match(refused.body.error, /bypass_disabled/);
  assert.deepEqual(spy.queries.at(-1).permissionModeCalls, ["bypassPermissions"]);
  assert.equal((await summaryOf(port, id)).permissionMode, "default");
  assert.equal(engine.sessions.get(id).snapshot().permissionMode, "default");
  assert.equal(engine.sessions.get(id).events.length, before);
});

test("cards pendentes: a troca de modo nao resolve os pedidos abertos", async () => {
  const { engine, port } = await start();
  const id = await create(port, "perm2");
  await waitFor(async () => (await summaryOf(port, id)).pendingPermissions === 2);

  const changed = await api(port, "POST", `/api/sessions/${id}/permission-mode`, { mode: "bypassPermissions" });
  assert.equal(changed.status, 200);
  await sleep(50);

  const summary = await summaryOf(port, id);
  assert.equal(summary.pendingPermissions, 2);
  assert.equal(summary.status, "waiting_permission");
  assert.equal(eventsOf(engine, id, "permission_resolved").length, 0);

  for (const { requestId } of eventsOf(engine, id, "permission")) {
    await api(port, "POST", `/api/sessions/${id}/permission`, { requestId, decision: "allow" });
  }
  await waitFor(() => eventsOf(engine, id, "result").at(-1)?.text === "perm2 resolvido");
});

test("bypass com SDK falso: AskUserQuestion pede card e recebe answers; Edit roda sem card", async () => {
  const { engine, port } = await start();

  const askId = await create(port, "ask2", { permissionMode: "bypassPermissions" });
  await waitFor(async () => (await summaryOf(port, askId)).status === "waiting_permission");
  const [request] = eventsOf(engine, askId, "permission");
  assert.equal(request.toolName, "AskUserQuestion");
  const answers = { "Qual banco?": "SQLite", "Quais alvos?": "iOS" };
  await api(port, "POST", `/api/sessions/${askId}/permission`, { requestId: request.requestId, decision: "answer", answers });
  await waitFor(() => eventsOf(engine, askId, "result").length === 1);
  assert.deepEqual(JSON.parse(eventsOf(engine, askId, "tool_result")[0].text), answers);

  const editId = await create(port, "perm:Edit", { permissionMode: "bypassPermissions" });
  await waitFor(() => eventsOf(engine, editId, "result").length === 1);
  assert.equal(eventsOf(engine, editId, "result")[0].text, "Edit aplicado");
  assert.equal(eventsOf(engine, editId, "permission").length, 0);
});

test("resume usa o modo do snapshot; snapshot sem a chave volta como default", async () => {
  const first = await start();
  const kept = await createIdle(first.port, { permissionMode: "acceptEdits" });
  const legacy = await createIdle(first.port, { permissionMode: "acceptEdits" });
  await first.engine.sessions.shutdown({ waitMs: 200 });

  const legacyFile = path.join(first.sessionsDir, `${legacy}.json`);
  const snapshot = JSON.parse(readFileSync(legacyFile, "utf8"));
  assert.equal(snapshot.permissionMode, "acceptEdits");
  delete snapshot.permissionMode;
  writeFileSync(legacyFile, JSON.stringify(snapshot));

  const { port, spy } = await start({ sessionsDir: first.sessionsDir });
  assert.equal((await summaryOf(port, kept)).permissionMode, "acceptEdits");
  assert.equal((await summaryOf(port, legacy)).permissionMode, "default");

  assert.equal((await api(port, "POST", `/api/sessions/${kept}/resume`)).status, 200);
  assert.equal(spy.calls.at(-1).permissionMode, "acceptEdits");
  assert.equal(spy.calls.at(-1).allowDangerouslySkipPermissions, true);

  assert.equal((await api(port, "POST", `/api/sessions/${legacy}/resume`)).status, 200);
  assert.equal(spy.calls.at(-1).permissionMode, "default");
});

test("sessao sem processo: a troca so grava e vale no proximo attach", async () => {
  const first = await start();
  const id = await createIdle(first.port);
  await first.engine.sessions.shutdown({ waitMs: 200 });

  const { engine, port, spy } = await start({ sessionsDir: first.sessionsDir });
  const changed = await api(port, "POST", `/api/sessions/${id}/permission-mode`, { mode: "bypassPermissions" });
  assert.equal(changed.status, 200);
  assert.equal(changed.body.status, "detached");
  assert.equal(changed.body.permissionMode, "bypassPermissions");
  assert.equal(spy.calls.length, 0);
  assert.equal(engine.sessions.get(id).snapshot().permissionMode, "bypassPermissions");
  assert.deepEqual(eventsOf(engine, id, "permission_mode").map((e) => e.mode), ["bypassPermissions"]);

  await api(port, "POST", `/api/sessions/${id}/resume`);
  assert.equal(spy.calls.at(-1).permissionMode, "bypassPermissions");
});
