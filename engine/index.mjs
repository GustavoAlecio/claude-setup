import { execFile } from "node:child_process";
import { fstatSync, promises as fs, realpathSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs, promisify } from "node:util";
import { createEngine } from "./engine.mjs";
import { createLog, guardStream, installCrashGuards } from "./log.mjs";

const execFileAsync = promisify(execFile);
const ORPHAN_WAIT_MS = 2500;
const CONSUME_WAIT_MS = 1500;
const HARD_EXIT_MS = 1800;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === "EPERM";
  }
}

/** So um engine anterior recebe o sinal: um pid reaproveitado pelo SO nao tem `--sessions-dir`. */
async function isEngine(pid) {
  try {
    const { stdout } = await execFileAsync("ps", ["-o", "command=", "-p", String(pid)]);
    return stdout.includes("--sessions-dir");
  } catch {
    return false;
  }
}

async function stopOrphan(pidFile, log) {
  let pid;
  try {
    pid = Number.parseInt(await fs.readFile(pidFile, "utf8"), 10);
  } catch {
    return;
  }
  if (!Number.isInteger(pid) || pid <= 0 || pid === process.pid) return;
  if (!(await isEngine(pid))) return;

  log("engine anterior vivo, enviando SIGTERM", pid);
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    return;
  }
  const deadline = Date.now() + ORPHAN_WAIT_MS;
  while (isAlive(pid) && Date.now() < deadline) await sleep(50);
  if (isAlive(pid)) log("engine anterior nao saiu em", ORPHAN_WAIT_MS, "ms", pid);
}

async function writePidFile(pidFile) {
  const tmp = `${pidFile}.${process.pid}.tmp`;
  await fs.writeFile(tmp, String(process.pid));
  await fs.rename(tmp, pidFile);
}

async function removePidFileIfOurs(pidFile) {
  try {
    if ((await fs.readFile(pidFile, "utf8")).trim() === String(process.pid)) await fs.rm(pidFile, { force: true });
  } catch {}
}

/** /dev/null e TTY nunca chegam a um EOF que signifique "o pai morreu"; so pipe e socket. */
function watchesParent(stdin) {
  try {
    const stat = fstatSync(stdin.fd ?? 0);
    return stat.isFIFO() || stat.isSocket();
  } catch {
    return false;
  }
}

export async function main({ argv, query, stdin = process.stdin, stdout = process.stdout }) {
  const log = createLog(process.stderr);
  installCrashGuards(log);
  const out = guardStream(stdout);

  const { values } = parseArgs({
    args: argv,
    options: { port: { type: "string", default: "0" }, "sessions-dir": { type: "string" } },
  });
  const port = Number(values.port);
  if (!values["sessions-dir"] || !Number.isInteger(port) || port < 0) {
    log("uso: node index.mjs --port <n|0> --sessions-dir <dir>");
    process.exit(2);
  }
  const sessionsDir = path.resolve(values["sessions-dir"]);
  const pidFile = path.join(sessionsDir, "engine.pid");

  query ??= (await import("@anthropic-ai/claude-agent-sdk")).query;

  await fs.mkdir(sessionsDir, { recursive: true });
  await stopOrphan(pidFile, log);
  await writePidFile(pidFile);

  const engine = createEngine({ query, sessionsDir, log });
  const restored = await engine.sessions.restore();

  const server = http.createServer(engine.app);
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", resolve);
  }).catch((err) => {
    log("falha ao abrir porta", port, err);
    process.exit(1);
  });

  let shuttingDown = false;
  async function shutdown(reason) {
    if (shuttingDown) return;
    shuttingDown = true;
    log("encerrando:", reason);
    setTimeout(() => process.exit(1), HARD_EXIT_MS).unref();
    server.close();
    try {
      await engine.sessions.shutdown({ waitMs: CONSUME_WAIT_MS });
      await removePidFileIfOurs(pidFile);
    } catch (err) {
      log("falha no encerramento", err);
    }
    process.exit(0);
  }

  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
  if (watchesParent(stdin)) {
    stdin.on("error", () => {});
    stdin.on("end", () => shutdown("stdin EOF"));
    stdin.on("close", () => shutdown("stdin fechado"));
    stdin.resume();
  }

  const { port: bound } = server.address();
  log(`engine pronto port=${bound} pid=${process.pid} sessions=${restored} dir=${sessionsDir}`);
  out.write(`ENGINE_READY ${JSON.stringify({ port: bound, pid: process.pid })}\n`);
  return { port: bound, shutdown };
}

export function runMain(options) {
  main(options).catch((err) => {
    createLog(process.stderr)("falha no boot", err);
    process.exit(1);
  });
}

function isEntrypoint() {
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isEntrypoint()) runMain({ argv: process.argv.slice(2) });
