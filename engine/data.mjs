import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";

export const CLAUDE_HOME = process.env.CLAUDE_HOME || path.join(os.homedir(), ".claude");
export const WORKFLOW_ROOT = path.join(CLAUDE_HOME, "workflow");
const SKILLS_ROOT = path.join(CLAUDE_HOME, "skills");

const SAFE_SEGMENT = /^[A-Za-z0-9._-]+$/;

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function safeSegment(name) {
  if (typeof name !== "string" || name === "." || name === ".." || !SAFE_SEGMENT.test(name)) {
    throw new HttpError(400, `invalid name: ${name}`);
  }
  return name;
}

/** `current.json` do projeto, ou null quando ausente/ilegivel. 404 so quando o projeto nao existe. */
export async function readCurrent(name) {
  const dir = path.join(WORKFLOW_ROOT, safeSegment(name));
  try {
    await fs.access(dir);
  } catch {
    throw new HttpError(404, `project not found: ${name}`);
  }
  try {
    return JSON.parse(await fs.readFile(path.join(dir, "current.json"), "utf8"));
  } catch {
    return null;
  }
}

const KEY_LINE = /^([A-Za-z_][A-Za-z0-9_-]*):(?:[ \t]+(.*))?$/;

function unquote(value) {
  const quote = value[0];
  let out = "";
  for (let i = 1; i < value.length; i++) {
    const c = value[i];
    if (quote === '"' && c === "\\" && i + 1 < value.length) {
      const n = value[++i];
      out += n === "n" ? "\n" : n === "t" ? "\t" : n === '"' || n === "\\" ? n : c + n;
    } else if (c === quote) {
      if (quote === "'" && value[i + 1] === "'") {
        out += "'";
        i++;
      } else {
        return out;
      }
    } else {
      out += c;
    }
  }
  return value;
}

/** Subconjunto de YAML das skills: escalar, aspas ("..." / '...'), blocos `>`/`>-`/`|`/`|-`; o resto e ignorado. */
export function parseFrontmatter(raw) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(raw);
  if (!match) return {};
  const lines = match[1].split(/\r?\n/);
  const out = {};
  for (let i = 0; i < lines.length; i++) {
    const kv = KEY_LINE.exec(lines[i].trimEnd());
    if (!kv) continue;
    const value = (kv[2] ?? "").trim();
    const body = [];
    while (i + 1 < lines.length && (lines[i + 1].trim() === "" || /^[ \t]/.test(lines[i + 1]))) body.push(lines[++i]);
    if (/^[>|]-?$/.test(value)) {
      const text = body.filter((l) => l.trim() !== "");
      const indent = Math.min(...text.map((l) => l.length - l.trimStart().length));
      const parts = text.map((l) => l.slice(indent).trimEnd());
      out[kv[1]] = value.startsWith(">") ? parts.join(" ") : parts.join("\n");
    } else if (value.startsWith('"') || value.startsWith("'")) {
      out[kv[1]] = unquote(value);
    } else {
      out[kv[1]] = value;
    }
  }
  return out;
}

export async function listSkills() {
  let entries;
  try {
    entries = await fs.readdir(SKILLS_ROOT, { withFileTypes: true });
  } catch {
    return [];
  }
  const skills = await Promise.all(
    entries
      .filter((e) => e.isDirectory() || e.isSymbolicLink())
      .map(async (entry) => {
        let raw;
        try {
          raw = await fs.readFile(path.join(SKILLS_ROOT, entry.name, "SKILL.md"), "utf8");
        } catch {
          return null;
        }
        const fm = parseFrontmatter(raw);
        return { name: fm.name || entry.name, description: fm.description || "", model: fm.model || null };
      })
  );
  return skills.filter(Boolean).sort((a, b) => a.name.localeCompare(b.name));
}
