import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createEngine } from "../engine.mjs";

const run = promisify(execFile);

async function start(cycleCommand) {
  const sessionsDir = mkdtempSync(path.join(os.tmpdir(), "cycle-"));
  const engine = createEngine({ query: () => { throw new Error("sem sdk"); }, sessionsDir, cycleCommand });
  const server = engine.app.listen(0, "127.0.0.1");
  await new Promise((r) => server.once("listening", r));
  test.after(() => server.close());
  return server.address().port;
}

const post = async (port, project, body) => {
  const res = await fetch(`http://127.0.0.1:${port}/api/projects/${project}/cycle`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, body: res.headers.get("content-type")?.includes("json") ? JSON.parse(text) : text };
};

test("ciclo: repassa a acao ao wf-cycle e valida acao e projeto", async () => {
  const calls = [];
  const port = await start(async (action, project) => calls.push([action, project]));
  assert.deepEqual(await post(port, "demo", { action: "pause" }), { status: 200, body: { ok: true } });
  assert.equal((await post(port, "demo", { action: "apagar" })).status, 400);
  // `..` nem chega na rota: o fetch normaliza o caminho.
  assert.equal((await post(port, "..", { action: "pause" })).status, 404);
  assert.equal((await post(port, "a%20b", { action: "pause" })).status, 400);
  assert.deepEqual(calls, [["pause", "demo"]]);
});

test("ciclo: sem ciclo ativo vira 409 com a mensagem do script", async () => {
  const port = await start(async () => {
    throw Object.assign(new Error("Command failed"), { code: 1, stderr: "sem ciclo ativo em demo\n" });
  });
  assert.deepEqual(await post(port, "demo", { action: "resume" }), {
    status: 409,
    body: { error: "sem ciclo ativo em demo" },
  });
});

test("ciclo: o padrao roda o bin/wf-cycle.py do repo", async () => {
  const home = mkdtempSync(path.join(os.tmpdir(), "cycle-home-"));
  const wf = path.join(home, ".claude", "workflow", "demo");
  mkdirSync(wf, { recursive: true });
  writeFileSync(path.join(wf, "current.json"), JSON.stringify({ feature: "F" }));
  const script = new URL("../../bin/wf-cycle.py", import.meta.url).pathname;
  await run("python3", [script, "pause", "demo"], { env: { ...process.env, CLAUDE_HOME: path.join(home, ".claude") } });
  assert.equal(JSON.parse(readFileSync(path.join(wf, "current.json"), "utf8")).paused, true);
  assert.ok(existsSync(script));
});
