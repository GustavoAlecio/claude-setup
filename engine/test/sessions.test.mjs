import { test, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { query } from "./fixtures/fake-sdk.mjs";

// data.mjs e cwd.mjs resolvem as raizes no import: o ambiente tem que existir antes.
const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-sessions-"));
const claudeHome = tmpDir();
const workflowRoot = path.join(claudeHome, "workflow");
mkdirSync(path.join(workflowRoot, "semcwd"), { recursive: true });
process.env.CLAUDE_HOME = claudeHome;
process.env.CLAUDE_WEB_SCAN_ROOTS = tmpDir();

const { createEngine } = await import("../engine.mjs");
const { version: VERSION } = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));

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
  const engine = createEngine({ query, sessionsDir });
  engines.add(engine);
  await engine.sessions.restore();
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { engine, sessionsDir, port: server.address().port };
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

async function create(port, command, cwd = os.tmpdir()) {
  const created = await api(port, "POST", "/api/sessions", { project: "demo", cwd, command });
  assert.equal(created.status, 200, JSON.stringify(created.body));
  return created.body.id;
}

async function createIdle(port, command = "oi") {
  const id = await create(port, command);
  await waitFor(async () => (await statusOf(port, id)) === "idle");
  return id;
}

/** Le frames SSE conforme chegam; `until` espera um frame que case o predicado. */
async function openSse(port, url) {
  const controller = new AbortController();
  const res = await fetch(`http://127.0.0.1:${port}${url}`, { signal: controller.signal });
  const frames = [];
  const waiters = new Set();
  const settle = () => {
    for (const waiter of waiters) {
      const found = frames.find(waiter.predicate);
      if (!found) continue;
      waiters.delete(waiter);
      waiter.resolve(found);
    }
  };

  if (res.headers.get("content-type")?.startsWith("text/event-stream")) {
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
            const type = /^event: (.*)$/m.exec(raw)?.[1];
            const data = /^data: (.*)$/m.exec(raw)?.[1];
            if (type) frames.push({ type, data: JSON.parse(data) });
          }
          settle();
        }
      } catch {}
    })();
  }

  return {
    res,
    frames,
    until(predicate, timeoutMs = 3000) {
      const found = frames.find(predicate);
      if (found) return Promise.resolve(found);
      return new Promise((resolve, reject) => {
        const waiter = { predicate, resolve };
        waiters.add(waiter);
        setTimeout(() => {
          if (!waiters.delete(waiter)) return;
          reject(new Error(`frame nao chegou; recebidos: ${JSON.stringify(frames)}`));
        }, timeoutMs);
      });
    },
    close: () => controller.abort(),
  };
}

const kinds = (engine, id) => engine.sessions.get(id).events.map((e) => e.kind);
const lastOf = (engine, id, kind) => engine.sessions.get(id).events.findLast((e) => e.kind === kind);

async function waitPermission(engine, port, id) {
  await waitFor(async () => (await statusOf(port, id)) === "waiting_permission");
  return lastOf(engine, id, "permission");
}

test("criar sessao devolve o summary leve, roda o turno ate idle e expoe model e title", async () => {
  const { engine, port } = await start();
  const id = await create(port, "oi");
  const created = (await api(port, "GET", `/api/sessions/${id}`)).body;
  assert.equal(created.project, "demo");
  assert.equal(created.title, "oi");

  await waitFor(async () => (await statusOf(port, id)) === "idle");
  const summary = (await api(port, "GET", `/api/sessions/${id}`)).body;
  assert.equal(summary.model, "fake-model");
  assert.equal(summary.cost, 0.01);
  assert.equal(summary.pendingPermissions, 0);
  assert.equal(summary.resumable, true);
  assert.deepEqual(kinds(engine, id), ["user_text", "init", "assistant_text", "result"]);
  assert.deepEqual((await api(port, "GET", "/api/sessions")).body.map((s) => s.id), [id]);

  const long = "a".repeat(30) + "\n" + "b".repeat(60);
  const longId = await create(port, long);
  const title = (await api(port, "GET", `/api/sessions/${longId}`)).body.title;
  assert.equal(title.length, 60);
  assert.ok(title.startsWith(`${"a".repeat(30)} b`));
  assert.ok(title.endsWith("…"));
});

