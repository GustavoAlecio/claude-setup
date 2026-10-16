import { createReadStream, promises as fs, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import readline from "node:readline";

/**
 * Sessoes do Claude Code no terminal. O CLI grava o transcript em `projects/<cwd>/<sdkSessionId>.jsonl` e, enquanto
 * o processo vive, `sessions/<pid>.json` com `sessionId` e `status`. Os dois formatos sao internos do CLI: o que
 * nao casar com o esperado e ignorado, nunca vira erro.
 */

const LIST_LIMIT = 20;
const HEAD_BYTES = 256 * 1024;
const TAIL_BYTES = 128 * 1024;
const MAX_EVENTS = 600;
const MAX_RESULT_CHARS = 4000;

const encodeCwd = (cwd) => cwd.replace(/[^A-Za-z0-9._-]/g, "-");

export const projectDirOf = (claudeHome, cwd) => path.join(claudeHome, "projects", encodeCwd(cwd));

const isAlive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === "EPERM";
  }
};

/** `sdkSessionId -> status` (`busy`/`idle`/...) das sessoes com processo vivo no terminal. */
export function liveTerminalSessions(claudeHome, alive = isAlive) {
  const live = new Map();
  let names;
  try {
    names = readdirSync(path.join(claudeHome, "sessions"));
  } catch {
    return live;
  }
  for (const name of names) {
    if (!/^\d+\.json$/.test(name)) continue;
    try {
      const info = JSON.parse(readFileSync(path.join(claudeHome, "sessions", name), "utf8"));
      if (typeof info.sessionId === "string" && Number.isInteger(info.pid) && alive(info.pid)) {
        live.set(info.sessionId, typeof info.status === "string" ? info.status : "unknown");
      }
    } catch {
      // Arquivo sendo reescrito pelo CLI: fica para a proxima leitura.
    }
  }
  return live;
}

async function readSlice(file, start, length) {
  const handle = await fs.open(file, "r");
  try {
    const buffer = Buffer.alloc(length);
    const { bytesRead } = await handle.read(buffer, 0, length, start);
    return buffer.subarray(0, bytesRead).toString("utf8");
  } finally {
    await handle.close();
  }
}

function parseLines(text) {
  const out = [];
  for (const line of text.split("\n")) {
    try {
      out.push(JSON.parse(line));
    } catch {
      // Primeira e ultima linha do recorte podem vir cortadas.
    }
  }
  return out;
}

/** Texto que o usuario digitou; `null` para injecoes do CLI (meta, saida de `!cmd`, lembretes). */
export function humanText(line) {
  if (line.type !== "user" || line.isSidechain || line.isMeta) return null;
  const content = line.message?.content;
  const text = typeof content === "string"
    ? content
    : Array.isArray(content) && content.every((b) => b.type === "text" || b.type === "image")
      ? content.filter((b) => b.type === "text").map((b) => b.text).join("\n")
      : null;
  if (!text?.trim()) return null;
  const command = /<command-name>([^<]+)<\/command-name>/.exec(text);
  if (command) {
    const args = /<command-args>([^<]*)<\/command-args>/.exec(text)?.[1]?.trim();
    return args ? `${command[1].trim()} ${args}` : command[1].trim();
  }
  return text.trimStart().startsWith("<") ? null : text;
}

async function summarize(file, sdkSessionId, stat, live) {
  const head = parseLines(await readSlice(file, 0, Math.min(stat.size, HEAD_BYTES)));
  const tailStart = Math.max(0, stat.size - TAIL_BYTES);
  const tail = tailStart === 0 ? head : parseLines(await readSlice(file, tailStart, stat.size - tailStart));
  // `sdk-*` sao processos de programas (o proprio engine, scripts), nao conversas de alguem num terminal.
  if (head.find((l) => typeof l.entrypoint === "string")?.entrypoint.startsWith("sdk")) return null;
  const cwd = head.find((l) => typeof l.cwd === "string")?.cwd ?? null;
  const first = head.map(humanText).find(Boolean) ?? null;
  const aiTitle = tail.findLast((l) => l.type === "ai-title" && typeof l.aiTitle === "string")?.aiTitle ?? null;
  if (!first && !aiTitle) return null;
  return {
    sdkSessionId,
    cwd,
    title: aiTitle ?? first,
    firstPrompt: first,
    updatedAt: stat.mtime.toISOString(),
    live: live.get(sdkSessionId) ?? null,
  };
}

