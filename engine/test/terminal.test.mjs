import { test, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, utimesSync, writeFileSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { query } from "./fixtures/fake-sdk.mjs";

const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-terminal-"));
const claudeHome = tmpDir();
process.env.CLAUDE_HOME = claudeHome;
process.env.CLAUDE_WEB_SCAN_ROOTS = tmpDir();

const { createEngine } = await import("../engine.mjs");
const { humanText, listTerminalSessions, liveTerminalSessions, projectDirOf, transcriptEvents } = await import("../terminal.mjs");

const repo = tmpDir();
const ID_A = "11111111-1111-4111-8111-111111111111";
const ID_B = "22222222-2222-4222-8222-222222222222";
const ID_LIVE = "33333333-3333-4333-8333-333333333333";

const user = (content, extra = {}) => ({ type: "user", timestamp: "2026-10-16T10:00:00Z", cwd: repo, message: { role: "user", content }, ...extra });
const assistant = (content) => ({ type: "assistant", timestamp: "2026-10-16T10:00:05Z", cwd: repo, message: { model: "claude-opus-5-5", content } });

function transcript(id, lines, mtime, cwd = repo) {
  const dir = projectDirOf(claudeHome, cwd);
  mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${id}.jsonl`);
  writeFileSync(file, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  utimesSync(file, mtime, mtime);
}

transcript(
  ID_A,
  [
    { type: "permission-mode", permissionMode: "default" },
    user("<local-command-caveat>Caveat</local-command-caveat>", { isMeta: true }),
    user("como funciona o greet?"),
    assistant([
      { type: "thinking", thinking: "olhar main.go" },
      { type: "text", text: "Vou ler." },
      { type: "tool_use", id: "t1", name: "Read", input: { file_path: "main.go" } },
    ]),
    user([{ type: "tool_result", tool_use_id: "t1", content: "x".repeat(5000) }]),
    user("subagente", { isSidechain: true }),
    user("<command-name>/kickoff</command-name><command-args>--manual idioma</command-args>"),
    user("<bash-stdout>ok</bash-stdout>"),
    assistant([{ type: "text", text: "Kickoff feito." }]),
    { type: "ai-title", aiTitle: "Greet com idioma", sessionId: ID_A },
  ],
  new Date("2026-10-16T10:00:00Z")
);
transcript(ID_B, [user("sessao antiga")], new Date("2026-10-10T10:00:00Z"));
const ID_SUB = "55555555-5555-4555-8555-555555555555";
const ID_SIBLING = "66666666-6666-4666-8666-666666666666";
transcript("77777777-7777-4777-8777-777777777777", [user("Responda ok", { entrypoint: "sdk-cli" })], new Date("2026-10-16T12:00:00Z"));
transcript(ID_SUB, [user("no pacote", { cwd: path.join(repo, "pkg") })], new Date("2026-10-09T10:00:00Z"), path.join(repo, "pkg"));
// `<repo>-x` codifica igual a `<repo>/x`: o cwd do transcript diz que e outro projeto.
transcript(ID_SIBLING, [user("vizinho", { cwd: `${repo}-x` })], new Date("2026-10-09T09:00:00Z"), `${repo}-x`);
transcript(ID_LIVE, [user("aberta no terminal")], new Date("2026-10-16T11:00:00Z"));
mkdirSync(path.join(claudeHome, "sessions"), { recursive: true });
writeFileSync(path.join(claudeHome, "sessions", `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: ID_LIVE, status: "idle" }));
writeFileSync(path.join(claudeHome, "sessions", "999999.json"), JSON.stringify({ pid: 999999, sessionId: ID_B, status: "busy" }));

const servers = new Set();
const engines = new Set();
after(async () => {
  for (const engine of engines) await engine.sessions.shutdown({ waitMs: 200 });
  for (const server of servers) {
    server.closeAllConnections();
    server.close();
  }
});

