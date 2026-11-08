import { test, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, writeFileSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { query } from "./fixtures/fake-sdk.mjs";

const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-agy-"));
const claudeHome = tmpDir();
mkdirSync(path.join(claudeHome, "workflow"), { recursive: true });
process.env.CLAUDE_HOME = claudeHome;
process.env.CLAUDE_WEB_SCAN_ROOTS = tmpDir();
process.env.AGY_BIN = fileURLToPath(new URL("./fixtures/fake-agy.mjs", import.meta.url));

const { createEngine, parseAgyModels, parseAgyQuota, quotaFor } = await import("../engine.mjs");
const { createAccounts } = await import("../accounts.mjs");

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

async function waitFor(check, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await check();
    if (value) return value;
    await sleep(10);
  }
  throw new Error("condicao nao satisfeita a tempo");
}

function fakeHome() {
  const home = tmpDir();
  mkdirSync(path.join(home, ".ssh"));
  writeFileSync(path.join(home, ".gitconfig"), "[user]\n");
  mkdirSync(path.join(home, ".gemini"));
  mkdirSync(path.join(home, "Library", "Keychains"), { recursive: true });
  mkdirSync(path.join(home, "Library", "Developer"));
  return home;
}

async function start() {
  const home = fakeHome();
  const accounts = createAccounts({ home, root: path.join(tmpDir(), "accounts") });
  const log = path.join(tmpDir(), "agy.log");
  process.env.FAKE_AGY_LOG = log;
  const engine = createEngine({ query, sessionsDir: tmpDir(), accounts });
  engines.add(engine);
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  engine.listening(server.address().port);
  return { engine, port: server.address().port, accounts, log };
}