const insideOf = (root, cwd) => cwd === root || cwd.startsWith(`${root}/`);

/**
 * As sessoes mais recentes de [root] e das suas subpastas (o terminal costuma abrir num pacote do repo), sem as que
 * [exclude] ja conhece (as do proprio engine). O diretorio codificado e ambiguo (`a-b` vem de `/a/b` e de `/a-b`):
 * quem decide e o `cwd` gravado no transcript.
 */
export async function listTerminalSessions(claudeHome, root, { exclude = new Set(), alive } = {}) {
  const projects = path.join(claudeHome, "projects");
  const prefix = encodeCwd(root);
  let dirs;
  try {
    dirs = (await fs.readdir(projects)).filter((d) => d === prefix || d.startsWith(`${prefix}-`));
  } catch {
    return [];
  }
  const files = [];
  for (const dir of dirs) {
    const names = await fs.readdir(path.join(projects, dir)).catch(() => []);
    for (const name of names) {
      const id = name.endsWith(".jsonl") ? name.slice(0, -6) : null;
      if (!id || exclude.has(id)) continue;
      const file = path.join(projects, dir, name);
      const stat = await fs.stat(file).catch(() => null);
      if (stat?.isFile() && stat.size > 0) files.push({ id, file, stat, exact: dir === prefix });
    }
  }
  files.sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);
  const live = liveTerminalSessions(claudeHome, alive);
  const out = [];
  for (const { id, file, stat, exact } of files) {
    if (out.length === LIST_LIMIT) break;
    const summary = await summarize(file, id, stat, live).catch(() => null);
    if (!summary) continue;
    const cwd = summary.cwd ?? (exact ? root : null);
    if (cwd && insideOf(root, cwd)) out.push({ ...summary, cwd });
  }
  return out;
}

function resultText(block) {
  const text = typeof block.content === "string"
    ? block.content
    : (block.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("\n");
  return text.length > MAX_RESULT_CHARS ? `${text.slice(0, MAX_RESULT_CHARS)}\n…` : text;
}

/**
 * Eventos do engine a partir do transcript, no mesmo formato que `Session.handle` emite. So a linha principal
 * (sem subagentes) e so as ultimas [MAX_EVENTS]: o snapshot da sessao vai inteiro para o disco e para o app.
 */
export async function transcriptEvents(claudeHome, cwd, sdkSessionId) {
  const file = path.join(projectDirOf(claudeHome, cwd), `${sdkSessionId}.jsonl`);
  const events = [];
  let createdAt = null;
  let model = null;
  let firstPrompt = null;
  const lines = readline.createInterface({ input: createReadStream(file, "utf8"), crlfDelay: Infinity });
  for await (const raw of lines) {
    let line;
    try {
      line = JSON.parse(raw);
    } catch {
      continue;
    }
    if (line.isSidechain) continue;
    const at = typeof line.timestamp === "string" ? line.timestamp : null;
    if (at && !createdAt) createdAt = at;
    if (line.type === "user") {
      const text = humanText(line);
      if (text) {
        firstPrompt ??= text;
        events.push({ at, kind: "user_text", text });
        continue;
      }
      if (!Array.isArray(line.message?.content)) continue;
      for (const block of line.message.content) {
        if (block.type === "tool_result") {
          events.push({ at, kind: "tool_result", id: block.tool_use_id, isError: Boolean(block.is_error), text: resultText(block) });
        }
      }
    } else if (line.type === "assistant") {
      model = line.message?.model ?? model;
      for (const block of line.message?.content ?? []) {
        if (block.type === "text" && block.text?.trim()) events.push({ at, kind: "assistant_text", text: block.text });
        else if (block.type === "thinking" && block.thinking?.trim()) events.push({ at, kind: "thinking", text: block.thinking });
        else if (block.type === "tool_use") events.push({ at, kind: "tool_use", id: block.id, name: block.name, input: block.input });
      }
    }
  }
  const kept = events.slice(-MAX_EVENTS);
  return {
    createdAt,
    model,
    // O titulo da sessao no app: o primeiro pedido da conversa, mesmo quando ele ficou fora de [events].
    firstPrompt,
    dropped: events.length - kept.length,
    events: kept,
  };
}
