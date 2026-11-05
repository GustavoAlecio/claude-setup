import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

// cwd.mjs resolve as raizes no import: o ambiente tem que existir antes.
const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-cwd-"));
const claudeHome = tmpDir();
const scanRoot = tmpDir();
// Raiz da busca que e ela mesma um repo: conta como ancestral.
const gitScanRoot = tmpDir();
mkdirSync(path.join(gitScanRoot, ".git"));
mkdirSync(path.join(claudeHome, "workflow"), { recursive: true });
process.env.CLAUDE_HOME = claudeHome;
process.env.CLAUDE_WEB_SCAN_ROOTS = `${scanRoot}:${gitScanRoot}`;

const { resolveCwd } = await import("../cwd.mjs");

const mkdir = (rel, root = scanRoot) => {
  const dir = path.join(root, rel);
  mkdirSync(dir, { recursive: true });
  return dir;
};
const gitDir = (rel) => mkdir(path.join(rel, ".git"));
const gitFile = (rel) => writeFileSync(path.join(mkdir(rel), ".git"), "gitdir: /tmp/elsewhere\n");

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

test("raiz do repo: copia dentro de outro repo perde para o repo de mesmo nome", async () => {
  gitDir("repoA");
  mkdir("repoA/sub/alvo");
  gitDir("alvo");

  const { cwd, candidates } = await resolveCwd("alvo", null);

  assert.equal(cwd, path.join(scanRoot, "alvo"));
  assert.deepEqual(candidates, [path.join(scanRoot, "alvo")]);
});

test("raiz do repo: pasta dentro de um repo, sem ser a raiz dele, nao e candidata", async () => {
  gitDir("repoB");
  mkdir("repoB/sub/aninhado");

  const { cwd, candidates } = await resolveCwd("aninhado", null);

  assert.equal(cwd, null);
  assert.deepEqual(candidates, []);
});

test("raiz do repo: pasta sem .git em lugar nenhum continua aceita", async () => {
  const plain = mkdir("plain/solto");

  assert.equal((await resolveCwd("solto", null)).cwd, plain);
});

test("raiz do repo: a raiz da busca com .git conta como ancestral", async () => {
  mkdir("dentro", gitScanRoot);

  const { cwd, candidates } = await resolveCwd("dentro", null);

  assert.equal(cwd, null);
  assert.deepEqual(candidates, []);
});

test("raiz do repo: .git como arquivo (worktree/submodulo) dentro de outro repo e raiz", async () => {
  gitDir("repoC");
  gitFile("repoC/sub2");

  assert.equal((await resolveCwd("sub2", null)).cwd, path.join(scanRoot, "repoC/sub2"));
});

test("raiz do repo: candidato recusado nao interrompe a descida", async () => {
  gitDir("repoD");
  mkdir("repoD/fundo");
  gitDir("repoD/fundo/fundo");

  const { cwd, candidates } = await resolveCwd("fundo", null);

  assert.equal(cwd, path.join(scanRoot, "repoD/fundo/fundo"));
  assert.deepEqual(candidates, [path.join(scanRoot, "repoD/fundo/fundo")]);
});
