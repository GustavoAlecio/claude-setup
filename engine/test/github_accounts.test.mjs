import { test, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { query as fakeQuery } from "./fixtures/fake-sdk.mjs";

// data.mjs e cwd.mjs resolvem as raizes no import: o ambiente tem que existir antes.
const tmpDir = () => mkdtempSync(path.join(os.tmpdir(), "engine-gh-acct-"));
const claudeHome = tmpDir();
const scanRoot = tmpDir();
mkdirSync(path.join(claudeHome, "workflow"), { recursive: true });
process.env.CLAUDE_HOME = claudeHome;
process.env.CLAUDE_WEB_SCAN_ROOTS = scanRoot;

const { createEngine } = await import("../engine.mjs");
const { createGitHub, REMOTE_HTTPS, SSH_KEY_REFUSED, SSH_UNKNOWN_HOST } = await import("../github.mjs");
const { createTokens, redact } = await import("../gh_env.mjs");

const servers = new Set();
const engines = new Set();

after(async () => {
  for (const engine of engines) await engine.sessions.shutdown({ waitMs: 200 });
  for (const server of servers) {
    server.closeAllConnections();
    server.close();
  }
});

const TOKENS = {
  "acct-a": "gho_FAKEaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "acct-b": "gho_FAKEbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
};
const NOT_LOGGED = (login) => `conta ${login} não está logada no gh (gh auth login)`;

const isTokenCall = (args) => args[0] === "auth" && args[1] === "token";
const userOf = (args) => args[args.indexOf("--user") + 1];
const fail = (fields) => Object.assign(new Error("Command failed"), { code: 1, ...fields });

/** `gh` falso: registra `{args, env}`, responde `auth token` por `TOKENS` e delega o resto. */
function fakeGh(handler = () => assert.fail("gh nao deveria ser chamado")) {
  const calls = [];
  const gh = async (args, { env } = {}) => {
    calls.push({ args, env });
    if (isTokenCall(args)) {
      const token = TOKENS[userOf(args)];
      if (!token) throw fail({ stderr: `no oauth token found for github.com account ${userOf(args)}` });
      return { stdout: `${token}\n` };
    }
    return handler(args, env);
  };
  return {
    gh,
    calls,
    of: (predicate) => calls.filter((c) => predicate(c.args)),
    tokenCalls: () => calls.filter((c) => isTokenCall(c.args)),
  };
}

/** `git` falso: tira `-C <cwd>` e `-c credential.helper=` e responde por subcomando. */
function fakeGit({ urls = {}, remotes = {}, pushUrls = {} } = {}) {
  const calls = [];
  const git = async (args) => {
    calls.push(args);
    let rest = args;
    let cwd = null;
    if (rest[0] === "-C") [cwd, rest] = [rest[1], rest.slice(2)];
    assert.deepEqual(rest.slice(0, 2), ["-c", "credential.helper="], `git sem helper vazio: ${args.join(" ")}`);
    rest = rest.slice(2);
    let out;
    if (rest[0] === "ls-remote") out = urls[rest[2]] ?? rest[2];
    else if (rest[0] === "config") out = remotes[cwd];
    else if (rest[0] === "remote") out = pushUrls[cwd];
    if (out === undefined) throw fail({});
    return { stdout: `${out}\n` };
  };
  return { git, calls };
}

function fakeSsh(byDest) {
  const calls = [];
  const ssh = async (args) => {
    calls.push(args);
    const reply = byDest[args.at(-1)];
    if (!reply) throw fail({ code: 255, stderr: "ssh: connect to host x port 22: Operation timed out" });
    throw fail(reply);
  };
  return { ssh, calls };
}

async function start({ gh, git = fakeGit().git, ssh = fakeSsh({}).ssh, now = Date.now, log = () => {} }) {
  const engine = createEngine({ query: fakeQuery, sessionsDir: tmpDir(), gh, git, ssh, now, log });
  engines.add(engine);
  const server = http.createServer(engine.app);
  servers.add(server);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return server.address().port;
}

async function get(port, url) {
  const res = await fetch(`http://127.0.0.1:${port}${url}`);
  return { status: res.status, body: await res.json().catch(() => null), raw: res };
}

function writePrs(project, prs) {
  const dir = path.join(claudeHome, "workflow", project);
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, "prs.json"), JSON.stringify({ prs }));
}

