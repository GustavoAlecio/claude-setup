import { execFile } from "node:child_process";
import { existsSync, promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { HttpError } from "./data.mjs";

const execFileAsync = promisify(execFile);

export const DEFAULT_ACCOUNT = "default";
export const ACCOUNT = /^[a-z0-9][a-z0-9._-]{0,62}$/i;

const GATE_SCRIPT = fileURLToPath(new URL("./agy-gate.mjs", import.meta.url));
// Maior que qualquer espera humana: estourar nega a tool (fail-closed) e o card some no app.
const GATE_TIMEOUT_S = 86_400;
const TOKEN_FILE = path.join(".gemini", "antigravity-cli", "antigravity-oauth-token");

/** `undefined`/`null` viram a conta default; o nome vira diretório, então só o formato de [ACCOUNT]. */
export function accountParam(value) {
  if (value === undefined || value === null) return DEFAULT_ACCOUNT;
  if (typeof value !== "string" || !ACCOUNT.test(value) || value === "." || value === "..") {
    throw new HttpError(400, "conta inválida");
  }
  return value;
}

/** Binário do `agy`: o app herda o PATH do launchd, que não tem `~/.local/bin`. */
export function agyBin(env = process.env, home = os.homedir()) {
  if (env.AGY_BIN) return env.AGY_BIN;
  const local = path.join(home, ".local", "bin", "agy");
  return existsSync(local) ? local : "agy";
}

/**
 * Espelha [src] em [dst] por symlinks, menos [skip]. Entradas reais em [dst] (criadas por ferramentas
 * rodando com o HOME sombra) ficam; links para o que sumiu da origem ou passou a ser pulado saem.
 */
async function mirror(src, dst, skip) {
  await fs.mkdir(dst, { recursive: true });
  const wanted = new Set((await fs.readdir(src)).filter((name) => !skip.has(name)));
  for (const name of await fs.readdir(dst)) {
    if (wanted.has(name)) continue;
    const entry = path.join(dst, name);
    if ((await fs.lstat(entry)).isSymbolicLink()) await fs.unlink(entry);
  }
  for (const name of wanted) {
    const target = path.join(src, name);
    const link = path.join(dst, name);
    const stat = await fs.lstat(link).catch(() => null);
    if (stat && !stat.isSymbolicLink()) continue;
    if (stat && (await fs.readlink(link)) === target) continue;
    if (stat) await fs.unlink(link);
    await fs.symlink(target, link);
  }
}

/**
 * HOMEs sombra do `agy`, um por conta. O token de uma conta não-default fica em arquivo dentro do seu
 * HOME porque o `agy` não alcança o Keychain sem `Library/Keychains`; a default o alcança e usa o login
 * da IDE. O hook do gate só existe aqui dentro, nunca no `~/.gemini` real.
 */
const shellQuote = (s) => `'${s.replaceAll("'", "'\\''")}'`;

export function createAccounts({
  home = os.homedir(),
  root = path.join(home, ".claude-flow", "accounts", "antigravity"),
  nodeBin = process.execPath,
  open = (file) => execFileAsync("open", ["-a", "Terminal", file], { timeout: 10_000 }),
} = {}) {
  const dirFor = (account) => path.join(root, account);

  async function prepare(account) {
    const dir = dirFor(account);
    await mirror(home, dir, new Set([".gemini", ".claude-flow", "Library"]));
    if (existsSync(path.join(home, "Library"))) {
      await mirror(path.join(home, "Library"), path.join(dir, "Library"), new Set(account === DEFAULT_ACCOUNT ? [] : ["Keychains"]));
    }
    const config = path.join(dir, ".gemini", "config");
    await fs.mkdir(config, { recursive: true });
    const hooks = {
      "claude-flow-gate": {
        enabled: true,
        PreToolUse: [{ matcher: "*", hooks: [{ type: "command", command: `"${nodeBin}" "${GATE_SCRIPT}"`, timeout: GATE_TIMEOUT_S }] }],
      },
    };
    const tmp = path.join(config, `hooks.json.${process.pid}.tmp`);
    await fs.writeFile(tmp, JSON.stringify(hooks, null, 2));
    await fs.rename(tmp, path.join(config, "hooks.json"));
    return dir;
  }

  async function loggedIn(account) {
    if (account !== DEFAULT_ACCOUNT) return existsSync(path.join(dirFor(account), TOKEN_FILE));
    try {
      await execFileAsync("security", ["find-generic-password", "-s", "gemini", "-a", "antigravity"], { timeout: 5000 });
      return true;
    } catch {
      return false;
    }
  }

  /** Login exige TTY: o app mostra o comando e o usuário roda no terminal. */
  async function status(account) {
    const dir = await prepare(account);
    return {
      account,
      home: dir,
      loggedIn: await loggedIn(account),
      loginCommand: `HOME=${JSON.stringify(dir)} ${JSON.stringify(agyBin(process.env, home))}`,
    };
  }

  /**
   * Abre o Terminal já no `agy` da conta: o login do Google exige TTY. Um `.command` aberto pelo `open` dispensa a
   * permissão de AppleEvents que um `osascript` pediria ao app.
   */
  async function login(account) {
    const dir = await prepare(account);
    const script = path.join(root, `${account}.login.command`);
    const lines = [
      "#!/bin/zsh",
      "clear",
      `echo ${shellQuote(`Antigravity · conta ${account}`)}`,
      `echo ${shellQuote("Entre com a conta Google desta org. Depois do login, saia com /quit ou Ctrl+C.")}`,
      `HOME=${shellQuote(dir)} exec ${shellQuote(agyBin(process.env, home))}`,
    ];
    await fs.writeFile(script, `${lines.join("\n")}\n`, { mode: 0o755 });
    await fs.chmod(script, 0o755);
    await open(script);
    return { opened: true };
  }

  return { dirFor, prepare, loggedIn, status, login };
}
