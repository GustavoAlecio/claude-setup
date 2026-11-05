import { test, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { query as fakeQuery } from "./fixtures/fake-sdk.mjs";

// data.mjs e cwd.mjs resolvem as raizes no import: o ambiente tem que existir antes.
const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-gh-"));
const claudeHome = tmpDir();
const scanRoot = tmpDir();
mkdirSync(path.join(claudeHome, "workflow"), { recursive: true });
process.env.CLAUDE_HOME = claudeHome;
process.env.CLAUDE_WEB_SCAN_ROOTS = scanRoot;

const { createEngine } = await import("../engine.mjs");
const { createGitHub, stageFrom, checksFrom, GH_MISSING, GH_NO_LOGIN, NOT_PR_URL, PR_NOT_FOUND, INVALID_ENTRY } =
  await import("../github.mjs");

const servers = new Set();
const engines = new Set();

after(async () => {
  for (const engine of engines) await engine.sessions.shutdown({ waitMs: 200 });
  for (const server of servers) {
    server.closeAllConnections();
    server.close();
  }
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function graphqlPr(overrides = {}) {
  return {
    state: "OPEN",
    isDraft: false,
    reviewDecision: null,
    mergedAt: null,
    updatedAt: "2026-09-30T10:00:00Z",
    mergeable: "MERGEABLE",
    commits: { nodes: [{ commit: { statusCheckRollup: { state: "SUCCESS" } } }] },
    reviewThreads: { nodes: [] },
    ...overrides,
  };
}

const prResponse = (pr) => ({ stdout: JSON.stringify({ data: { repository: { pullRequest: pr } } }) });

/** `gh` falso: registra os args e delega ao handler; nunca chama o binario real. */
function fakeGh(handler) {
  const calls = [];
  const gh = async (args) => {
    calls.push(args);
    return handler(args);
  };
  return { gh, calls, graphqlCalls: () => calls.filter((a) => a[0] === "api" && a[1] === "graphql") };
}

function fakeGit(remotes = {}) {
  return async (args) => {
    const remote = remotes[args[1]];
    if (remote === undefined) throw Object.assign(new Error("exit 1"), { code: 1 });
    return { stdout: `${remote}\n` };
  };
}

function writePrs(project, content) {
  const dir = path.join(claudeHome, "workflow", project);
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, "prs.json"), typeof content === "string" ? content : JSON.stringify(content));
}

const entry = (n, repo = "solo", extra = {}) => ({
  pr_number: n,
  ado_id: 100 + n,
  branch: `feat/${n}`,
  target: "main",
  title: `PR ${n}`,
  url: `https://github.com/me/${repo}/pull/${n}`,
  stage: "awaiting_review",
  opened_at: "2026-09-01T00:00:00Z",
  last_check: null,
  ...extra,
});

const mkdir = (rel) => {
  const dir = path.join(scanRoot, rel);
  mkdirSync(dir, { recursive: true });
  return dir;
};

async function start({ gh, git = fakeGit(), now = Date.now } = {}) {
  const engine = createEngine({ query: fakeQuery, sessionsDir: tmpDir(), gh, git, now });
  engines.add(engine);
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return server.address().port;
}

async function get(port, url) {
  const res = await fetch(`http://127.0.0.1:${port}${url}`);
  return { status: res.status, body: await res.json().catch(() => null) };
}

test("stage: tabela de estados, incluindo thread aberta sem CHANGES_REQUESTED", () => {
  const open = [{ path: "a", line: 1, author: "x", body: "y" }];
  const cases = [
    [{ state: "MERGED", isDraft: false, reviewDecision: "APPROVED" }, [], "merged"],
    [{ state: "CLOSED", isDraft: false, reviewDecision: null }, open, "closed"],
    [{ state: "OPEN", isDraft: true, reviewDecision: "CHANGES_REQUESTED" }, open, "draft"],
    [{ state: "OPEN", isDraft: false, reviewDecision: "CHANGES_REQUESTED" }, [], "changes_requested"],
    [{ state: "OPEN", isDraft: false, reviewDecision: "APPROVED" }, open, "changes_requested"],
    [{ state: "OPEN", isDraft: false, reviewDecision: "APPROVED" }, [], "approved"],
    [{ state: "OPEN", isDraft: false, reviewDecision: "REVIEW_REQUIRED" }, [], "awaiting_review"],
    [{ state: "OPEN", isDraft: false, reviewDecision: null }, [], "awaiting_review"],
  ];
  for (const [pr, unresolved, expected] of cases) assert.equal(stageFrom(pr, unresolved), expected, JSON.stringify(pr));
});

test("checks: FAILURE, ERROR, PENDING, EXPECTED, SUCCESS e rollup nulo", () => {
  assert.equal(checksFrom("FAILURE"), "failing");
  assert.equal(checksFrom("ERROR"), "failing");
  assert.equal(checksFrom("PENDING"), "pending");
  assert.equal(checksFrom("EXPECTED"), "pending");
  assert.equal(checksFrom("SUCCESS"), "passing");
  assert.equal(checksFrom(null), null);
  assert.equal(checksFrom(undefined), null);
});

test("query: owner e repo com -f, so pr com -F; mapeia threads abertas, checks e datas", async () => {
  writePrs("mapping", { project: "mapping", prs: [entry(5)] });
  const fake = fakeGh(() =>
    prResponse(
      graphqlPr({
        reviewDecision: "APPROVED",
        mergedAt: null,
        commits: { nodes: [{ commit: { statusCheckRollup: { state: "FAILURE" } } }] },
        reviewThreads: {
          nodes: [
            { isResolved: true, comments: { nodes: [{ author: { login: "old" }, body: "ok", path: "x", line: 1 }] } },
            { isResolved: false, comments: { nodes: [{ author: { login: "rev" }, body: "conserta", path: "lib/a.dart", line: 42 }] } },
          ],
        },
      })
    )
  );
  const github = createGitHub({ gh: fake.gh, git: fakeGit() });

  const [pr] = await github.prs("mapping");

  const args = fake.graphqlCalls()[0];
  const flag = (value) => args[args.indexOf(value) - 1];
  assert.equal(flag("owner=me"), "-f");
  assert.equal(flag("repo=solo"), "-f");
  assert.equal(flag("pr=5"), "-F");
  assert.ok(args.some((a) => a.startsWith("query=") && a.includes("reviewThreads(first:100)")));

  assert.equal(pr.live, true);
  assert.equal("liveError" in pr, false);
  assert.equal(pr.stage, "changes_requested");
  assert.equal(pr.checks, "failing");
  assert.deepEqual(pr.unresolved, [{ path: "lib/a.dart", line: 42, author: "rev", body: "conserta" }]);
  assert.equal(pr.updatedAt, "2026-09-30T10:00:00Z");
  assert.equal(pr.mergedAt, null);
  assert.equal(pr.ado_id, 105);
  assert.equal(pr.repo, "solo");
  assert.equal(pr.nameWithOwner, "me/solo");
});

test("cache: t=0 e t=59s -> 1 chamada; t=60s -> 2", async () => {
  writePrs("ttl", { prs: [entry(1)] });
  let clock = 0;
  const fake = fakeGh(() => prResponse(graphqlPr()));
  const github = createGitHub({ gh: fake.gh, git: fakeGit(), now: () => clock });

  await github.prs("ttl");
  clock = 59_000;
  await github.prs("ttl");
  assert.equal(fake.graphqlCalls().length, 1);

  clock = 60_000;
  await github.prs("ttl");
  assert.equal(fake.graphqlCalls().length, 2);
});

test("cache: dois GETs concorrentes -> 1 chamada", async () => {
  writePrs("concurrent", { prs: [entry(2)] });
  const fake = fakeGh(async () => {
    await sleep(30);
    return prResponse(graphqlPr());
  });
  const port = await start({ gh: fake.gh });

  const [a, b] = await Promise.all([get(port, "/api/projects/concurrent/prs"), get(port, "/api/projects/concurrent/prs")]);

  assert.equal(a.status, 200);
  assert.equal(b.status, 200);
  assert.equal(a.body.prs[0].live, true);
  assert.equal(fake.graphqlCalls().length, 1);
});

test("cache: falha em t=0 e GET em t=30s -> 1 chamada", async () => {
  writePrs("failcache", { prs: [entry(3)] });
  let clock = 0;
  const fake = fakeGh(async () => {
    throw Object.assign(new Error("boom"), { code: 1, stderr: "erro qualquer" });
  });
  const github = createGitHub({ gh: fake.gh, git: fakeGit(), now: () => clock });

  const [first] = await github.prs("failcache");
  clock = 30_000;
  const [second] = await github.prs("failcache");

  assert.equal(fake.graphqlCalls().length, 1);
  assert.equal(first.liveError, "erro qualquer");
  assert.equal(second.liveError, "erro qualquer");
});

test("falhas: ENOENT, saida 4, repo inexistente e URL invalida -> fallback com mensagem fixa", async () => {
  const cases = [
    ["enoent", entry(1), () => Promise.reject(Object.assign(new Error("spawn gh ENOENT"), { code: "ENOENT" })), GH_MISSING],
    ["nologin", entry(1), () => Promise.reject(Object.assign(new Error("Command failed"), { code: 4, stderr: "" })), GH_NO_LOGIN],
    [
      "norepo",
      entry(1),
      () =>
        Promise.reject(
          Object.assign(new Error("Command failed"), {
            code: 1,
            stderr: "GraphQL: Could not resolve to a Repository with the name 'me/solo'. (repository)",
          })
        ),
      PR_NOT_FOUND,
    ],
    ["nullpr", entry(1), () => Promise.resolve(prResponse(null)), PR_NOT_FOUND],
    ["badurl", entry(1, "solo", { url: "https://gitlab.com/me/solo/merge_requests/1" }), null, NOT_PR_URL],
    ["nourl", entry(1, "solo", { url: undefined }), null, INVALID_ENTRY],
    ["badnum", entry(1, "solo", { pr_number: "1" }), null, INVALID_ENTRY],
    ["long", entry(1), () => Promise.reject(Object.assign(new Error("x"), { code: 1, stderr: "e".repeat(500) })), "e".repeat(200)],
  ];
  for (const [project, item, handler, message] of cases) {
    writePrs(project, { prs: [{ ...item, stage: "approved" }] });
    const fake = fakeGh(handler ?? (() => assert.fail("gh nao deveria ser chamado")));
    const github = createGitHub({ gh: fake.gh, git: fakeGit() });

    const [pr] = await github.prs(project);

    assert.equal(pr.live, false, project);
    assert.equal(pr.liveError, message, project);
    assert.equal(pr.stage, "approved", project);
    assert.equal(pr.checks, null, project);
    assert.deepEqual(pr.unresolved, [], project);
    assert.equal(pr.updatedAt, null, project);
    assert.equal(pr.mergedAt, null, project);
    if (!handler) assert.equal(fake.calls.length, 0, project);
  }
});

test("cwd: remote que bate, outro owner, empate e PRs de repos diferentes no mesmo projeto", async () => {
  const match = mkdir("work/match-repo");
  const other = mkdir("work/foreign-repo");
  mkdir("x1/twin-repo");
  mkdir("x2/twin-repo");
  const a = mkdir("multi/a-repo");
  const b = mkdir("multi/b-repo");
  writePrs("cwdproj", {
    prs: [entry(1, "match-repo"), entry(2, "foreign-repo"), entry(3, "twin-repo"), entry(4, "a-repo"), entry(5, "b-repo")],
  });
  const git = fakeGit({
    [match]: "git@github.com:Me/Match-Repo.git",
    [other]: "https://github.com/someone-else/foreign-repo.git",
    [a]: "https://github.com/me/a-repo",
    [b]: "ssh://git@github.com/me/b-repo.git",
  });
  const github = createGitHub({ gh: fakeGh(() => prResponse(graphqlPr())).gh, git });

  const byRepo = Object.fromEntries((await github.prs("cwdproj")).map((pr) => [pr.repo, pr]));

  assert.equal(byRepo["match-repo"].cwd, match);
  assert.equal(byRepo["match-repo"].cwdReason, null);

  assert.equal(byRepo["foreign-repo"].cwd, null);
  assert.deepEqual(byRepo["foreign-repo"].cwdCandidates, [other]);
  assert.match(byRepo["foreign-repo"].cwdReason, /someone-else\/foreign-repo/);

  assert.equal(byRepo["twin-repo"].cwd, null);
  assert.deepEqual(byRepo["twin-repo"].cwdCandidates.sort(), [
    path.join(scanRoot, "x1/twin-repo"),
    path.join(scanRoot, "x2/twin-repo"),
  ]);
  assert.match(byRepo["twin-repo"].cwdReason, /ambíguo/);

  assert.equal(byRepo["a-repo"].cwd, a);
  assert.equal(byRepo["b-repo"].cwd, b);
});

test("cwd: uma varredura por nome distinto por request, mesmo com varios PRs do mesmo repo", async () => {
  writePrs("scanonce", { prs: [entry(1, "same"), entry(2, "same"), entry(3, "same")] });
  const scans = [];
  const github = createGitHub({
    gh: fakeGh(() => prResponse(graphqlPr())).gh,
    git: fakeGit(),
    resolveCwd: async (name) => {
      scans.push(name);
      return { cwd: null, candidates: [], override: null };
    },
  });

  const prs = await github.prs("scanonce");

  assert.equal(prs.length, 3);
  assert.deepEqual(scans, ["same"]);
  assert.equal(prs[0].cwdReason, "sem checkout local");
});

test("/api/projects/:name/prs: ausente, invalido, nome inseguro e duplicatas", async () => {
  const fake = fakeGh(() => prResponse(graphqlPr()));
  const port = await start({ gh: fake.gh });

  assert.deepEqual(await get(port, "/api/projects/nao-existe/prs"), { status: 200, body: { prs: [] } });

  mkdirSync(path.join(claudeHome, "workflow", "semarquivo"), { recursive: true });
  assert.deepEqual(await get(port, "/api/projects/semarquivo/prs"), { status: 200, body: { prs: [] } });

  writePrs("jsonruim", "{nao e json");
  assert.deepEqual(await get(port, "/api/projects/jsonruim/prs"), { status: 200, body: { prs: [] } });

  writePrs("semarray", { prs: { a: 1 } });
  assert.deepEqual(await get(port, "/api/projects/semarray/prs"), { status: 200, body: { prs: [] } });

  assert.equal((await get(port, "/api/projects/..%2Fx/prs")).status, 400);
  assert.equal((await get(port, "/api/projects/a%20b/prs")).status, 400);

  writePrs("dup", { prs: [entry(7, "solo", { title: "antigo" }), entry(8), entry(7, "solo", { title: "novo" })] });
  const dup = await get(port, "/api/projects/dup/prs");
  assert.equal(dup.status, 200);
  assert.deepEqual(
    dup.body.prs.map((pr) => [pr.pr_number, pr.title]),
    [
      [8, "PR 8"],
      [7, "novo"],
    ]
  );
  assert.equal(fake.calls.length, 2);
});

function inboxGh({ search, login = "octocat" }) {
  return fakeGh((args) => {
    if (args[0] === "search") return search();
    if (args[0] === "api" && args[1] === "user") return { stdout: `${login}\n` };
    throw new Error(`chamada inesperada: ${args.join(" ")}`);
  });
}

test("inbox: sucesso traz nameWithOwner, repo, cwd, cwdCandidates e login", async () => {
  const repoDir = mkdir("inbox/my_repo");
  const fake = inboxGh({
    search: () => ({
      stdout: JSON.stringify([
        {
          number: 7,
          title: "Ajusta X",
          repository: { name: "my_repo", nameWithOwner: "org/my_repo" },
          author: { login: "alice" },
          updatedAt: "2026-09-29T12:00:00Z",
          isDraft: true,
          url: "https://github.com/org/my_repo/pull/7",
        },
        { number: "x", url: "https://github.com/org/bad/pull/1", repository: { nameWithOwner: "org/bad" } },
        {
          number: 9,
          title: "Sem checkout",
          repository: { nameWithOwner: "org/nowhere" },
          author: { login: "bob" },
          updatedAt: "2026-09-28T12:00:00Z",
          isDraft: false,
          url: "https://github.com/org/nowhere/pull/9",
        },
      ]),
    }),
  });
  const port = await start({ gh: fake.gh, git: fakeGit({ [repoDir]: "git@github.com:org/my_repo.git" }) });

  const res = await get(port, "/api/review-inbox");

  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.login, "octocat");
  assert.deepEqual(res.body.items, [
    {
      number: 7,
      title: "Ajusta X",
      url: "https://github.com/org/my_repo/pull/7",
      repo: "my_repo",
      nameWithOwner: "org/my_repo",
      author: "alice",
      updatedAt: "2026-09-29T12:00:00Z",
      isDraft: true,
      cwd: repoDir,
      cwdCandidates: [repoDir],
      cwdReason: null,
    },
    {
      number: 9,
      title: "Sem checkout",
      url: "https://github.com/org/nowhere/pull/9",
      repo: "nowhere",
      nameWithOwner: "org/nowhere",
      author: "bob",
      updatedAt: "2026-09-28T12:00:00Z",
      isDraft: false,
      cwd: null,
      cwdCandidates: [],
      cwdReason: "sem checkout local",
    },
  ]);
  const search = fake.calls.find((a) => a[0] === "search");
  assert.deepEqual(search, [
    "search",
    "prs",
    "--review-requested=@me",
    "--state=open",
    "--limit",
    "50",
    "--json",
    "number,title,repository,author,updatedAt,isDraft,url",
  ]);

  await get(port, "/api/review-inbox");
  assert.equal(fake.calls.filter((a) => a[0] === "search").length, 1);
});

