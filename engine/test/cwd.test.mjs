import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

// cwd.mjs resolve as raizes no import: o ambiente tem que existir antes.
const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-cwd-"));
const claudeHome = tmpDir();
const scanRoot = tmpDir();
mkdirSync(path.join(claudeHome, "workflow"), { recursive: true });
process.env.CLAUDE_HOME = claudeHome;
process.env.CLAUDE_WEB_SCAN_ROOTS = scanRoot;

const { resolveCwd } = await import("../cwd.mjs");

const mkdir = (rel) => {
  const dir = path.join(scanRoot, rel);
  mkdirSync(dir, { recursive: true });
  return dir;
};

test("varredura: o candidato mais raso vence a copia em docs/repos", async () => {
  mkdir("docs/repos/shallow");
  const top = mkdir("shallow");

  const { cwd, candidates } = await resolveCwd("shallow", null);

  assert.equal(cwd, top);
  assert.equal(candidates[0], top);
  assert.equal(candidates.length, 2);
});

test("varredura: empate no nivel mais raso nao escolhe cwd", async () => {
  mkdir("a/twin");
  mkdir("b/twin");
  mkdir("c/d/twin");

  const { cwd, candidates } = await resolveCwd("twin", null);

  assert.equal(cwd, null);
  assert.deepEqual(candidates.slice(0, 2).sort(), [path.join(scanRoot, "a/twin"), path.join(scanRoot, "b/twin")]);
  assert.equal(candidates[2], path.join(scanRoot, "c/d/twin"));
});

test("project_path e override continuam precedendo a varredura", async () => {
  mkdir("x/pinned");
  mkdir("y/pinned");
  const projectPath = mkdir("elsewhere/pinned");

  assert.equal((await resolveCwd("pinned", { project_path: projectPath })).cwd, projectPath);

  const override = mkdir("override/pinned");
  writeFileSync(
    path.join(claudeHome, "workflow", ".dashboard.json"),
    JSON.stringify({ cwds: { pinned: override } }),
  );
  const resolved = await resolveCwd("pinned", { project_path: projectPath });
  assert.equal(resolved.cwd, override);
  assert.deepEqual(resolved.candidates.slice(0, 2), [projectPath, override]);
});
