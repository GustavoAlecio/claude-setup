import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const CLI = fileURLToPath(new URL("./fixtures/fake-cli.mjs", import.meta.url));
const READY = /^ENGINE_READY \{"port":\d+,"pid":\d+\}$/;
const children = new Set();

after(() => {
  for (const child of children) if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
});

const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-test-"));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function spawnEngine(sessionsDir, { stdin = "pipe" } = {}) {
  const child = spawn(process.execPath, [CLI, "--port", "0", "--sessions-dir", sessionsDir], {
    stdio: [stdin, "pipe", "pipe"],
  });
  children.add(child);
  const io = { stdout: "", stderr: "" };
  child.stdout.on("data", (chunk) => (io.stdout += chunk));
  child.stderr.on("data", (chunk) => (io.stderr += chunk));
  const exited = new Promise((resolve) => child.on("exit", (code, signal) => resolve({ code, signal, at: Date.now() })));
  const ready = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`sem ENGINE_READY em 5s\nstderr:\n${io.stderr}`)), 5000);
    const onData = () => {
      const line = io.stdout.split("\n")[0];
      if (!io.stdout.includes("\n")) return;
      clearTimeout(timer);
      child.stdout.off("data", onData);
      resolve(JSON.parse(line.slice("ENGINE_READY ".length)));
    };
    child.stdout.on("data", onData);
    exited.then(({ code }) => reject(new Error(`engine saiu (${code}) antes do ready\nstderr:\n${io.stderr}`)));
  });
  return { child, io, ready, exited };
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
    await sleep(20);
  }
  throw new Error("condicao nao satisfeita a tempo");
}

async function startIdleSession(port, cwd, command = "oi") {
  const created = await api(port, "POST", "/api/sessions", { project: "demo", cwd, command });
  assert.equal(created.status, 200, JSON.stringify(created.body));
  await waitFor(async () => (await api(port, "GET", `/api/sessions/${created.body.id}`)).body.status === "idle");
  return created.body.id;
}

function readSnapshot(dir, id) {
  return JSON.parse(readFileSync(path.join(dir, `${id}.json`), "utf8"));
}

async function stopAndTime(engine, stop) {
  const startedAt = Date.now();
  stop();
  const { code, signal, at } = await engine.exited;
  return { code, signal, elapsed: at - startedAt };
}

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

test("ENGINE_READY e a unica linha do stdout, com porta 0; health responde e nao ha estaticos nem artefatos", async () => {
  const dir = tmpDir();
  const engine = spawnEngine(dir);
  const { port, pid } = await engine.ready;
  assert.equal(pid, engine.child.pid);
  assert.ok(port > 0);

  const health = await api(port, "GET", "/api/health");
  assert.equal(health.status, 200);
  assert.deepEqual(health.body, { ok: true, version: "0.1.0" });
  assert.equal((await api(port, "GET", "/")).status, 404);
  assert.equal((await api(port, "GET", "/api/projects/demo/artifact?path=spec.md")).status, 404);
  assert.equal(readFileSync(path.join(dir, "engine.pid"), "utf8"), String(pid));

  const { code } = await stopAndTime(engine, () => engine.child.kill("SIGTERM"));
  assert.equal(code, 0);
  const lines = engine.io.stdout.split("\n").filter(Boolean);
  assert.equal(lines.length, 1, engine.io.stdout);
  assert.match(lines[0], READY);
});

test("SIGTERM grava o snapshot com o result e sai com 0 em ate 2s", async () => {
  const dir = tmpDir();
  const engine = spawnEngine(dir);
  const { port } = await engine.ready;
  const id = await startIdleSession(port, dir);

  const { code, elapsed } = await stopAndTime(engine, () => engine.child.kill("SIGTERM"));
  assert.equal(code, 0, engine.io.stderr);
  assert.ok(elapsed <= 2000, `levou ${elapsed}ms`);
  const snapshot = readSnapshot(dir, id);
  assert.ok(snapshot.events.some((e) => e.kind === "result" && e.text === "ola mundo"));
});