async function api(port, method, url, body) {
  const res = await fetch(`http://127.0.0.1:${port}${url}`, {
    method,
    headers: body ? { "content-type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, body: await res.json().catch(() => null) };
}

const statusOf = async (port, id) => (await api(port, "GET", `/api/sessions/${id}`)).body.status;
const eventsOf = (engine, id, kind) => engine.sessions.get(id).events.filter((e) => e.kind === kind);

async function create(port, command, extra = {}) {
  const res = await api(port, "POST", "/api/sessions", {
    project: "demo",
    cwd: os.tmpdir(),
    command,
    provider: "antigravity",
    account: "likin.do",
    model: "gemini-x",
    ...extra,
  });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  return res.body.id;
}

const tool = (name, args) => `tool:${name}:${JSON.stringify(args)}`;

test("turno de texto vira init, assistant_text e result; o id da conversa vira o do resume", async () => {
  const { engine, port, log } = await start();
  const id = await create(port, "text:ola mundo");
  await waitFor(async () => (await statusOf(port, id)) === "idle");

  const session = engine.sessions.get(id);
  assert.equal(session.sdkSessionId, "conv-1");
  assert.equal(eventsOf(engine, id, "assistant_text")[0].text, "ola mundo");
  assert.equal(eventsOf(engine, id, "result")[0].text, "ola mundo");
  assert.equal(session.summary().provider, "antigravity");
  assert.equal(session.summary().account, "likin.do");

  const [spawned] = readFileSync(log, "utf8").trim().split("\n").map(JSON.parse);
  assert.ok(spawned.args.includes("--dangerously-skip-permissions"));
  assert.deepEqual(spawned.args.slice(spawned.args.indexOf("--model"), spawned.args.indexOf("--model") + 2), ["--model", "gemini-x"]);
  assert.match(spawned.home, /accounts\/likin\.do$/);
});

test("modo default: leitura passa sem card; comando vira card de Bash e a negacao volta como erro da tool", async () => {
  const { engine, port } = await start();
  const id = await create(port, tool("view_file", { AbsolutePath: "/tmp/x" }));
  await waitFor(async () => (await statusOf(port, id)) === "idle");
  assert.equal(eventsOf(engine, id, "permission").length, 0);
  assert.equal(eventsOf(engine, id, "tool_result")[0].isError, false);

  await api(port, "POST", `/api/sessions/${id}/input`, { text: tool("run_command", { CommandLine: "rm -rf build" }) });
  const card = await waitFor(() => eventsOf(engine, id, "permission")[0]);
  assert.equal(card.toolName, "Bash");
  assert.equal(card.input.command, "rm -rf build");

  await api(port, "POST", `/api/sessions/${id}/permission`, { requestId: card.requestId, decision: "deny" });
  await waitFor(() => eventsOf(engine, id, "tool_result").length === 2);
  const denied = eventsOf(engine, id, "tool_result")[1];
  assert.equal(denied.isError, true);
  assert.match(denied.text, /negado pelo usuario/);
});

test("acceptEdits libera escrita; trocar para bypass ao vivo libera comando sem reiniciar o processo", async () => {
  const { engine, port, log } = await start();
  const id = await create(port, tool("write_to_file", { TargetFile: "/tmp/a", CodeContent: "x" }), { permissionMode: "acceptEdits" });
  await waitFor(async () => (await statusOf(port, id)) === "idle");
  assert.equal(eventsOf(engine, id, "permission").length, 0);
  assert.equal(eventsOf(engine, id, "tool_use")[0].name, "Write");

  assert.equal((await api(port, "POST", `/api/sessions/${id}/permission-mode`, { mode: "bypassPermissions" })).status, 200);
  await api(port, "POST", `/api/sessions/${id}/input`, { text: tool("run_command", { CommandLine: "ls" }) });
  await waitFor(() => eventsOf(engine, id, "tool_result").length === 2);
  assert.equal(eventsOf(engine, id, "permission").length, 0);
  assert.equal(eventsOf(engine, id, "tool_result")[1].isError, false);
  assert.equal(readFileSync(log, "utf8").trim().split("\n").length, 1);
});

test("plan: leitura passa e o resto e recusado sem card", async () => {
  const { engine, port } = await start();
  const id = await create(port, tool("write_to_file", { TargetFile: "/tmp/a", CodeContent: "x" }), { permissionMode: "plan" });
  await waitFor(async () => (await statusOf(port, id)) === "idle");
  assert.equal(eventsOf(engine, id, "permission").length, 0);
  const [result] = eventsOf(engine, id, "tool_result");
  assert.equal(result.isError, true);
  assert.match(result.text, /só leitura/);
});

test("ask_question vira AskUserQuestion e a escolha volta ao modelo no motivo do deny", async () => {
  const { engine, port } = await start();
  const id = await create(port, tool("ask_question", { questions: [{ question: "Cor?", options: ["Azul", "Verde"], is_multi_select: false }] }));
  const card = await waitFor(() => eventsOf(engine, id, "permission")[0]);
  assert.equal(card.toolName, "AskUserQuestion");
  assert.deepEqual(card.input.questions[0].options.map((o) => o.label), ["Azul", "Verde"]);

  await api(port, "POST", `/api/sessions/${id}/permission`, { requestId: card.requestId, decision: "answer", answers: { "Cor?": "Verde" } });
  const result = await waitFor(() => eventsOf(engine, id, "tool_result")[0]);
  assert.match(result.text, /Cor\?: Verde/);
});

test("interrupt mata o processo e a mensagem seguinte religa com --conversation", async () => {
  const { engine, port, log } = await start();
  const id = await create(port, "text:primeira");
  await waitFor(async () => (await statusOf(port, id)) === "idle");

  await api(port, "POST", `/api/sessions/${id}/interrupt`);
  await waitFor(() => !engine.sessions.get(id).query.proc);
  await api(port, "POST", `/api/sessions/${id}/input`, { text: "text:segunda" });
  await waitFor(() => eventsOf(engine, id, "result").length === 2);

  const spawns = readFileSync(log, "utf8").trim().split("\n").map(JSON.parse);
  assert.equal(spawns.length, 2);
  assert.deepEqual(spawns[1].args.slice(spawns[1].args.indexOf("--conversation")), ["--conversation", "conv-1"]);
});

test("artefatos: lista os arquivos de topo da conversa e serve o conteudo, sem sair da pasta", async () => {
  const { port, accounts } = await start();
  const id = await create(port, "text:oi");
  await waitFor(async () => (await statusOf(port, id)) === "idle");

  const brain = path.join(accounts.dirFor("likin.do"), ".gemini", "antigravity-cli", "brain", "conv-1");
  mkdirSync(path.join(brain, ".system_generated"), { recursive: true });
  writeFileSync(path.join(brain, "analise.md"), "# Analise");
  writeFileSync(path.join(brain, "analise.md.metadata.json"), "{}");
  writeFileSync(path.join(brain, ".system_generated", "log.md"), "x");

  const list = await api(port, "GET", `/api/sessions/${id}/artifacts`);
  assert.deepEqual(list.body.artifacts.map((a) => a.name), ["analise.md"]);
  const read = await api(port, "GET", `/api/sessions/${id}/artifacts/analise.md`);
  assert.deepEqual(read.body, { name: "analise.md", content: "# Analise" });
  assert.equal((await api(port, "GET", `/api/sessions/${id}/artifacts/analise.md.metadata.json`)).status, 404);
  assert.equal((await api(port, "GET", `/api/sessions/${id}/artifacts/..%2F..%2Fsettings.json`)).status, 404);

});

test("mostrar no Finder abre a pasta da conversa com o artefato selecionado", async () => {
  const home = fakeHome();
  const accounts = createAccounts({ home, root: path.join(tmpDir(), "accounts") });
  process.env.FAKE_AGY_LOG = path.join(tmpDir(), "agy.log");
  const revealed = [];
  const engine = createEngine({ query, sessionsDir: tmpDir(), accounts, reveal: async (file) => revealed.push(file) });
  engines.add(engine);
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  engine.listening(port);
  const id = await create(port, "text:oi");
  await waitFor(async () => (await statusOf(port, id)) === "idle");
  const brain = path.join(accounts.dirFor("likin.do"), ".gemini", "antigravity-cli", "brain", "conv-1");
  mkdirSync(brain, { recursive: true });
  writeFileSync(path.join(brain, "a.md"), "x");

  assert.equal((await api(port, "POST", `/api/sessions/${id}/artifacts/a.md/reveal`)).status, 200);
  assert.deepEqual(revealed, [path.join(brain, "a.md")]);
  assert.equal((await api(port, "POST", `/api/sessions/${id}/artifacts/nope.md/reveal`)).status, 404);
});

test("gate com segredo errado e 403", async () => {
  const { port } = await start();
  const id = await create(port, "text:oi");
  await waitFor(async () => (await statusOf(port, id)) === "idle");
  const res = await api(port, "POST", "/internal/agy-gate", { session: id, secret: "nope", call: { toolCall: { name: "run_command" } } });
  assert.equal(res.status, 403);
});

test("conta invalida e provider desconhecido sao 400", async () => {
  const { port } = await start();
  const bad = await api(port, "POST", "/api/sessions", { project: "demo", cwd: os.tmpdir(), command: "x", provider: "antigravity", account: "../x" });
  assert.equal(bad.status, 400);
  const unknown = await api(port, "POST", "/api/sessions", { project: "demo", cwd: os.tmpdir(), command: "x", provider: "openai" });
  assert.equal(unknown.status, 400);
});

test("HOME sombra: espelha o HOME sem .gemini, isola Keychains fora da default e grava o hook", async () => {
  const home = fakeHome();
  const root = path.join(tmpDir(), "accounts");
  const accounts = createAccounts({ home, root, nodeBin: "/usr/bin/node" });

  const dir = await accounts.prepare("likin.do");
  assert.equal(readlinkSync(path.join(dir, ".ssh")), path.join(home, ".ssh"));
  assert.equal(lstatSync(path.join(dir, ".gemini")).isSymbolicLink(), false);
  assert.equal(existsSync(path.join(dir, "Library", "Keychains")), false);
  assert.equal(readlinkSync(path.join(dir, "Library", "Developer")), path.join(home, "Library", "Developer"));
  const hooks = JSON.parse(readFileSync(path.join(dir, ".gemini", "config", "hooks.json"), "utf8"));
  assert.match(hooks["claude-flow-gate"].PreToolUse[0].hooks[0].command, /agy-gate\.mjs"$/);

  const fallback = await accounts.prepare("default");
  assert.equal(readlinkSync(path.join(fallback, "Library", "Keychains")), path.join(home, "Library", "Keychains"));

  writeFileSync(path.join(dir, ".lesshst"), "criado pela ferramenta");
  mkdirSync(path.join(home, ".novo"));
  await accounts.prepare("likin.do");
  assert.equal(readFileSync(path.join(dir, ".lesshst"), "utf8"), "criado pela ferramenta");
  assert.equal(readlinkSync(path.join(dir, ".novo")), path.join(home, ".novo"));
  assert.equal(await accounts.loggedIn("likin.do"), false);
});

test("login abre no Terminal um .command que roda o agy com o HOME sombra da conta", async () => {
  const home = fakeHome();
  const root = path.join(tmpDir(), "accounts");
  const opened = [];
  const accounts = createAccounts({ home, root, open: async (file) => opened.push(file) });
  const engine = createEngine({ query, sessionsDir: tmpDir(), accounts });
  engines.add(engine);
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;

  assert.equal((await api(port, "POST", "/api/agy/accounts/likin.do/login")).status, 200);
  assert.deepEqual(opened, [path.join(root, "likin.do.login.command")]);
  const script = readFileSync(opened[0], "utf8");
  assert.match(script, new RegExp(`HOME='${path.join(root, "likin.do")}' exec `));
  assert.equal((await api(port, "POST", "/api/agy/accounts/..%2Fx/login")).status, 400);
});

test("parseAgyModels le slug e rotulo e ignora o cabecalho", () => {
  assert.deepEqual(parseAgyModels("Fetching available models...\ngemini-x\tGemini X\nclaude-y\tClaude Y\n"), [
    { id: "gemini-x", label: "Gemini X" },
    { id: "claude-y", label: "Claude Y" },
  ]);
});

test("parseAgyQuota le grupos, percentual e reset; quotaFor casa o modelo pela familia", () => {
  const groups = parseAgyQuota(
    "Gemini Models\tWeekly Limit Remaining\t0%\t2026-10-13T12:03:43Z\nClaude and GPT models\tWeekly Limit Remaining\t97%\t2026-10-13T12:12:34Z\n"
  );
  assert.deepEqual(groups, [
    { families: ["gemini"], remaining: 0, resetsAt: "2026-10-13T12:03:43.000Z" },
    { families: ["claude", "gpt"], remaining: 0.97, resetsAt: "2026-10-13T12:12:34.000Z" },
  ]);
  assert.deepEqual(quotaFor("gemini-3.1-pro-high", groups), { remaining: 0, resetsAt: "2026-10-13T12:03:43.000Z" });
  assert.deepEqual(quotaFor("gpt-oss-120b-medium", groups), { remaining: 0.97, resetsAt: "2026-10-13T12:12:34.000Z" });
  assert.equal(quotaFor("llama-x", groups), null);
});

test("modelos do agy vem com a cota do grupo; /quota falhando deixa a cota nula", async () => {
  const home = fakeHome();
  const accounts = createAccounts({ home, root: path.join(tmpDir(), "accounts") });
  let quotaOk = true;
  const execAgy = async (args) => {
    if (args[0] === "models") return { stdout: "gemini-x\tGemini X\nclaude-y\tClaude Y\n" };
    if (!quotaOk) throw new Error("boom");
    return { stdout: "Gemini Models\tWeekly Limit Remaining\t0%\t2026-10-13T12:03:43Z\n" };
  };
  let clock = 0;
  const engine = createEngine({ query, sessionsDir: tmpDir(), accounts, execAgy, now: () => clock });
  engines.add(engine);
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;

  const { body } = await api(port, "GET", "/api/agy/models?account=default");
  assert.deepEqual(body.models, [
    { id: "gemini-x", label: "Gemini X", quota: { remaining: 0, resetsAt: "2026-10-13T12:03:43.000Z" } },
    { id: "claude-y", label: "Claude Y", quota: null },
  ]);

  quotaOk = false;
  clock += 61_000;
  const later = await api(port, "GET", "/api/agy/models?account=default");
  assert.equal(later.body.models[0].quota, null);
});

test("result do agy: status da conversa nao marca erro num turno com resposta, totais viram diferenca e repetido some", async () => {
  const { createAgy } = await import("../agy.mjs");
  const { PassThrough } = await import("node:stream");
  const { EventEmitter } = await import("node:events");
  const stdout = new PassThrough();
  const proc = Object.assign(new EventEmitter(), {
    stdin: new PassThrough(),
    stdout,
    stderr: new PassThrough(),
    kill() {
      setImmediate(() => proc.emit("exit", null, "SIGTERM"));
    },
  });
  const accounts = { prepare: async () => "/tmp" };
  const agy = createAgy({ accounts, gateUrl: () => "http://x", bin: "agy", spawn: () => proc });
  async function* prompt() {
    yield { type: "user", message: { content: "oi" } };
    await new Promise(() => {});
  }
  const run = agy.query({ prompt: prompt(), options: { env: {}, canUseTool: async () => ({ behavior: "allow" }) } });
  const results = [];
  const reading = (async () => {
    for await (const m of run) if (m.type === "result") results.push(m);
  })();
  await new Promise((r) => setTimeout(r, 20));
  const result = (status, response, duration, turns) =>
    stdout.write(`${JSON.stringify({ event: "result", result: { status, response, duration_seconds: duration, num_turns: turns } })}\n`);
  result("SUCCESS", "a", 10, 1);
  result("ERROR", "b", 25, 2);
  result("ERROR", "b", 25, 2);
  result("ERROR", "", 30, 3);
  await new Promise((r) => setTimeout(r, 20));
  run.close();
  await reading.catch(() => {});
  assert.deepEqual(
    results.map((r) => [r.is_error, r.duration_ms, r.num_turns]),
    [
      [false, 10000, 1],
      [false, 15000, 1],
      [true, 5000, 1],
    ]
  );
});