test("stream da sessao com ?from reenvia so os eventos posteriores e depois o status", async () => {
  const { engine, port } = await start();
  const id = await createIdle(port);
  const total = engine.sessions.get(id).events.length;

  const sse = await openSse(port, `/api/sessions/${id}/stream?from=2`);
  await sse.until((f) => f.type === "status");
  sse.close();
  const seqs = sse.frames.filter((f) => f.type === "event").map((f) => f.data.seq);
  assert.deepEqual(seqs, Array.from({ length: total - 2 }, (_, i) => i + 3));
  assert.equal(sse.frames.at(-1).type, "status");
  assert.equal(sse.frames.at(-1).data.status, "idle");
});

test("deltas chegam antes do assistant_text final e ficam fora do log", async () => {
  const { engine, port } = await start();
  const id = await createIdle(port);
  const before = engine.sessions.get(id).events.length;
  const sse = await openSse(port, `/api/sessions/${id}/stream?from=${before}`);
  await sse.until((f) => f.type === "status");

  assert.equal((await api(port, "POST", `/api/sessions/${id}/input`, { text: "de novo" })).status, 200);
  await sse.until((f) => f.type === "event" && f.data.kind === "result");
  sse.close();

  const relevant = sse.frames.filter((f) => f.type === "delta" || (f.type === "event" && f.data.kind === "assistant_text"));
  assert.deepEqual(
    relevant.map((f) => (f.type === "delta" ? f.data.text : `final:${f.data.text}`)),
    ["ol", "a ", "mundo", "final:ola mundo"]
  );
  assert.ok(!engine.sessions.get(id).events.some((e) => e.kind === "delta"));
});

test("permissao allow e deny resolvem o pedido e o resultado da ferramenta", async () => {
  const { engine, port } = await start();

  const allowId = await create(port, "perm:Edit");
  const allowReq = await waitPermission(engine, port, allowId);
  assert.equal(allowReq.toolName, "Edit");
  assert.equal((await api(port, "GET", `/api/sessions/${allowId}`)).body.pendingPermissions, 1);
  const allowed = await api(port, "POST", `/api/sessions/${allowId}/permission`, { requestId: allowReq.requestId, decision: "allow" });
  assert.equal(allowed.status, 200);
  await waitFor(async () => (await statusOf(port, allowId)) === "idle");
  assert.equal(lastOf(engine, allowId, "permission_resolved").decision, "allow");
  assert.equal(lastOf(engine, allowId, "tool_result").isError, false);
  assert.equal(lastOf(engine, allowId, "result").text, "Edit aplicado");
  const again = await api(port, "POST", `/api/sessions/${allowId}/permission`, { requestId: allowReq.requestId, decision: "allow" });
  assert.equal(again.status, 409);

  const denyId = await create(port, "perm:Edit");
  const denyReq = await waitPermission(engine, port, denyId);
  await api(port, "POST", `/api/sessions/${denyId}/permission`, { requestId: denyReq.requestId, decision: "deny" });
  await waitFor(async () => (await statusOf(port, denyId)) === "idle");
  assert.equal(lastOf(engine, denyId, "permission_resolved").decision, "deny");
  assert.equal(lastOf(engine, denyId, "tool_result").isError, true);
  assert.equal(lastOf(engine, denyId, "result").text, "Edit negado");
});

test("answer com duas perguntas, uma multiSelect, devolve answers ao AskUserQuestion", async () => {
  const { engine, port } = await start();
  const id = await create(port, "ask2");
  const request = await waitPermission(engine, port, id);
  assert.equal(request.toolName, "AskUserQuestion");
  assert.equal(request.input.questions.length, 2);
  assert.equal(request.input.questions[1].multiSelect, true);

  const answers = { "Qual banco?": "Postgres", "Quais alvos?": "macOS, iOS" };
  assert.equal((await api(port, "POST", `/api/sessions/${id}/permission`, { requestId: request.requestId, decision: "answer" })).status, 400);
  const answered = await api(port, "POST", `/api/sessions/${id}/permission`, { requestId: request.requestId, decision: "answer", answers });
  assert.equal(answered.status, 200);
  await waitFor(async () => (await statusOf(port, id)) === "idle");
  assert.equal(lastOf(engine, id, "permission_resolved").decision, "answer");
  assert.deepEqual(JSON.parse(lastOf(engine, id, "tool_result").text), answers);
  assert.equal(lastOf(engine, id, "result").text, `respostas: ${JSON.stringify(answers)}`);
});