async function start() {
  const engine = createEngine({ query, sessionsDir: tmpDir() });
  engines.add(engine);
  await engine.sessions.restore();
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { engine, port: server.address().port };
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
    if (await check()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("condicao nao satisfeita a tempo");
}

test("humanText: comandos viram /skill args; meta, sidechain e saidas do CLI ficam de fora", () => {
  assert.equal(humanText(user("oi")), "oi");
  assert.equal(humanText(user("<command-name>/plan</command-name><command-args></command-args>")), "/plan");
  assert.equal(humanText(user("oi", { isMeta: true })), null);
  assert.equal(humanText(user("oi", { isSidechain: true })), null);
  assert.equal(humanText(user("<bash-input>ls</bash-input>")), null);
  assert.equal(humanText(user([{ type: "tool_result", tool_use_id: "x", content: "r" }])), null);
  assert.equal(humanText(user([{ type: "text", text: "com imagem" }, { type: "image" }])), "com imagem");
});

test("lista do cwd: mais recente primeiro, titulo do ai-title, viva so com pid vivo, sem os excluidos", async () => {
  const list = await listTerminalSessions(claudeHome, repo);
  assert.deepEqual(list.map((s) => s.sdkSessionId), [ID_LIVE, ID_A, ID_B, ID_SUB]);
  assert.equal(list[3].cwd, path.join(repo, "pkg"));
  assert.equal(list[0].cwd, repo);
  assert.equal(list[1].title, "Greet com idioma");
  assert.equal(list[1].firstPrompt, "como funciona o greet?");
  assert.equal(list[0].live, "idle");
  assert.equal(list[2].live, null, "pid morto nao conta");
  assert.deepEqual((await listTerminalSessions(claudeHome, repo, { exclude: new Set([ID_A]) })).map((s) => s.sdkSessionId), [ID_LIVE, ID_B, ID_SUB]);
  assert.deepEqual(await listTerminalSessions(claudeHome, path.join(repo, "nada")), []);
  assert.deepEqual([...liveTerminalSessions(claudeHome).keys()], [ID_LIVE]);
});

test("transcript vira eventos no formato do engine, com tool_result cortado", async () => {
  const { events, model, createdAt, dropped, firstPrompt } = await transcriptEvents(claudeHome, repo, ID_A);
  assert.equal(firstPrompt, "como funciona o greet?");
  assert.deepEqual(events.map((e) => e.kind), ["user_text", "thinking", "assistant_text", "tool_use", "tool_result", "user_text", "assistant_text"]);
  assert.equal(events[5].text, "/kickoff --manual idioma");
  assert.ok(events[4].text.length < 4100);
  assert.equal(model, "claude-opus-5-5");
  assert.equal(createdAt, "2026-10-16T10:00:00Z");
  assert.equal(dropped, 0);
});

test("importar cria sessao detached com o historico, some da lista, e e idempotente", async () => {
  const { engine, port } = await start();
  const body = { sdkSessionId: ID_A, cwd: repo, project: "sandbox" };
  const imported = await api(port, "POST", "/api/sessions/import", body);
  assert.equal(imported.status, 200, JSON.stringify(imported.body));
  assert.equal(imported.body.status, "detached");
  assert.equal(imported.body.resumable, true);
  assert.equal(imported.body.title, "como funciona o greet?");
  assert.equal(imported.body.skill, "/kickoff");
  assert.equal(engine.sessions.get(imported.body.id).events.at(-1).kind, "imported");

  assert.equal((await api(port, "POST", "/api/sessions/import", body)).body.id, imported.body.id);
  const listed = (await api(port, "GET", `/api/terminal-sessions?cwd=${encodeURIComponent(repo)}`)).body;
  assert.deepEqual(listed.map((s) => s.sdkSessionId), [ID_LIVE, ID_B, ID_SUB]);

  assert.equal((await api(port, "POST", "/api/sessions/import", { ...body, sdkSessionId: "../x" })).status, 400);
  assert.equal((await api(port, "POST", "/api/sessions/import", { ...body, sdkSessionId: "44444444-4444-4444-8444-444444444444" })).status, 404);
  assert.equal((await api(port, "GET", "/api/terminal-sessions?cwd=relativo")).status, 400);
});

test("resume de transcript fechado continua nele; de um vivo no terminal, num fork", async () => {
  const { engine, port } = await start();
  for (const [id, forked] of [[ID_B, false], [ID_LIVE, true]]) {
    const { body } = await api(port, "POST", "/api/sessions/import", { sdkSessionId: id, cwd: repo, project: "sandbox" });
    const session = engine.sessions.get(body.id);
    await api(port, "POST", `/api/sessions/${body.id}/resume`);
    assert.equal(session.events.at(-1).forked, forked ? true : undefined);
    await api(port, "POST", `/api/sessions/${body.id}/input`, { text: "continua" });
    await waitFor(() => session.events.some((e) => e.kind === "result"));
    assert.equal(session.sdkSessionId === id, !forked, id);
  }
});

test("open-terminal vai para os apps conectados no stream global; sem app e 409", async () => {
  const { port } = await start();
  const body = { sdkSessionId: ID_A, cwd: repo };
  assert.equal((await api(port, "POST", "/api/ui/open-terminal", body)).status, 409);
  assert.deepEqual((await api(port, "GET", "/api/ui")).body, { clients: 0 });

  const controller = new AbortController();
  const res = await fetch(`http://127.0.0.1:${port}/api/sessions/stream`, { signal: controller.signal });
  const reader = res.body.getReader();
  let text = "";
  const read = async (needle) => {
    while (!text.includes(needle)) text += new TextDecoder().decode((await reader.read()).value);
  };
  await read("snapshot");
  assert.deepEqual((await api(port, "GET", "/api/ui")).body, { clients: 1 });
  assert.equal((await api(port, "POST", "/api/ui/open-terminal", body)).status, 200);
  await read("open-terminal");
  assert.ok(text.includes(`event: open-terminal\ndata: ${JSON.stringify(body)}`), text);
  assert.equal((await api(port, "POST", "/api/ui/open-terminal", { ...body, cwd: "relativo" })).status, 400);
  controller.abort();
});

test("reimport traz os turnos novos do terminal enquanto o app nao conversou; depois disso nao mexe", async () => {
  const { engine, port } = await start();
  const id = "88888888-8888-4888-8888-888888888888";
  const t = (m) => ({ timestamp: `2026-10-16T09:0${m}:00Z` });
  const turn1 = [user("primeiro", t(0)), { ...assistant([{ type: "text", text: "r1" }]), ...t(1) }];
  transcript(id, turn1, new Date("2026-10-16T09:00:00Z"));
  const body = { sdkSessionId: id, cwd: repo, project: "sandbox" };
  const first = (await api(port, "POST", "/api/sessions/import", body)).body;
  const session = engine.sessions.get(first.id);
  assert.deepEqual(session.events.map((e) => e.kind), ["user_text", "assistant_text", "imported"]);

  // Retomado (o terminal esta vivo? nao: fecha no lugar) mas sem mensagem: o processo para e volta a detached.
  await api(port, "POST", `/api/sessions/${first.id}/resume`);
  assert.ok(session.query);
  transcript(id, [...turn1, user("segundo", t(2)), { ...assistant([{ type: "text", text: "r2" }]), ...t(3) }], new Date("2026-10-16T09:05:00Z"));
  const again = (await api(port, "POST", "/api/sessions/import", body)).body;
  assert.equal(again.id, first.id);
  assert.equal(again.status, "detached");
  assert.deepEqual(session.events.map((e) => e.kind).slice(-3), ["user_text", "assistant_text", "imported"]);
  assert.equal(session.events.at(-3).text, "segundo");
  const count = session.events.length;
  assert.equal((await api(port, "POST", "/api/sessions/import", body)).body.id, first.id);
  assert.equal(session.events.length, count, "sem turnos novos, nada muda");

  await api(port, "POST", `/api/sessions/${first.id}/resume`);
  await api(port, "POST", `/api/sessions/${first.id}/input`, { text: "do app" });
  await waitFor(() => session.events.some((e) => e.kind === "result"));
  transcript(id, [...turn1, user("segundo", t(2)), user("terceiro", t(4)), user("quarto", t(5))], new Date("2026-10-16T09:10:00Z"));
  const after = session.events.length;
  await api(port, "POST", "/api/sessions/import", body);
  assert.equal(session.events.length, after, "o app ja conversou: o reimport nao copia nada");
});
