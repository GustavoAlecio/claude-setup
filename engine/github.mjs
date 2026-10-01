import { promises as fs } from "node:fs";
import path from "node:path";
import { resolveCwd as defaultResolveCwd } from "./cwd.mjs";
import { HttpError, WORKFLOW_ROOT, safeSegment } from "./data.mjs";

const TTL_MS = 60_000;

export const GH_MISSING = "gh não encontrado no PATH do engine";
export const GH_NO_LOGIN = "gh sem login (gh auth login)";
export const NOT_PR_URL = "URL não é de PR do GitHub";
export const PR_NOT_FOUND = "PR não encontrado ou sem acesso para a conta ativa";
export const INVALID_ENTRY = "entrada inválida";
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

function ghMessage(err) {
  if (err instanceof GhError) return err.message;
  if (err?.code === "ENOENT") return GH_MISSING;
  if (err?.killed) return GH_TIMEOUT;
  const stderr = String(err?.stderr ?? "").trim();
  const text = `${stderr}\n${err?.stdout ?? ""}`;
  if (err?.code === 4 || /gh auth login/i.test(text)) return GH_NO_LOGIN;
  if (/Could not resolve to a (Repository|PullRequest)/i.test(text)) return PR_NOT_FOUND;
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

/** Cache com TTL que guarda a promise: concorrentes compartilham a execucao e a falha tambem fica 60 s. */
function ttlCache(now) {
  const entries = new Map();
  return (key, load) => {
    const hit = entries.get(key);
    if (hit && now() - hit.at < TTL_MS) return hit.value;
    const value = load().then(
      (ok) => ({ ok }),
      (err) => ({ error: ghMessage(err) })
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

export function createGitHub({ gh, git, now = Date.now, resolveCwd = defaultResolveCwd, log = () => {} }) {
  const cached = ttlCache(now);

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
      let remote = null;
      try {
        remote = remoteRepo((await git(["-C", cwd, "config", "--get", "remote.origin.url"])).stdout);
      } catch {}
      if (remote?.toLowerCase() === key) return { cwd, cwdCandidates: candidates, cwdReason: null };
      const reason = remote ? `${cwd} aponta para ${remote}` : `${cwd} sem remote origin do GitHub`;
      return { cwd: null, cwdCandidates: candidates, cwdReason: reason };
    }).then((r) => r.ok ?? { cwd: null, cwdCandidates: [], cwdReason: r.error });
  }

  function fetchPr(entry, nameWithOwner) {
    return cached(`pr:${entry.url}`, async () => {
      const [owner, repo] = nameWithOwner.split("/");
      const { stdout } = await gh([
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
      ]);
      const pr = parseJson(stdout)?.data?.repository?.pullRequest;
      if (!pr) throw new GhError(PR_NOT_FOUND);
      return liveFrom(pr);
    });
  }

  async function enrich(entry) {
    const nameWithOwner = typeof entry.url === "string" ? prRepo(entry.url) : null;
    const where = nameWithOwner ? locate(nameWithOwner) : { cwd: null, cwdCandidates: [], cwdReason: null };

    let result;
    if (typeof entry.url !== "string" || !Number.isInteger(entry.pr_number)) result = { error: INVALID_ENTRY };
    else if (!nameWithOwner) result = { error: NOT_PR_URL };
    else result = await fetchPr(entry, nameWithOwner);

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

  async function prs(project) {
    const entries = await readEntries(safeSegment(project), log);
    return Promise.all(entries.map(enrich));
  }

  async function loadInbox() {
    const [search, login] = await Promise.all([
      gh(["search", "prs", "--review-requested=@me", "--state=open", "--limit", "50", "--json", SEARCH_FIELDS]),
      gh(["api", "user", "-q", ".login"]).then(
        ({ stdout }) => String(stdout).trim() || null,
        () => null
      ),
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

  /** Sem fallback: falha do `gh` vira 502 com a mensagem. */
  async function inbox() {
    const result = await cached("inbox", loadInbox);
    if (result.error) throw new HttpError(502, result.error);
    return result.ok;
  }

  return { prs, inbox };
}