test("sessao restaurada fica detached com o model do init e o resume a religa", async () => {
  const first = await start();
  const id = await createIdle(first.port);
  await first.engine.sessions.shutdown({ waitMs: 200 });

  const { engine, port } = await start(first.sessionsDir);
  const restored = (await api(port, "GET", `/api/sessions/${id}`)).body;
  assert.equal(restored.status, "detached");
  assert.equal(restored.model, "fake-model");
  assert.equal(restored.resumable, true);

  const resumed = await api(port, "POST", `/api/sessions/${id}/resume`);
  assert.equal(resumed.status, 200);
  assert.equal(resumed.body.status, "idle");
  assert.equal(lastOf(engine, id, "reattached").kind, "reattached");

  await api(port, "POST", `/api/sessions/${id}/input`, { text: "continua" });
  await waitFor(async () => engine.sessions.get(id).events.filter((e) => e.kind === "result").length === 2);
  assert.equal(await statusOf(port, id), "idle");
});

test("stop encerra o processo e o resume seguinte devolve 'resumed' e aceita input", async () => {
  const { engine, port } = await start();
  const id = await createIdle(port);
  const session = engine.sessions.get(id);
  session.stop();
  await waitFor(async () => (await statusOf(port, id)) === "stopped");
  await waitFor(() => session.query === null);

  assert.equal(await session.resume(), "resumed");
  assert.equal(await session.resume(), "attached");
  await api(port, "POST", `/api/sessions/${id}/input`, { text: "volta" });
  await waitFor(() => session.events.filter((e) => e.kind === "result").length === 2);
  assert.equal(await statusOf(port, id), "idle");
});

test("sessao sem githubAccount religa a cada resume depois que o processo termina", async () => {
  const calls = [];
  const engine = createEngine({ query: (args) => (calls.push(args), query(args)), sessionsDir: tmpDir() });
  engines.add(engine);
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  const id = await createIdle(port);
  const session = engine.sessions.get(id);
  assert.equal(session.githubAccount, null);

  for (let round = 2; round <= 3; round++) {
    session.stop();
    await waitFor(() => session.query === null);
    assert.equal(await session.resume(), "resumed");
    assert.equal(calls.length, round);
    assert.ok(session.query);
  }
});

test("interrupt leva a idle e o input seguinte e aceito", async () => {
  const { engine, port } = await start();
  const id = await create(port, "slow");
  await waitFor(async () => (await statusOf(port, id)) === "running");

  const interrupted = await api(port, "POST", `/api/sessions/${id}/interrupt`);
  assert.equal(interrupted.status, 200);
  assert.equal(interrupted.body.status, "idle");
  await waitFor(() => lastOf(engine, id, "result"));

  const input = await api(port, "POST", `/api/sessions/${id}/input`, { text: "oi" });
  assert.equal(input.status, 200);
  await waitFor(() => lastOf(engine, id, "result").text === "ola mundo");
  assert.equal(await statusOf(port, id), "idle");
});