test("fim do stdin grava o snapshot com o result e sai com 0 em ate 2s", async () => {
  const dir = tmpDir();
  const engine = spawnEngine(dir);
  const { port } = await engine.ready;
  const id = await startIdleSession(port, dir);

  const { code, elapsed } = await stopAndTime(engine, () => engine.child.stdin.end());
  assert.equal(code, 0, engine.io.stderr);
  assert.ok(elapsed <= 2000, `levou ${elapsed}ms`);
  assert.ok(readSnapshot(dir, id).events.some((e) => e.kind === "result"));
});

test("SIGTERM com turno em andamento aborta a sessao e sai com 0 em ate 2s", async () => {
  const dir = tmpDir();
  const engine = spawnEngine(dir);
  const { port } = await engine.ready;
  const created = await api(port, "POST", "/api/sessions", { project: "demo", cwd: dir, command: "slow" });
  await waitFor(async () => (await api(port, "GET", `/api/sessions/${created.body.id}`)).body.status === "running");

  const { code, elapsed } = await stopAndTime(engine, () => engine.child.kill("SIGTERM"));
  assert.equal(code, 0, engine.io.stderr);
  assert.ok(elapsed <= 2000, `levou ${elapsed}ms`);
  assert.ok(readSnapshot(dir, created.body.id).events.some((e) => e.kind === "user_text" && e.text === "slow"));
});

test("engine orfao no mesmo diretorio recebe SIGTERM antes do novo carregar as sessoes", async () => {
  const dir = tmpDir();
  const first = spawnEngine(dir);
  const { port } = await first.ready;
  const id = await startIdleSession(port, dir);

  const second = spawnEngine(dir);
  const ready = await second.ready;
  const { code } = await first.exited;
  assert.equal(code, 0, first.io.stderr);
  assert.equal(readFileSync(path.join(dir, "engine.pid"), "utf8"), String(ready.pid));

  const restored = await api(ready.port, "GET", `/api/sessions/${id}`);
  assert.equal(restored.body.status, "detached");
  assert.equal(restored.body.events, readSnapshot(dir, id).events.length);

  second.child.kill("SIGTERM");
  assert.equal((await second.exited).code, 0);
});

test("pid gravado de um processo que nao e engine nao recebe sinal", async () => {
  const dir = tmpDir();
  const bystander = spawn("sleep", ["30"], { stdio: "ignore" });
  children.add(bystander);
  writeFileSync(path.join(dir, "engine.pid"), String(bystander.pid));

  const engine = spawnEngine(dir);
  await engine.ready;
  assert.ok(isAlive(bystander.pid));

  engine.child.kill("SIGTERM");
  await engine.exited;
  bystander.kill("SIGKILL");
});

test("stdin em /dev/null nao encerra o engine", async () => {
  const dir = tmpDir();
  const engine = spawnEngine(dir, { stdin: "ignore" });
  const { port } = await engine.ready;
  await sleep(500);
  assert.equal(engine.child.exitCode, null);
  assert.equal((await api(port, "GET", "/api/health")).status, 200);

  engine.child.kill("SIGTERM");
  assert.equal((await engine.exited).code, 0);
});

test("EPIPE em stdout/stderr nao derruba o engine", async () => {
  const dir = tmpDir();
  const engine = spawnEngine(dir);
  const { port } = await engine.ready;
  engine.child.stdout.destroy();
  engine.child.stderr.destroy();
  await sleep(50);

  for (let i = 0; i < 3; i++) await startIdleSession(port, dir);
  assert.equal((await api(port, "POST", "/api/sessions", { project: "x/..", command: "oi" })).status, 400);
  await sleep(100);
  assert.equal(engine.child.exitCode, null);
  assert.equal((await api(port, "GET", "/api/health")).status, 200);

  const { code } = await stopAndTime(engine, () => engine.child.kill("SIGTERM"));
  assert.equal(code, 0);
});
