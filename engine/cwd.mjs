import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { WORKFLOW_ROOT, safeSegment } from "./data.mjs";

const CONFIG = path.join(WORKFLOW_ROOT, ".dashboard.json");
const SCAN_ROOTS = (process.env.CLAUDE_WEB_SCAN_ROOTS ?? path.join(os.homedir(), "development")).split(":");
const SKIP = new Set(["node_modules", ".git", "build", "dist", "Pods", ".dart_tool", "vendor", "target"]);

export async function readConfig() {
  try {
    return JSON.parse(await fs.readFile(CONFIG, "utf8"));
  } catch {
    return { cwds: {} };
  }
}

async function isDir(dir) {
  try {
    return (await fs.stat(dir)).isDirectory();
  } catch {
    return false;
  }
}

/** `level` e a profundidade abaixo da raiz varrida (`<raiz>/x` e 0), como `ScanCandidate.depth` no app. */
async function scan(root, target, depth, out, level = 0) {
  if (depth < 0 || out.length >= 8) return;
  let entries;
  try {
    entries = await fs.readdir(root, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith(".") || SKIP.has(entry.name)) continue;
    const full = path.join(root, entry.name);
    if (entry.name === target) out.push({ dir: full, level });
    else await scan(full, target, depth - 1, out, level + 1);
  }
}

/**
 * project_path do current.json > override salvo pelo usuario > varredura das raizes de dev. Na varredura
 * vence o candidato mais raso; empate no nivel mais raso nao escolhe nenhum (mesma regra de `resolvePath`).
 */
export async function resolveCwd(project, current) {
  const name = safeSegment(project);
  const config = await readConfig();
  const override = config.cwds?.[name];

  const candidates = [];
  if (current?.project_path && (await isDir(current.project_path))) candidates.push(current.project_path);
  if (override && (await isDir(override)) && !candidates.includes(override)) candidates.push(override);
  const preferred = candidates[0];

  const scanned = [];
  for (const root of SCAN_ROOTS) {
    const found = [];
    await scan(root, name, 3, found);
    scanned.push(...found);
  }
  scanned.sort((a, b) => a.level - b.level);
  for (const { dir } of scanned) if (!candidates.includes(dir)) candidates.push(dir);

  const [first, second] = scanned;
  const tie = second !== undefined && first.level === second.level && first.dir !== second.dir;
  const shallowest = tie ? undefined : first?.dir;
  return { cwd: override ?? preferred ?? shallowest ?? null, candidates, override: override ?? null };
}
