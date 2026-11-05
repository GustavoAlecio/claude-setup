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

function parseFrontmatter(raw) {
  const match = /^---\n([\s\S]*?)\n---/.exec(raw);
  if (!match) return {};
  const out = {};
  for (const line of match[1].split("\n")) {
    const kv = /^([A-Za-z_-]+):\s*(.*)$/.exec(line);
    if (kv) out[kv[1]] = kv[2].replace(/^["']|["']$/g, "");
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