const entry = (n, repo = "solo") => ({
  pr_number: n,
  title: `PR ${n}`,
  url: `https://github.com/org-x/${repo}/pull/${n}`,
  stage: "awaiting_review",
});

const livePr = (body = "ok") => ({
  stdout: JSON.stringify({
    data: {
      repository: {
        pullRequest: {
          state: "OPEN",
          isDraft: false,
          reviewDecision: null,
          mergedAt: null,
          updatedAt: "2026-09-30T10:00:00Z",
          commits: { nodes: [] },
          reviewThreads: { nodes: [{ isResolved: false, comments: { nodes: [{ author: { login: "r" }, body, path: "a", line: 1 }] } }] },
        },
      },
    },
  }),
});

async function withEnv(vars, body) {
  const saved = Object.fromEntries(Object.keys(vars).map((k) => [k, process.env[k]]));
  Object.assign(process.env, vars);
  try {
    return await body();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

test("contas: so keyring de github.com, valid por state, e o gh nunca recebe token herdado", async () => {
  const status = {
    hosts: {
      "github.com": [
        { state: "success", active: true, host: "github.com", login: "acct-a", tokenSource: "keyring" },
        { state: "error", active: false, host: "github.com", login: "acct-b", tokenSource: "keyring" },
        { state: "success", active: false, host: "github.com", login: "acct-env", tokenSource: "GH_TOKEN" },
      ],
    },
  };
  // `gh auth status` sai com 1 quando ha conta com erro; o JSON vem no stdout mesmo assim.
  const fake = fakeGh((args) => {
    if (args[0] === "auth" && args[1] === "status") throw fail({ stdout: JSON.stringify(status) });
    assert.fail(`inesperado: ${args.join(" ")}`);
  });

  await withEnv({ GH_TOKEN: "gho_FAKEinheritedinheritedinherited", GITHUB_TOKEN: "ghp_FAKEinheritedinheritedinherited" }, async () => {
    const port = await start({ gh: fake.gh });
    const res = await get(port, "/api/github/accounts");
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.deepEqual(res.body, {
      accounts: [
        { login: "acct-a", active: true, valid: true },
        { login: "acct-b", active: false, valid: false },
      ],
    });
    await get(port, "/api/github/accounts");
  });

  assert.equal(fake.calls.length, 1);
  const [{ args, env }] = fake.calls;
  assert.deepEqual(args.slice(0, 4), ["auth", "status", "--json", "hosts"]);
  for (const key of ["GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"]) {
    assert.equal(key in env, false, key);
  }
  assert.equal(env.GH_PROMPT_DISABLED, "1");
  assert.equal(env.PATH, process.env.PATH);
});

test("orgs: token da conta no GH_TOKEN, login primeiro e dedup ignorando caixa; sem conta usa a ativa", async () => {
  const fake = fakeGh((args) => {
    if (args[0] === "api" && args[1] === "user/orgs") return { stdout: "org-x\nOrg-Y\nACCT-A\nnome invalido\n\n" };
    if (args[0] === "api" && args[1] === "user") return { stdout: "acct-b\n" };
    assert.fail(`inesperado: ${args.join(" ")}`);
  });
  const port = await start({ gh: fake.gh });

  const withAccount = await get(port, "/api/github/orgs?account=acct-a");
  assert.equal(withAccount.status, 200, JSON.stringify(withAccount.body));
  assert.deepEqual(withAccount.body, { login: "acct-a", orgs: ["acct-a", "org-x", "Org-Y"] });
  const orgsCall = fake.of((a) => a[1] === "user/orgs")[0];
  assert.equal(orgsCall.env.GH_TOKEN, TOKENS["acct-a"]);
  assert.deepEqual(orgsCall.args.slice(-2), ["--jq", ".[].login"]);
  assert.equal(fake.of((a) => a[1] === "user").length, 0);

  const active = await get(port, "/api/github/orgs");
  assert.deepEqual(active.body, { login: "acct-b", orgs: ["acct-b", "org-x", "Org-Y", "ACCT-A"] });
  const activeCalls = fake.of((a) => a[1] === "user/orgs");
  assert.equal(activeCalls.length, 2);
  assert.equal("GH_TOKEN" in activeCalls[1].env, false);
});

test("conta desconhecida: orgs e inbox 400 fixo, prs 200 com live false; parametro invalido nem chama o gh", async () => {
  writePrs("unknown-acct", [entry(1), entry(2)]);
  const fake = fakeGh(() => assert.fail("so auth token deveria rodar"));
  const port = await start({ gh: fake.gh });

  const orgs = await get(port, "/api/github/orgs?account=acct-z");
  assert.deepEqual([orgs.status, orgs.body], [400, { error: NOT_LOGGED("acct-z") }]);
  const inbox = await get(port, "/api/review-inbox?account=acct-z&owner=org-x");
  assert.deepEqual([inbox.status, inbox.body], [400, { error: NOT_LOGGED("acct-z") }]);

  const prs = await get(port, "/api/projects/unknown-acct/prs?account=acct-z");
  assert.equal(prs.status, 200);
  assert.equal(prs.body.prs.length, 2);
  for (const pr of prs.body.prs) {
    assert.equal(pr.live, false);
    assert.equal(pr.liveError, NOT_LOGGED("acct-z"));
  }
  assert.ok(fake.calls.every((c) => isTokenCall(c.args)));
  assert.ok(!JSON.stringify([orgs.body, inbox.body, prs.body]).includes("no oauth token"));

  const before = fake.calls.length;
  for (const url of [
    "/api/github/orgs?account=--hostname",
    "/api/review-inbox?account=--hostname",
    "/api/review-inbox?owner=a%20b",
    "/api/review-inbox?owner=--x",
    "/api/projects/unknown-acct/prs?account=--hostname",
    "/api/projects/unknown-acct/prs?account=",
    "/api/github/ssh-identity?owner=-oProxyCommand=x",
  ]) {
    const res = await get(port, url);
    assert.deepEqual([res.status, res.body], [400, { error: "parâmetro inválido" }], url);
  }
  assert.equal(fake.calls.length, before);
});

test("cache de token: t=0 e t=299s -> 1 chamada; t=301s -> 2; 401 invalida", async () => {
  writePrs("token-ttl", [entry(1)]);
  let clock = 0;
  let unauthorized = false;
  const fake = fakeGh((args) => {
    if (unauthorized) throw fail({ stderr: "HTTP 401: Bad credentials (https://api.github.com/graphql)" });
    return livePr();
  });
  const github = createGitHub({ gh: fake.gh, git: fakeGit().git, now: () => clock });

  const [first] = await github.prs("token-ttl", { account: "acct-a" });
  assert.equal(first.live, true);
  assert.equal(fake.of((a) => a[1] === "graphql")[0].env.GH_TOKEN, TOKENS["acct-a"]);
  clock = 299_000;
  await github.prs("token-ttl", { account: "acct-a" });
  assert.equal(fake.tokenCalls().length, 1);
  assert.equal(fake.of((a) => a[1] === "graphql").length, 2);

  clock = 301_000;
  await github.prs("token-ttl", { account: "acct-a" });
  assert.equal(fake.tokenCalls().length, 2);

  clock = 400_000;
  unauthorized = true;
  const [denied] = await github.prs("token-ttl", { account: "acct-a" });
  assert.equal(denied.live, false);
  assert.equal(fake.tokenCalls().length, 2);

  clock = 470_000;
  unauthorized = false;
  await github.prs("token-ttl", { account: "acct-a" });
  assert.equal(fake.tokenCalls().length, 3);
});

test("cache de token: falha nao fica em cache e vira a mensagem fixa", async () => {
  let fails = true;
  const calls = [];
  const tokens = createTokens({
    gh: async (args) => {
      calls.push(args);
      if (fails) throw fail({ stderr: "gho_FAKEsecretsecretsecretsecret detalhe cru" });
      return { stdout: "gho_FAKEokokokokokokokokokokokok\n" };
    },
  });
  await assert.rejects(tokens.tokenFor("acct-a"), { status: 400, message: NOT_LOGGED("acct-a") });
  fails = false;
  assert.equal(await tokens.tokenFor("acct-a"), "gho_FAKEokokokokokokokokokokokok");
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[0], ["auth", "token", "--hostname", "github.com", "--user", "acct-a"]);
});

test("redacao: token ecoado no stdout e stderr do gh nao chega a resposta, cache nem log", async () => {
  writePrs("leaky", [entry(1, "leak-ok"), entry(2, "leak-fail")]);
  const token = TOKENS["acct-a"];
  const logged = [];
  const fake = fakeGh((args) => {
    if (args[0] === "search") {
      return {
        stdout: JSON.stringify([
          { number: 3, title: `vaza ${token}`, url: "https://github.com/org-x/r/pull/3", repository: { nameWithOwner: "org-x/r" } },
        ]),
      };
    }
    if (args.includes("repo=leak-ok")) return livePr(`token ${token}`);
    throw fail({ stderr: `falhou com ${token}`, stdout: token });
  });
  const ssh = () => {
    throw new Error(`bug inesperado com ${token}`);
  };
  const port = await start({ gh: fake.gh, ssh, log: (...args) => logged.push(args.join(" ")) });

  const responses = [];
  for (let i = 0; i < 2; i++) {
    responses.push(await get(port, "/api/review-inbox?account=acct-a"));
    responses.push(await get(port, "/api/projects/leaky/prs?account=acct-a"));
  }
  const crash = await get(port, "/api/github/ssh-identity?owner=org-x");
  assert.equal(crash.status, 500);
  responses.push(crash);

  assert.equal(fake.of((a) => a[0] === "search").length, 1, "a segunda leitura vem do cache");
  const text = JSON.stringify(responses.map((r) => r.body));
  assert.ok(!text.includes(token), text);
  assert.ok(!text.includes("FAKEaaaa"), text);
  assert.equal(responses[0].body.items[0].title, "vaza ***");
  const prs = Object.fromEntries(responses[1].body.prs.map((pr) => [pr.repo, pr]));
  assert.equal(prs["leak-ok"].unresolved[0].body, "token ***");
  assert.equal(prs["leak-fail"].liveError, "falhou com ***");
  assert.deepEqual(responses[3].body, responses[1].body);

  assert.ok(logged.length > 0, "o 500 tem que passar pelo log");
  assert.ok(!logged.join("\n").includes(token), logged.join("\n"));
  assert.equal(redact(`a ${token} b ghs_${"x".repeat(20)} c`, []), "a *** b *** c");
});

test("owners: ordem e caixa nao mudam a chave; --owner por owner; outra conta e nova chamada", async () => {
  const fake = fakeGh((args) => {
    if (args[0] === "search") return { stdout: "[]" };
    if (args[1] === "user") return { stdout: "ativa\n" };
    assert.fail(`inesperado: ${args.join(" ")}`);
  });
  const port = await start({ gh: fake.gh });
  const searches = () => fake.of((a) => a[0] === "search");

  const first = await get(port, "/api/review-inbox?account=acct-a&owner=B&owner=a");
  assert.deepEqual(first.body, { items: [], login: "acct-a" });
  await get(port, "/api/review-inbox?account=acct-a&owner=a&owner=b");
  await get(port, "/api/review-inbox?account=acct-a&owner=b&owner=A&owner=a");
  assert.equal(searches().length, 1);
  const { args, env } = searches()[0];
  const i = args.indexOf("--owner");
  assert.deepEqual(args.slice(i, i + 4), ["--owner", "a", "--owner", "b"]);
  assert.equal(env.GH_TOKEN, TOKENS["acct-a"]);

  await get(port, "/api/review-inbox?account=acct-a");
  assert.equal(searches().length, 2);
  assert.ok(!searches()[1].args.includes("--owner"));

  await get(port, "/api/review-inbox?account=acct-b&owner=a&owner=b");
  assert.equal(searches().length, 3);
  assert.equal(searches()[2].env.GH_TOKEN, TOKENS["acct-b"]);

  const active = await get(port, "/api/review-inbox?owner=a");
  assert.equal(active.body.login, "ativa");
  assert.equal("GH_TOKEN" in searches()[3].env, false);
});

test("prs: conta na chave do cache e na mensagem de PR nao encontrado", async () => {
  writePrs("pr-accounts", [entry(1)]);
  const fake = fakeGh((args, env) => {
    if (env.GH_TOKEN === TOKENS["acct-b"]) {
      throw fail({ stderr: "GraphQL: Could not resolve to a Repository with the name 'org-x/solo'." });
    }
    return livePr();
  });
  const port = await start({ gh: fake.gh });

  const a = await get(port, "/api/projects/pr-accounts/prs?account=acct-a");
  const b = await get(port, "/api/projects/pr-accounts/prs?account=acct-b");
  const active = await get(port, "/api/projects/pr-accounts/prs");
  assert.equal(a.body.prs[0].live, true);
  assert.equal(b.body.prs[0].live, false);
  assert.equal(b.body.prs[0].liveError, "PR não encontrado ou sem acesso para a conta @acct-b");
  assert.equal(active.body.prs[0].live, true);
  assert.equal(fake.of((x) => x[1] === "graphql").length, 3);
});

test("ssh-identity: URL efetiva do git, Hi no stderr com codigo 1, -p da URL, https sem ssh e um ssh por host", async () => {
  const git = fakeGit({
    urls: {
      "git@github.com:acct-b-org/x.git": "git@alias:acct-b-org/x.git",
      "git@github.com:other-org/x.git": "git@alias:other-org/x.git",
      "git@github.com:ported/x.git": "ssh://git@h:443/ported/x.git",
      "git@github.com:web-org/x.git": "https://github.com/web-org/x.git",
    },
  });
  const ssh = fakeSsh({
    "git@alias": { code: 1, stderr: "Hi acct-b! You've successfully authenticated, but GitHub does not provide shell access.\n" },
    "git@h": { code: 1, stderr: "Hi acct-a! You've successfully authenticated.\n" },
    "git@github.com": { code: 1, stderr: "Hi acct-a! You've successfully authenticated.\n" },
  });
  const port = await start({ gh: fakeGh().gh, git: git.git, ssh: ssh.ssh });

  const alias = await get(port, "/api/github/ssh-identity?owner=acct-b-org");
  assert.deepEqual(alias.body, { owner: "acct-b-org", host: "alias", login: "acct-b" });
  const [args] = ssh.calls;
  for (const option of ["BatchMode=yes", "ConnectTimeout=8", "StrictHostKeyChecking=yes"]) {
    assert.equal(args[args.indexOf(option) - 1], "-o", option);
  }
  assert.ok(args.includes("-T"));
  assert.ok(!args.join(" ").includes("accept-new"));
  assert.equal(args.at(-1), "git@alias");
  assert.ok(!args.includes("-p"));

  const sameHost = await get(port, "/api/github/ssh-identity?owner=other-org");
  assert.deepEqual(sameHost.body, { owner: "other-org", host: "alias", login: "acct-b" });
  assert.equal(ssh.calls.length, 1);

  const ported = await get(port, "/api/github/ssh-identity?owner=ported");
  assert.deepEqual(ported.body, { owner: "ported", host: "h", login: "acct-a" });
  const portArgs = ssh.calls.at(-1);
  assert.equal(portArgs[portArgs.indexOf("-p") + 1], "443");
  assert.equal(portArgs.at(-1), "git@h");

  const plain = await get(port, "/api/github/ssh-identity?owner=no-rule");
  assert.deepEqual(plain.body, { owner: "no-rule", host: "github.com", login: "acct-a" });

  const calls = ssh.calls.length;
  const https = await get(port, "/api/github/ssh-identity?owner=web-org");
  assert.deepEqual(https.body, { owner: "web-org", host: null, login: null, error: REMOTE_HTTPS });
  assert.equal(ssh.calls.length, calls);

  await get(port, "/api/github/ssh-identity?owner=acct-b-org&fresh=1");
  assert.equal(ssh.calls.length, calls + 1);

  assert.ok(git.calls.some((a) => a.join(" ") === "-c credential.helper= ls-remote --get-url git@github.com:acct-b-org/x.git"));
  assert.equal((await get(port, "/api/github/ssh-identity")).status, 400);
});

test("ssh-identity: chave recusada, known_hosts e indisponivel; erro fica 30 s, sucesso 5 min", async () => {
  let clock = 0;
  const git = fakeGit({
    urls: {
      "git@github.com:refused/x.git": "git@refused-host:refused/x.git",
      "git@github.com:unknown/x.git": "git@unknown-host:unknown/x.git",
      "git@github.com:offline/x.git": "git@offline-host:offline/x.git",
    },
  });
  const ssh = fakeSsh({
    "git@refused-host": { code: 255, stderr: "git@refused-host: Permission denied (publickey).\n" },
    "git@unknown-host": { code: 255, stderr: "Host key verification failed.\n" },
  });
  const port = await start({ gh: fakeGh().gh, git: git.git, ssh: ssh.ssh, now: () => clock });

  assert.equal((await get(port, "/api/github/ssh-identity?owner=refused")).body.error, SSH_KEY_REFUSED);
  assert.equal((await get(port, "/api/github/ssh-identity?owner=unknown")).body.error, SSH_UNKNOWN_HOST);
  const offline = (await get(port, "/api/github/ssh-identity?owner=offline")).body;
  assert.equal(offline.login, null);
  assert.match(offline.error, /indisponível/);
  assert.equal(ssh.calls.length, 3);

  clock = 29_000;
  await get(port, "/api/github/ssh-identity?owner=refused");
  assert.equal(ssh.calls.length, 3);
  clock = 31_000;
  await get(port, "/api/github/ssh-identity?owner=refused");
  assert.equal(ssh.calls.length, 4);
});

test("ssh-identity por cwd: push URL do checkout validado; cwd fora do locate e 400", async () => {
  const repo = path.join(scanRoot, "work", "repo-z");
  mkdirSync(repo, { recursive: true });
  const stray = tmpDir();
  const git = fakeGit({
    remotes: { [repo]: "git@github.com:org-x/repo-z.git", [stray]: "git@github.com:org-x/repo-z.git" },
    pushUrls: { [repo]: "https://github.com/org-x/repo-z.git" },
  });
  const port = await start({ gh: fakeGh().gh, git: git.git });

  const res = await get(port, `/api/github/ssh-identity?cwd=${encodeURIComponent(repo)}`);
  assert.deepEqual(res.body, { owner: "org-x", host: null, login: null, error: REMOTE_HTTPS });
  assert.ok(git.calls.some((a) => a.join(" ") === `-C ${repo} -c credential.helper= remote get-url --push origin`));

  assert.equal((await get(port, `/api/github/ssh-identity?cwd=${encodeURIComponent(stray)}`)).status, 400);
  assert.equal((await get(port, "/api/github/ssh-identity?cwd=relativo")).status, 400);
});

test("protocol: git_protocol do gh para github.com", async () => {
  const fake = fakeGh((args) => {
    assert.deepEqual(args, ["config", "get", "git_protocol", "-h", "github.com"]);
    return { stdout: "ssh\n" };
  });
  const port = await start({ gh: fake.gh });
  assert.deepEqual((await get(port, "/api/github/protocol")).body, { protocol: "ssh" });
});
