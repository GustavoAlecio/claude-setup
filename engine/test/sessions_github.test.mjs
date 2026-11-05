import { test, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spyQuery } from "./fixtures/fake-sdk.mjs";

// data.mjs e cwd.mjs resolvem as raizes no import: o ambiente tem que existir antes.
const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-sessions-gh-"));
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

const TOKENS = { "acct-a": "gho_FAKEsessionaaaaaaaaaaaaaaaaaaaa" };
const NOT_LOGGED = "conta acct-a não está logada no gh (gh auth login)";
const STRIPPED = ["GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"];

/** So responde `gh auth token --user`; `known` decide quais contas estao logadas. */
function fakeGh(known = TOKENS) {
  const calls = [];
  const gh = async (args, { env } = {}) => {
    calls.push({ args, env });
    assert.deepEqual(args.slice(0, 2), ["auth", "token"], `gh inesperado: ${args.join(" ")}`);
    const token = known[args[args.indexOf("--user") + 1]];
    if (!token) throw Object.assign(new Error("Command failed"), { code: 1, stderr: "no oauth token found" });
    return { stdout: `${token}\n` };
  };
  return { gh, calls };
}

async function start({ sessionsDir = tmpDir(), gh = fakeGh(), log = () => {} } = {}) {
  const spy = spyQuery();
  const engine = createEngine({ query: spy.query, sessionsDir, gh: gh.gh, log });
  engines.add(engine);
  await engine.sessions.restore();
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { engine, sessionsDir, port: server.address().port, queries: spy.calls, gh };
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

async function createIdle(port, body) {
  const created = await api(port, "POST", "/api/sessions", { project: "demo", cwd: os.tmpdir(), command: "oi", ...body });
  assert.equal(created.status, 200, JSON.stringify(created.body));
  await waitFor(async () => (await statusOf(port, created.body.id)) === "idle");
  return created.body;
}

async function withEnv(vars, body) {
  const saved = Object.fromEntries(Object.keys(vars).map((k) => [k, process.env[k]]));
  for (const [k, v] of Object.entries(vars)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return await body();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

/** Le o stream da sessao como texto cru ate o predicado casar. */
async function readStream(port, id, from, until) {
  const controller = new AbortController();
  const res = await fetch(`http://127.0.0.1:${port}/api/sessions/${id}/stream?from=${from}`, { signal: controller.signal });
  const decoder = new TextDecoder();
  let text = "";
  const reading = (async () => {
    try {
      for await (const chunk of res.body) {
        text += decoder.decode(chunk, { stream: true });
        if (until(text)) break;
      }
    } catch {}
  })();
  return {
    done: async () => {
      await waitFor(() => until(text));
      controller.abort();
      await reading;
      return text;
    },
  };
}

test("ambiente da sessao: sem token herdado, GH_TOKEN da conta, prompts desligados e SSH intocado", async () => {
  await withEnv(
    {
      GITHUB_TOKEN: "ghp_FAKEinheritedinheritedinherited",
      GH_TOKEN: "gho_FAKEinheritedinheritedinherited",
      GH_HOST: "example.invalid",
      SSH_AUTH_SOCK: "/tmp/fake-agent.sock",
      GIT_SSH_COMMAND: undefined,
    },
    async () => {
      const { port, queries, gh } = await start();

      const withAccount = await createIdle(port, { githubAccount: "acct-a" });
      assert.equal(withAccount.githubAccount, "acct-a");
      const env = queries[0].env;
      for (const [key, value] of Object.entries(process.env)) {
        if (!STRIPPED.includes(key)) assert.equal(env[key], value, key);
      }
      assert.equal(env.GH_TOKEN, TOKENS["acct-a"]);
      assert.equal("GITHUB_TOKEN" in env, false);
      assert.equal("GH_HOST" in env, false);
      assert.equal(env.GH_PROMPT_DISABLED, "1");
      assert.equal(env.GIT_TERMINAL_PROMPT, "0");
      assert.equal(env.SSH_AUTH_SOCK, "/tmp/fake-agent.sock");
      assert.equal("GIT_SSH_COMMAND" in env, false);
      assert.equal(gh.calls[0].env.GH_TOKEN, undefined, "o proprio auth token roda sem token herdado");

      const without = await createIdle(port, {});
      assert.equal(without.githubAccount, null);
      const plain = queries[1].env;
      assert.equal("GH_TOKEN" in plain, false);
      assert.equal("GITHUB_TOKEN" in plain, false);
      assert.equal(plain.GIT_TERMINAL_PROMPT, "0");

      const org = await api(port, "POST", "/api/sessions", {
        org: "org-app",
        cwd: os.tmpdir(),
        command: "oi",
        githubAccount: "acct-a",
      });
      assert.equal(org.status, 200, JSON.stringify(org.body));
      assert.equal(org.body.githubAccount, "acct-a");
      assert.equal(queries[2].env.GH_TOKEN, TOKENS["acct-a"]);
      assert.equal(gh.calls.length, 1, "token em cache entre sessoes da mesma conta");
    }
  );
});

test("githubAccount desconhecido ou invalido: 400 sem sessao e sem query", async () => {
  const { port, queries, gh } = await start();

  const unknown = await api(port, "POST", "/api/sessions", {
    project: "demo",
    cwd: os.tmpdir(),
    command: "oi",
    githubAccount: "acct-z",
  });
  assert.deepEqual([unknown.status, unknown.body], [400, { error: "conta acct-z não está logada no gh (gh auth login)" }]);

  for (const githubAccount of ["--hostname", "", 42, ["acct-a"]]) {
    const res = await api(port, "POST", "/api/sessions", { project: "demo", cwd: os.tmpdir(), command: "oi", githubAccount });
    assert.deepEqual([res.status, res.body], [400, { error: "parâmetro inválido" }], JSON.stringify(githubAccount));
  }

  assert.equal(gh.calls.length, 1);
  assert.equal(queries.length, 0);
  assert.deepEqual((await api(port, "GET", "/api/sessions")).body, []);
});

test("redacao: token ecoado pelo agente nao chega ao stream, aos eventos, ao snapshot nem ao log", async () => {
  const token = TOKENS["acct-a"];
  const logged = [];
  const { engine, port, sessionsDir } = await start({ log: (...args) => logged.push(args.join(" ")) });
  const { id } = await createIdle(port, { githubAccount: "acct-a" });
  const from = engine.sessions.get(id).events.length;

  const stream = await readStream(port, id, from, (text) => text.includes('"kind":"result"') && text.includes("fim"));
  await sleep(30);
  assert.equal((await api(port, "POST", `/api/sessions/${id}/input`, { text: "leak" })).status, 200);
  const raw = await stream.done();
  await waitFor(async () => (await statusOf(port, id)) === "idle");

  assert.ok(raw.includes("event: delta"), raw);
  assert.ok(raw.includes("token=***"), raw);
  assert.ok(!raw.includes(token), raw);

  const events = JSON.stringify(engine.sessions.get(id).events);
  assert.ok(events.includes("vi ***"));
  assert.ok(!events.includes(token));

  await engine.sessions.flushAll();
  const snapshot = readFileSync(path.join(sessionsDir, `${id}.json`), "utf8");
  assert.ok(!snapshot.includes(token));
  assert.equal(JSON.parse(snapshot).githubAccount, "acct-a");
  assert.ok(!logged.join("\n").includes(token));
});

test("resume: token pedido de novo, attach unico em inputs concorrentes, conta removida e 409", async () => {
  const first = await start();
  const { id } = await createIdle(first.port, { githubAccount: "acct-a" });
  await first.engine.sessions.shutdown({ waitMs: 200 });
  const saved = JSON.parse(readFileSync(path.join(first.sessionsDir, `${id}.json`), "utf8"));
  assert.equal(saved.githubAccount, "acct-a");
  assert.ok(!JSON.stringify(saved).includes(TOKENS["acct-a"]));

  const second = await start({ sessionsDir: first.sessionsDir });
  const restored = (await api(second.port, "GET", `/api/sessions/${id}`)).body;
  assert.deepEqual([restored.status, restored.githubAccount], ["detached", "acct-a"]);
  assert.equal((await api(second.port, "POST", `/api/sessions/${id}/input`, { text: "continua" })).status, 200);
  await waitFor(() => second.engine.sessions.get(id).events.filter((e) => e.kind === "result").length === 2);
  assert.equal(second.gh.calls.length, 1);
  assert.equal(second.queries.length, 1);
  assert.equal(second.queries[0].env.GH_TOKEN, TOKENS["acct-a"]);
  assert.equal(second.queries[0].resume, saved.sdkSessionId);
  await second.engine.sessions.shutdown({ waitMs: 200 });

  const third = await start({ sessionsDir: first.sessionsDir });
  const [a, b] = await Promise.all([
    api(third.port, "POST", `/api/sessions/${id}/input`, { text: "um" }),
    api(third.port, "POST", `/api/sessions/${id}/input`, { text: "dois" }),
  ]);
  assert.deepEqual([a.status, b.status], [200, 200]);
  assert.equal(third.queries.length, 1);
  assert.equal(third.gh.calls.length, 1);
  assert.equal(third.engine.sessions.get(id).events.filter((e) => e.kind === "reattached").length, 2, "um reattached por restart");
  await waitFor(() => third.engine.sessions.get(id).events.filter((e) => e.kind === "result").length === 4);
  await third.engine.sessions.shutdown({ waitMs: 200 });

  const fourth = await start({ sessionsDir: first.sessionsDir, gh: fakeGh({}) });
  const input = await api(fourth.port, "POST", `/api/sessions/${id}/input`, { text: "sem conta" });
  assert.deepEqual([input.status, input.body], [409, { error: NOT_LOGGED }]);
  const resume = await api(fourth.port, "POST", `/api/sessions/${id}/resume`);
  assert.deepEqual([resume.status, resume.body], [409, { error: NOT_LOGGED }]);
  assert.equal(fourth.queries.length, 0);
  assert.equal(await statusOf(fourth.port, id), "detached");
});

test("snapshot antigo sem githubAccount: resume sem GH_TOKEN e sem pedir token", async () => {
  const sessionsDir = tmpDir();
  const id = "11111111-1111-4111-8111-111111111111";
  writeFileSync(
    path.join(sessionsDir, `${id}.json`),
    JSON.stringify({
      id,
      project: "demo",
      org: null,
      cwd: os.tmpdir(),
      additionalDirectories: [],
      command: "oi",
      createdAt: "2026-09-01T00:00:00.000Z",
      sdkSessionId: "fake-old",
      cost: 0,
      events: [],
    })
  );
  const { port, queries, gh } = await start({ sessionsDir });

  assert.equal((await api(port, "GET", `/api/sessions/${id}`)).body.githubAccount, null);
  assert.equal((await api(port, "POST", `/api/sessions/${id}/input`, { text: "volta" })).status, 200);
  assert.equal(queries.length, 1);
  assert.equal("GH_TOKEN" in queries[0].env, false);
  assert.equal(gh.calls.length, 0);
});