test("inbox: codigo 1, stdout que nao e JSON e sem login -> 502", async () => {
  const exit1 = inboxGh({
    search: () => Promise.reject(Object.assign(new Error("Command failed"), { code: 1, stderr: "HTTP 502: bad gateway" })),
  });
  const res1 = await get(await start({ gh: exit1.gh }), "/api/review-inbox");
  assert.equal(res1.status, 502);
  assert.equal(res1.body.error, "HTTP 502: bad gateway");

  const notJson = inboxGh({ search: () => ({ stdout: "<html>" }) });
  const res2 = await get(await start({ gh: notJson.gh }), "/api/review-inbox");
  assert.equal(res2.status, 502);
  assert.ok(res2.body.error);

  const noLogin = inboxGh({ search: () => Promise.reject(Object.assign(new Error("Command failed"), { code: 4 })) });
  const res3 = await get(await start({ gh: noLogin.gh }), "/api/review-inbox");
  assert.equal(res3.status, 502);
  assert.equal(res3.body.error, GH_NO_LOGIN);
});

test("health: versao 0.3.0", async () => {
  const port = await start({ gh: fakeGh(() => assert.fail("sem gh")).gh });
  assert.deepEqual(await get(port, "/api/health"), { status: 200, body: { ok: true, version: "0.3.0" } });
});
