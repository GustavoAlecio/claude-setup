import { existsSync, promises as fs } from "node:fs";
import path from "node:path";
import { resolveCwd as defaultResolveCwd } from "./cwd.mjs";
import { HttpError, WORKFLOW_ROOT, safeSegment } from "./data.mjs";
import { LOGIN, createTokens, ghEnv, redactDeep } from "./gh_env.mjs";

const TTL_MS = 60_000;
const SSH_OK_TTL_MS = 5 * 60_000;
const SSH_ERROR_TTL_MS = 30_000;
const UNAUTHORIZED = /HTTP 401|Bad credentials/i;

export const GH_MISSING = "gh não encontrado no PATH do engine";
export const GH_NO_LOGIN = "gh sem login (gh auth login)";
export const NOT_PR_URL = "URL não é de PR do GitHub";
export const prNotFound = (account) =>
  `PR não encontrado ou sem acesso para a ${account ? `conta @${account}` : "conta ativa"}`;
export const PR_NOT_FOUND = prNotFound(null);
export const INVALID_ENTRY = "entrada inválida";
export const REMOTE_HTTPS = "remote https: identidade definida pelo credential helper, não verificável";
export const REMOTE_UNKNOWN = "remote não reconhecido";
export const NO_REMOTE = "remote não resolvido pelo git";
export const SSH_KEY_REFUSED = "chave recusada";
export const SSH_UNKNOWN_HOST = "host desconhecido em known_hosts";
export const SSH_UNAVAILABLE = "SSH indisponível (sem rede ou timeout)";
const GH_TIMEOUT = "gh não respondeu a tempo";
const GH_BAD_JSON = "resposta do gh não é JSON";

const PR_QUERY = `query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      state isDraft reviewDecision mergedAt updatedAt mergeable
      commits(last:1){ nodes{ commit{ statusCheckRollup{ state } } } }
      reviewThreads(first:100){
        nodes{
          isResolved
          comments(first:1){ nodes{ author{ login } body path line } }
        }
      }
    }
  }
}`;

const SEARCH_FIELDS = "number,title,repository,author,updatedAt,isDraft,url";

class GhError extends Error {}

function ghMessage(err, account) {
  if (err instanceof GhError || err instanceof HttpError) return err.message;
  if (err?.code === "ENOENT") return GH_MISSING;
  if (err?.killed) return GH_TIMEOUT;
  const stderr = String(err?.stderr ?? "").trim();
  const text = `${stderr}\n${err?.stdout ?? ""}`;
  if (err?.code === 4 || /gh auth login/i.test(text)) return GH_NO_LOGIN;
  if (/Could not resolve to a (Repository|PullRequest)/i.test(text)) return prNotFound(account);
  return (stderr || String(err?.message ?? err)).slice(0, 200);
}

function parseJson(stdout) {
  try {
    return JSON.parse(stdout);
  } catch {
    throw new GhError(GH_BAD_JSON);
  }
}

