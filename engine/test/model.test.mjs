import { test, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spyQuery } from "./fixtures/fake-sdk.mjs";

const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-model-"));
const claudeHome = tmpDir();
mkdirSync(path.join(claudeHome, "workflow"), { recursive: true });
process.env.CLAUDE_HOME = claudeHome;
process.env.CLAUDE_WEB_SCAN_ROOTS = tmpDir();
process.env.AGY_BIN = fileURLToPath(new URL("./fixtures/fake-agy.mjs", import.meta.url));

const { createEngine } = await import("../engine.mjs");
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

async function start(sessionsDir = tmpDir()) {
  const spy = spyQuery();
  const home = tmpDir();
  const accounts = createAccounts({ home, root: path.join(home, "accounts") });
  const log = path.join(tmpDir(), "agy.log");
  process.env.FAKE_AGY_LOG = log;
  const engine = createEngine({ query: spy.query, sessionsDir, accounts });
  engines.add(engine);
  await engine.sessions.restore();
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  engine.listening(server.address().port);
  return { engine, spy, sessionsDir, log, port: server.address().port };
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

async function createIdle(port, extra = {}) {
  const res = await api(port, "POST", "/api/sessions", { project: "demo", cwd: os.tmpdir(), command: "oi", ...extra });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  await waitFor(async () => (await statusOf(port, res.body.id)) === "idle");
  return res.body.id;
}

test("Claude: troca ao vivo pelo setModel do SDK, emite evento e o resume usa o modelo novo", async () => {
  const { engine, spy, sessionsDir, port } = await start();
  const id = await createIdle(port);

  const res = await api(port, "POST", `/api/sessions/${id}/model`, { model: "sonnet" });
  assert.equal(res.status, 200);
  assert.equal(res.body.model, "sonnet");
  assert.deepEqual(spy.queries[0].modelCalls, ["sonnet"]);
  assert.equal(engine.sessions.get(id).events.at(-1).kind, "model");

  await engine.sessions.shutdown({ waitMs: 200 });
  const again = await start(sessionsDir);
  assert.equal((await api(again.port, "POST", `/api/sessions/${id}/resume`)).status, 200);
  assert.equal(again.spy.calls.at(-1).model, "sonnet");
});

test("modelo invalido e 400; sem processo so grava", async () => {
  const { engine, port } = await start();
  const id = await createIdle(port);
  assert.equal((await api(port, "POST", `/api/sessions/${id}/model`, { model: "rm -rf" })).status, 400);
  engine.sessions.get(id).stop();
  await waitFor(() => !engine.sessions.get(id).query);
  assert.equal((await api(port, "POST", `/api/sessions/${id}/model`, { model: "opus" })).status, 200);
  assert.equal(engine.sessions.get(id).requestedModel, "opus");
});

test("Antigravity: a troca religa o agy com --model novo na mesma conversa", async () => {
  const { port, log } = await start();
  const id = await createIdle(port, { command: "text:oi", provider: "antigravity", model: "gemini-x" });

  assert.equal((await api(port, "POST", `/api/sessions/${id}/model`, { model: "claude-y" })).status, 200);
  await api(port, "POST", `/api/sessions/${id}/input`, { text: "text:de novo" });
  await waitFor(() => readFileSync(log, "utf8").trim().split("\n").length === 2);

  const [first, second] = readFileSync(log, "utf8").trim().split("\n").map(JSON.parse);
  const flag = (args, name) => args[args.indexOf(name) + 1];
  assert.equal(flag(first.args, "--model"), "gemini-x");
  assert.equal(flag(second.args, "--model"), "claude-y");
  assert.equal(flag(second.args, "--conversation"), "conv-1");
});

test("Antigravity: trocar no meio de um turno e 409", async () => {
  const { engine, port } = await start();
  const id = await createIdle(port, { command: "text:oi", provider: "antigravity" });
  engine.sessions.get(id).query.busy = true;
  const res = await api(port, "POST", `/api/sessions/${id}/model`, { model: "claude-y" });
  assert.equal(res.status, 409);
  assert.match(res.body.error, /aguarde o turno/);
});

test("lista os modelos do Claude por uma consulta descartavel e guarda em cache", async () => {
  const { spy, port } = await start();
  const first = await api(port, "GET", "/api/claude/models");
  assert.deepEqual(first.body.models, [
    { id: "opus", label: "Opus" },
    { id: "sonnet", label: "Sonnet" },
  ]);
  await api(port, "GET", "/api/claude/models");
  assert.equal(spy.calls.length, 1);
  assert.equal(spy.calls[0].abortController.signal.aborted, true);
});

const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");

test("imagens: o Claude recebe blocos de imagem, o evento guarda os anexos e a rota os serve", async () => {
  const { engine, spy, port } = await start();
  const id = await createIdle(port);
  const data = PNG.toString("base64");

  const res = await api(port, "POST", `/api/sessions/${id}/input`, { text: "o que tem aqui?", images: [{ mediaType: "image/png", data }] });
  assert.equal(res.status, 200);
  await waitFor(() => spy.queries[0].prompts.length === 2);
  assert.deepEqual(spy.queries[0].prompts[1], [
    { type: "text", text: "o que tem aqui?" },
    { type: "image", source: { type: "base64", media_type: "image/png", data } },
  ]);

  const event = engine.sessions.get(id).events.findLast((e) => e.kind === "user_text");
  assert.equal(event.images.length, 1);
  const served = await fetch(`http://127.0.0.1:${port}/api/sessions/${id}/attachments/${event.images[0]}`);
  assert.equal(served.status, 200);
  assert.deepEqual(Buffer.from(await served.arrayBuffer()), PNG);
  assert.equal((await fetch(`http://127.0.0.1:${port}/api/sessions/${id}/attachments/..%2Fx.png`)).status, 404);
});

test("imagens na criacao vao junto da primeira mensagem", async () => {
  const { engine, spy, port } = await start();
  const data = PNG.toString("base64");
  const res = await api(port, "POST", "/api/sessions", {
    project: "x",
    cwd: os.tmpdir(),
    command: "descreva",
    images: [{ mediaType: "image/png", data }],
  });
  assert.equal(res.status, 200);
  await waitFor(() => spy.queries[0]?.prompts.length === 1);
  assert.deepEqual(spy.queries[0].prompts[0], [
    { type: "text", text: "descreva" },
    { type: "image", source: { type: "base64", media_type: "image/png", data } },
  ]);
  const event = engine.sessions.get(res.body.id).events.find((e) => e.kind === "user_text");
  assert.equal(event.images.length, 1);
  assert.equal((await api(port, "POST", "/api/sessions", { project: "x", cwd: os.tmpdir(), command: "y", images: [{ mediaType: "image/tiff", data }] })).status, 400);
});

test("imagens: o agy recebe os caminhos no texto; tipo, quantidade e tamanho sao validados", async () => {
  const { engine, port } = await start();
  const id = await createIdle(port, { command: "text:oi", provider: "antigravity" });
  const data = PNG.toString("base64");

  await api(port, "POST", `/api/sessions/${id}/input`, { text: "text:veja", images: [{ mediaType: "image/png", data }] });
  const event = await waitFor(() => engine.sessions.get(id).events.findLast((e) => e.kind === "user_text" && e.images));
  const file = path.join(engine.sessions.get(id).attachmentsDir, id, event.images[0]);
  assert.deepEqual(readFileSync(file), PNG);
  // O agy falso ecoa o texto recebido: o caminho do anexo tem que estar nele.
  const echoed = await waitFor(() => engine.sessions.get(id).events.findLast((e) => e.kind === "assistant_text" && e.text.includes("veja")));
  assert.match(echoed.text, new RegExp(`- ${file.replaceAll(".", "\\.")}`));

  const bad = (images) => api(port, "POST", `/api/sessions/${id}/input`, { text: "x", images });
  assert.equal((await bad([{ mediaType: "image/tiff", data }])).status, 400);
  assert.equal((await bad(Array.from({ length: 7 }, () => ({ mediaType: "image/png", data })))).status, 400);
  assert.equal((await bad([{ mediaType: "image/png", data: Buffer.alloc(5 * 1024 * 1024 + 1).toString("base64") }])).status, 413);
});

test("Antigravity: processo que cai no turno (cota) vira result de erro e a sessao segue com outro modelo", async () => {
  const { engine, port, log } = await start();
  const id = await createIdle(port, { command: "text:oi", provider: "antigravity", model: "claude-y" });

  await api(port, "POST", `/api/sessions/${id}/input`, { text: "quota" });
  const failed = await waitFor(() => engine.sessions.get(id).events.findLast((e) => e.kind === "result" && e.isError));
  assert.match(failed.text, /RESOURCE_EXHAUSTED \(code 429\): Individual quota reached\. Resets in 159h/);
  await waitFor(async () => (await statusOf(port, id)) === "idle");

  assert.equal((await api(port, "POST", `/api/sessions/${id}/model`, { model: "gemini-x" })).status, 200);
  await api(port, "POST", `/api/sessions/${id}/input`, { text: "text:de volta" });
  await waitFor(() => engine.sessions.get(id).events.some((e) => e.kind === "assistant_text" && e.text === "de volta"));
  const spawns = readFileSync(log, "utf8").trim().split("\n").map(JSON.parse);
  assert.equal(spawns.at(-1).args[spawns.at(-1).args.indexOf("--model") + 1], "gemini-x");
});

test("readiness: conta do Claude pelo accountInfo, contas validas do gh e versao do Node", async () => {
  const { spy, port } = await start();
  const res = await api(port, "GET", "/api/readiness");
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.claude, { ok: true, account: "dev@example.com", plan: "max" });
  assert.equal(res.body.node.ok, true);
  assert.equal(typeof res.body.gh.ok, "boolean");
  assert.equal(spy.calls.at(-1).abortController.signal.aborted, true);
});