test("stream global manda snapshot, summary so em mudanca relevante e removed", async () => {
  const { port } = await start();
  const existing = await createIdle(port);

  const sse = await openSse(port, "/api/sessions/stream");
  const snapshot = await sse.until((f) => f.type === "snapshot");
  assert.deepEqual(snapshot.data.map((s) => s.id), [existing]);
  assert.equal(snapshot.data[0].status, "idle");

  const id = await create(port, "perm:Edit");
  const waiting = await sse.until((f) => f.type === "summary" && f.data.id === id && f.data.pendingPermissions === 1);
  assert.equal(waiting.data.title, "perm:Edit");
  await sse.until((f) => f.type === "summary" && f.data.id === id && f.data.status === "waiting_permission");

  const events = await openSse(port, `/api/sessions/${id}/stream`);
  const permission = await events.until((f) => f.type === "event" && f.data.kind === "permission");
  events.close();
  await api(port, "POST", `/api/sessions/${id}/permission`, { requestId: permission.data.requestId, decision: "allow" });
  const done = await sse.until((f) => f.type === "summary" && f.data.id === id && f.data.status === "idle" && f.data.cost === 0.01);
  assert.equal(done.data.pendingPermissions, 0);
  assert.equal(done.data.model, "fake-model");

  const ofSession = sse.frames.filter((f) => f.type === "summary" && f.data.id === id).map((f) => f.data);
  const keys = ofSession.map((s) => JSON.stringify([s.status, s.pendingPermissions, s.cost, s.model]));
  for (let i = 1; i < keys.length; i++) assert.notEqual(keys[i], keys[i - 1], `summary repetido: ${keys[i]}`);
  assert.ok(ofSession.length < 10, `summaries demais: ${ofSession.length}`);

  assert.equal((await api(port, "DELETE", `/api/sessions/${id}`)).body.deleted, true);
  assert.deepEqual((await sse.until((f) => f.type === "removed")).data, { id });
  await sleep(50);
  assert.ok(!sse.frames.some((f) => f.type === "summary" && f.data.id === id && f.data.status === "stopped"));
  sse.close();
});

test("GET /api/sessions/stream e o stream global, nao a rota /api/sessions/:id", async () => {
  const { port } = await start();
  const sse = await openSse(port, "/api/sessions/stream");
  assert.equal(sse.res.status, 200);
  assert.match(sse.res.headers.get("content-type"), /^text\/event-stream/);
  assert.deepEqual((await sse.until((f) => f.type === "snapshot")).data, []);
  sse.close();
});

test("POST sem cwd resolvido responde 400 com o texto que orienta o usuario", async () => {
  const { port } = await start();
  const res = await api(port, "POST", "/api/sessions", { project: "semcwd", command: "oi" });
  assert.equal(res.status, 400);
  assert.equal(res.body.error, "sem diretório para semcwd: defina cwds.semcwd em ~/.claude/workflow/.dashboard.json");
});

test("/api/skills devolve paletteSkills ∩ skills na ordem da paleta, ou todas sem a chave", async () => {
  for (const name of ["alpha", "beta", "gamma"]) {
    mkdirSync(path.join(claudeHome, "skills", name), { recursive: true });
    writeFileSync(path.join(claudeHome, "skills", name, "SKILL.md"), `---\nname: ${name}\ndescription: skill ${name}\n---\n`);
  }
  mkdirSync(path.join(claudeHome, "skills", "sem-skill-md"), { recursive: true });
  const config = path.join(workflowRoot, ".dashboard.json");
  const { port } = await start();

  writeFileSync(config, JSON.stringify({ cwds: {}, paletteSkills: ["gamma", "inexistente", "alpha"] }));
  const filtered = await api(port, "GET", "/api/skills");
  assert.equal(filtered.status, 200);
  assert.deepEqual(filtered.body, [
    { name: "gamma", description: "skill gamma", model: null },
    { name: "alpha", description: "skill alpha", model: null },
  ]);

  writeFileSync(config, JSON.stringify({ cwds: {} }));
  assert.deepEqual((await api(port, "GET", "/api/skills")).body.map((s) => s.name), ["alpha", "beta", "gamma"]);
});

test("health responde a versao do package.json e nao ha / nem rotas de artefato", async () => {
  const { port } = await start();
  assert.deepEqual((await api(port, "GET", "/api/health")).body, { ok: true, version: VERSION });
  assert.equal((await api(port, "GET", "/")).status, 404);
  assert.equal((await api(port, "GET", "/api/projects/demo/artifact?path=spec.md")).status, 404);
  assert.equal((await api(port, "GET", "/api/projects/demo/reviews")).status, 404);
});