/** `owner/repo` de uma URL de PR (`https://github.com/o/r/pull/1`), ou null. */
export function prRepo(url) {
  const match = /^https:\/\/github\.com\/([^/\s]+)\/([^/\s]+)\/pull\/\d+(?:[/?#].*)?$/i.exec(url ?? "");
  return match ? `${match[1]}/${match[2]}` : null;
}

/** `owner/repo` de um remote ssh (`git@github.com:o/r.git`, `ssh://...`) ou https. */
export function remoteRepo(url) {
  const match = /github\.com[:/]([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/i.exec(String(url ?? "").trim());
  return match ? `${match[1]}/${match[2]}` : null;
}

const SAFE_HOST = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

function sshTarget(user, host, port) {
  if (!SAFE_HOST.test(host) || (user && !SAFE_HOST.test(user))) return { error: REMOTE_UNKNOWN };
  return { user: user ?? null, host, port: port ?? null };
}

/** `[user@]host:path`, `ssh://[user@]host[:port]/path`; `https`/`git://` não têm identidade SSH. */
export function parseRemote(url) {
  const text = String(url ?? "").trim();
  if (/^(https?|git):\/\//i.test(text)) return { error: REMOTE_HTTPS };
  const ssh = /^ssh:\/\/(?:([^@/\s]+)@)?([^:/\s]+)(?::(\d+))?\//i.exec(text);
  if (ssh) return sshTarget(ssh[1], ssh[2], ssh[3]);
  const scp = /^(?:([^@/:\s]+)@)?([^:/\s]+):(?!\/)/.exec(text);
  if (scp) return sshTarget(scp[1], scp[2], null);
  return { error: REMOTE_UNKNOWN };
}

/** O GitHub responde `Hi <login>!` no stderr e sai com 1 mesmo autenticado: o código não decide nada. */
function sshResult(out) {
  const stderr = String(out?.stderr ?? "");
  const hi = /Hi (\S+)!/.exec(stderr);
  if (hi) return { login: hi[1] };
  if (/Host key verification failed/i.test(stderr)) return { login: null, error: SSH_UNKNOWN_HOST };
  const network = /timed out|Could not resolve hostname|Connection refused|unreachable|No route to host/i;
  if (out?.killed || out?.code === "ENOENT" || network.test(stderr)) return { login: null, error: SSH_UNAVAILABLE };
  if (out?.code === 255 || /Permission denied/i.test(stderr)) return { login: null, error: SSH_KEY_REFUSED };
  return { login: null, error: SSH_UNAVAILABLE };
}

export function stageFrom({ state, isDraft, reviewDecision }, unresolved) {
  if (state === "MERGED") return "merged";
  if (state === "CLOSED") return "closed";
  if (isDraft) return "draft";
  // Thread aberta e trabalho pendente mesmo sem CHANGES_REQUESTED formal — mesma regra do /pr-status.
  if (reviewDecision === "CHANGES_REQUESTED" || unresolved.length > 0) return "changes_requested";
  if (reviewDecision === "APPROVED") return "approved";
  return "awaiting_review";
}

export function checksFrom(state) {
  if (!state) return null;
  if (state === "FAILURE" || state === "ERROR") return "failing";
  if (state === "PENDING" || state === "EXPECTED") return "pending";
  return "passing";
}

function liveFrom(pr) {
  const unresolved = (pr.reviewThreads?.nodes ?? [])
    .filter((thread) => thread && !thread.isResolved)
    .map((thread) => thread.comments?.nodes?.[0])
    .filter(Boolean)
    .map((comment) => ({
      path: comment.path ?? null,
      line: comment.line ?? null,
      author: comment.author?.login ?? "",
      body: comment.body ?? "",
    }));
  return {
    stage: stageFrom(pr, unresolved),
    checks: checksFrom(pr.commits?.nodes?.[0]?.commit?.statusCheckRollup?.state),
    unresolved,
    updatedAt: pr.updatedAt ?? null,
    mergedAt: pr.mergedAt ?? null,
  };
}

/**
 * Cache com TTL que guarda a promise: concorrentes compartilham a execucao e a falha tambem fica 60 s.
 * O que entra ja sai sem token: tudo que o cache devolve vai para resposta e log.
 */
function ttlCache(now, scrub) {
  const entries = new Map();
  return (key, load, account = null) => {
    const hit = entries.get(key);
    if (hit && now() - hit.at < TTL_MS) return hit.value;
    const value = load().then(
      (ok) => ({ ok: scrub(ok) }),
      (err) => ({ error: scrub(ghMessage(err, account)) })
    );
    entries.set(key, { at: now(), value });
    return value;
  };
}

/** Le `prs.json`; ausente ou malformado vira lista vazia. Duplicatas por `url` ficam com a ultima. */
async function readEntries(project, log) {
  const file = path.join(WORKFLOW_ROOT, project, "prs.json");
  let raw;
  try {
    raw = await fs.readFile(file, "utf8");
  } catch (err) {
    if (err.code !== "ENOENT") log("falha ao ler", file, err);
    return [];
  }
  let prs;
  try {
    prs = JSON.parse(raw).prs;
  } catch (err) {
    log("prs.json invalido", file, err.message);
    return [];
  }
  if (!Array.isArray(prs)) {
    log("prs.json sem array prs", file);
    return [];
  }
  const entries = prs.filter((pr) => pr && typeof pr === "object" && !Array.isArray(pr));
  const last = new Map(entries.map((pr, i) => [pr.url, i]));
  return entries.filter((pr, i) => typeof pr.url !== "string" || last.get(pr.url) === i);
}

export function createGitHub({
  gh,
  git,
  ssh,
  now = Date.now,
  resolveCwd = defaultResolveCwd,
  log = () => {},
  env = () => process.env,
  tokens = createTokens({ gh, now, env }),
}) {
  const cached = ttlCache(now, (value) => redactDeep(value, tokens.known()));
  const probes = new Map();

  /** Sem conta, o `gh` usa o keyring; com conta, o `GH_TOKEN` dela. Nada herdado do processo decide. */
  async function run(args, account = null) {
    const token = account ? await tokens.tokenFor(account) : null;
    try {
      return await gh(args, { env: ghEnv(env(), token) });
    } catch (err) {
      if (account && UNAUTHORIZED.test(`${err?.stderr ?? ""}\n${err?.stdout ?? ""}`)) tokens.invalidate(account);
      throw err;
    }
  }

  /** O engine nunca aciona credencial: `-c credential.helper=` vem logo depois do `-C`. */
  async function gitOut(cwd, args) {
    try {
      const { stdout } = await git([...(cwd ? ["-C", cwd] : []), "-c", "credential.helper=", ...args]);
      return String(stdout).trim() || null;
    } catch {
      return null;
    }
  }

  const activeLogin = () =>
    run(["api", "user", "-q", ".login"]).then(
      ({ stdout }) => String(stdout).trim() || null,
      () => null
    );

  /** Uma varredura por nome; o `cwd` so vale quando o `origin` aponta para o mesmo `owner/repo`. */
  function locate(nameWithOwner) {
    const key = nameWithOwner.toLowerCase();
    return cached(`cwd:${key}`, async () => {
      const name = nameWithOwner.split("/")[1];
      const { cwd, candidates } = await cached(`scan:${name}`, () => resolveCwd(name, null)).then((r) => {
        if (r.error) throw new GhError(r.error);
        return r.ok;
      });
      if (!cwd) {
        const reason = candidates.length > 1 ? `checkout ambíguo (${candidates.length} cópias)` : "sem checkout local";
        return { cwd: null, cwdCandidates: candidates, cwdReason: reason };
      }
      const remote = remoteRepo(await gitOut(cwd, ["config", "--get", "remote.origin.url"]));
      if (remote?.toLowerCase() === key) return { cwd, cwdCandidates: candidates, cwdReason: null };
      const reason = remote ? `${cwd} aponta para ${remote}` : `${cwd} sem remote origin do GitHub`;
      return { cwd: null, cwdCandidates: candidates, cwdReason: reason };
    }).then((r) => r.ok ?? { cwd: null, cwdCandidates: [], cwdReason: r.error });
  }

  function fetchPr(entry, nameWithOwner, account) {
    return cached(
      `pr:${account ?? "-"}:${entry.url}`,
      async () => {
        const [owner, repo] = nameWithOwner.split("/");
        const { stdout } = await run(
          [
            "api",
            "graphql",
            "-f",
            `query=${PR_QUERY}`,
            "-f",
            `owner=${owner}`,
            "-f",
            `repo=${repo}`,
            "-F",
            `pr=${entry.pr_number}`,
          ],
          account
        );
        const pr = parseJson(stdout)?.data?.repository?.pullRequest;
        if (!pr) throw new GhError(prNotFound(account));
        return liveFrom(pr);
      },
      account
    );
  }

  async function enrich(entry, account, accountError) {
    const nameWithOwner = typeof entry.url === "string" ? prRepo(entry.url) : null;
    const where = nameWithOwner ? locate(nameWithOwner) : { cwd: null, cwdCandidates: [], cwdReason: null };

    let result;
    if (typeof entry.url !== "string" || !Number.isInteger(entry.pr_number)) result = { error: INVALID_ENTRY };
    else if (!nameWithOwner) result = { error: NOT_PR_URL };
    else if (accountError) result = { error: accountError };
    else result = await fetchPr(entry, nameWithOwner, account);

    const base = { ...entry, repo: nameWithOwner?.split("/")[1] ?? null, nameWithOwner, ...(await where) };
    if (result.ok) return { ...base, ...result.ok, live: true };
    return {
      ...base,
      live: false,
      liveError: result.error,
      stage: entry.stage,
      checks: null,
      unresolved: [],
      updatedAt: null,
      mergedAt: null,
    };
  }

  /** Conta que nao loga nao derruba a aba: cada PR cai para o `prs.json` com a mensagem fixa. */
  async function prs(project, { account = null } = {}) {
    const entries = await readEntries(safeSegment(project), log);
    let accountError = null;
    if (account && entries.length) {
      await tokens.tokenFor(account).catch((err) => {
        accountError = err.message;
      });
    }
    return Promise.all(entries.map((entry) => enrich(entry, account, accountError)));
  }

  async function loadInbox(account, owners) {
    const [search, login] = await Promise.all([
      run(
        [
          "search",
          "prs",
          "--review-requested=@me",
          "--state=open",
          ...owners.flatMap((owner) => ["--owner", owner]),
          "--limit",
          "50",
          "--json",
          SEARCH_FIELDS,
        ],
        account
      ),
      account ?? activeLogin(),
    ]);
    const found = parseJson(search.stdout);
    if (!Array.isArray(found)) throw new GhError(GH_BAD_JSON);
    const valid = found.filter(
      (pr) =>
        Number.isInteger(pr?.number) &&
        typeof pr.url === "string" &&
        /^[^/\s]+\/[^/\s]+$/.test(pr.repository?.nameWithOwner ?? "")
    );
    const items = await Promise.all(
      valid.map(async (pr) => {
        const nameWithOwner = pr.repository.nameWithOwner;
        return {
          number: pr.number,
          title: typeof pr.title === "string" ? pr.title : "",
          url: pr.url,
          repo: nameWithOwner.split("/")[1],
          nameWithOwner,
          author: pr.author?.login ?? "",
          updatedAt: pr.updatedAt ?? null,
          isDraft: pr.isDraft === true,
          ...(await locate(nameWithOwner)),
        };
      })
    );
    return { items, login };
  }

  /**
   * Sem fallback: falha do `gh` vira 502 com a mensagem; conta que nao loga, 400 antes do cache.
   * `owners` chega normalizado (minusculas, sem duplicatas, ordenado) e e a mesma forma da chave.
   */
  async function inbox({ account = null, owners = [] } = {}) {
    if (account) await tokens.tokenFor(account);
    const result = await cached(`inbox:${account ?? "-"}:${owners.join(",")}`, () => loadInbox(account, owners), account);
    if (result.error) throw new HttpError(502, result.error);
    return result.ok;
  }

  /** So contas do keyring em `github.com`: uma entrada de env nao e selecionavel por `--user`. */
  async function accounts() {
    const result = await cached("accounts", async () => {
      let stdout;
      try {
        ({ stdout } = await run(["auth", "status", "--json", "hosts", "--hostname", "github.com"]));
      } catch (err) {
        // `gh auth status` sai com 1 quando alguma conta esta com erro, mas o JSON vem completo.
        if (!err?.stdout) throw err;
        stdout = err.stdout;
      }
      const list = parseJson(stdout)?.hosts?.["github.com"];
      if (!Array.isArray(list)) throw new GhError(GH_BAD_JSON);
      return list
        .filter((e) => e?.tokenSource === "keyring" && typeof e.login === "string" && LOGIN.test(e.login))
        .map((e) => ({ login: e.login, active: e.active === true, valid: e.state === "success" }));
    });
    if (result.error) throw new HttpError(502, result.error);
    return { accounts: result.ok };
  }

  /** Sugestoes de owner: o login da conta primeiro, depois as orgs dela, sem repetir (ignorando caixa). */
  async function orgs(account = null) {
    if (account) await tokens.tokenFor(account);
    const result = await cached(
      `orgs:${account ?? "-"}`,
      async () => {
        const [list, login] = await Promise.all([
          run(["api", "user/orgs", "--paginate", "--jq", ".[].login"], account),
          account ?? activeLogin(),
        ]);
        const names = String(list.stdout)
          .split("\n")
          .map((line) => line.trim())
          .filter((name) => LOGIN.test(name));
        const seen = new Set();
        const unique = [login, ...names].filter((name) => {
          if (!name || seen.has(name.toLowerCase())) return false;
          seen.add(name.toLowerCase());
          return true;
        });
        return { login, orgs: unique };
      },
      account
    );
    if (result.error) throw new HttpError(502, result.error);
    return result.ok;
  }

  async function protocol() {
    const result = await cached("protocol", async () => {
      const { stdout } = await run(["config", "get", "git_protocol", "-h", "github.com"]);
      return { protocol: String(stdout).trim() || null };
    });
    if (result.error) throw new HttpError(502, result.error);
    return result.ok;
  }

  /**
   * Uma conexao por `(user, host, port)`, com a promise compartilhada: sucesso vale 5 min, erro 30 s.
   * `StrictHostKeyChecking=yes` e `UpdateHostKeys=no` vencem o `~/.ssh/config`: nada grava `known_hosts`.
   */
  function probe({ user, host, port }, fresh) {
    const key = `${user ?? ""}@${host}:${port ?? ""}`;
    const hit = probes.get(key);
    if (!fresh && hit && (hit.ttl === null || now() - hit.at < hit.ttl)) return hit.value;
    const entry = { at: now(), ttl: null };
    const args = [
      "-T",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=8",
      "-o",
      "StrictHostKeyChecking=yes",
      "-o",
      "UpdateHostKeys=no",
      ...(port ? ["-p", port] : []),
      user ? `${user}@${host}` : host,
    ];
    entry.value = ssh(args)
      .then(
        (out) => out,
        (err) => err
      )
      .then((out) => {
        const result = sshResult(out);
        entry.at = now();
        entry.ttl = result.login ? SSH_OK_TTL_MS : SSH_ERROR_TTL_MS;
        return result;
      });
    probes.set(key, entry);
    return entry.value;
  }

  /** O `cwd` vem do app; so vale o checkout que `locate()` aceitou para o `owner/repo` do proprio origin. */
  async function validatedRepo(cwd) {
    if (typeof cwd !== "string" || !path.isAbsolute(cwd) || !existsSync(cwd)) throw new HttpError(400, "cwd inválido");
    const repo = remoteRepo(await gitOut(cwd, ["config", "--get", "remote.origin.url"]));
    if (!repo) throw new HttpError(400, `${cwd} sem remote origin do GitHub`);
    if ((await locate(repo)).cwd !== cwd) throw new HttpError(400, `${cwd} não é o checkout validado de ${repo}`);
    return repo;
  }

  /** URL efetiva pelo proprio git (`insteadOf` incluido), sem parser de config no engine. */
  async function sshIdentity({ owner = null, cwd = null, fresh = false }) {
    let who;
    let url;
    if (owner) {
      who = owner;
      url = await gitOut(null, ["ls-remote", "--get-url", `git@github.com:${owner}/x.git`]);
    } else {
      who = (await validatedRepo(cwd)).split("/")[0];
      url = await gitOut(cwd, ["remote", "get-url", "--push", "origin"]);
    }
    if (!url) return { owner: who, host: null, login: null, error: NO_REMOTE };
    const target = parseRemote(url);
    if (target.error) return { owner: who, host: null, login: null, error: target.error };
    return { owner: who, host: target.host, ...(await probe(target, fresh)) };
  }

  return { prs, inbox, accounts, orgs, protocol, sshIdentity, tokens };
}
