import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { format, promisify } from "node:util";
import express from "express";
import { readConfig, resolveCwd } from "./cwd.mjs";
import { HttpError, listSkills, readCurrent } from "./data.mjs";
import { createTokens, loginParam, ownersParam, redact } from "./gh_env.mjs";
import { createGitHub } from "./github.mjs";
import { createSessions } from "./sessions.mjs";
import { createStore } from "./store.mjs";

export const VERSION = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")).version;

const KEEPALIVE_MS = 20_000;

const execFileAsync = promisify(execFile);
const runner =
  (bin, timeout = 20_000) =>
  (args, { env } = {}) =>
    execFileAsync(bin, args, { timeout, maxBuffer: 8 * 1024 * 1024, ...(env ? { env } : {}) });
const execGh = runner("gh");
const execGit = runner("git");
// Acima do `ConnectTimeout=8`: o timeout do proprio ssh vira mensagem; o nosso so pega travas.
const execSsh = runner("ssh", 12_000);

function openSse(req, res) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
  const keepalive = setInterval(() => res.write(": ping\n\n"), KEEPALIVE_MS);
  req.on("close", () => clearInterval(keepalive));
}

const frame = (type, payload) => `event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`;

/** `paletteSkills` ausente mostra tudo; presente, define recorte e ordem do ⌘K. */
async function paletteSkills() {
  const [skills, config] = await Promise.all([listSkills(), readConfig()]);
  if (!Array.isArray(config.paletteSkills)) return skills;
  const byName = new Map(skills.map((s) => [s.name, s]));
  return config.paletteSkills.filter((name) => byName.has(name)).map((name) => byName.get(name));
}

/** `org` e rotulo opaco: nada aqui le config para ele. Devolve os adicionais validados. */
function validateOrgDirs(org, cwd, additionalDirectories) {
  if (typeof org !== "string" || !org.trim()) throw new HttpError(400, "org invalida");
  if (typeof cwd !== "string" || !cwd) throw new HttpError(400, "cwd ausente");
  const extra = additionalDirectories ?? [];
  if (!Array.isArray(extra) || extra.some((d) => typeof d !== "string")) {
    throw new HttpError(400, "additionalDirectories invalido");
  }
  for (const dir of [cwd, ...extra]) {
    if (!path.isAbsolute(dir) || !existsSync(dir)) throw new HttpError(400, `diretorio invalido: ${dir}`);
  }
  return extra;
}

export function createEngine({
  query,
  sessionsDir,
  log: rawLog = () => {},
  gh = execGh,
  git = execGit,
  ssh = execSsh,
  now = Date.now,
}) {
  const tokens = createTokens({ gh, now });
  // Todo log passa por aqui ja formatado: um Error com o token no stderr nao sai inteiro.
  const log = (...args) => rawLog(redact(format(...args), tokens.known()));
  const store = createStore(sessionsDir, { log });
  const sessions = createSessions({ query, store, tokens });
  const github = createGitHub({ gh, git, ssh, now, resolveCwd, log, tokens });
  const app = express();
  app.use(express.json());

  const route = (handler) => async (req, res) => {
    try {
      res.json(await handler(req));
    } catch (err) {
      const status = err instanceof HttpError ? err.status : 500;
      if (status === 500) log(req.method, req.path, err);
      res.status(status).json({ error: redact(err.message, tokens.known()) });
    }
  };

  app.get("/api/health", route(() => ({ ok: true, version: VERSION })));

  app.get("/api/skills", route(paletteSkills));

  app.get(
    "/api/projects/:name/prs",
    route(async (req) => ({ prs: await github.prs(req.params.name, { account: loginParam(req.query.account) }) }))
  );

  app.get(
    "/api/review-inbox",
    route((req) => github.inbox({ account: loginParam(req.query.account), owners: ownersParam(req.query.owner) }))
  );

  app.get("/api/github/accounts", route(() => github.accounts()));

  app.get("/api/github/orgs", route((req) => github.orgs(loginParam(req.query.account))));

  app.get("/api/github/protocol", route(() => github.protocol()));

  app.get(
    "/api/github/ssh-identity",
    route((req) => {
      const fresh = req.query.fresh === "1";
      if (req.query.owner !== undefined) return github.sshIdentity({ owner: loginParam(req.query.owner), fresh });
      if (typeof req.query.cwd === "string") return github.sshIdentity({ cwd: req.query.cwd, fresh });
      throw new HttpError(400, "owner ou cwd ausente");
    })
  );

  app.get("/api/sessions", route(() => sessions.list()));

  // Antes de `/api/sessions/:id`: senao "stream" vira um id e responde 404.
  app.get("/api/sessions/stream", (req, res) => {
    openSse(req, res);
    res.write(frame("snapshot", sessions.list()));
    const unsubscribe = sessions.onChange((change) =>
      res.write(change.type === "removed" ? frame("removed", { id: change.id }) : frame("summary", change.summary))
    );
    req.on("close", unsubscribe);
  });

  app.post(
    "/api/sessions",
    route(async (req) => {
      const { project, command, model, cwd: explicitCwd, org, additionalDirectories } = req.body ?? {};
      if (typeof command !== "string" || !command.trim()) throw new HttpError(400, "comando vazio");
      const githubAccount = loginParam(req.body?.githubAccount);

      if (org !== undefined) {
        const dirs = validateOrgDirs(org, explicitCwd, additionalDirectories);
        const session = await sessions.create({
          project: "",
          org,
          githubAccount,
          cwd: explicitCwd,
          additionalDirectories: dirs,
          command: command.trim(),
          model,
        });
        log("sessao criada", session.id, `org ${org}`);
        return session.summary();
      }

      if (explicitCwd) {
        if (!existsSync(explicitCwd)) throw new HttpError(400, `diretorio invalido: ${explicitCwd}`);
        const session = await sessions.create({
          project: project || path.basename(explicitCwd),
          githubAccount,
          cwd: explicitCwd,
          command: command.trim(),
          model,
        });
        log("sessao criada", session.id, session.project);
        return session.summary();
      }

      const current = await readCurrent(project);
      const { cwd } = await resolveCwd(project, current);
      if (!cwd) {
        throw new HttpError(400, `sem diretório para ${project}: defina cwds.${project} em ~/.claude/workflow/.dashboard.json`);
      }

      const session = await sessions.create({ project, githubAccount, cwd, command: command.trim(), model });
      log("sessao criada", session.id, session.project);
      return session.summary();
    })
  );

  const withSession = (handler) =>
    route((req) => {
      const session = sessions.get(req.params.id);
      if (!session) throw new HttpError(404, "sessao nao encontrada");
      return handler(session, req);
    });

  app.get("/api/sessions/:id", withSession((session) => session.summary()));

  /** Retomar o que ja esta rodando nao e erro do usuario: `resume()` e no-op e devolvemos o estado. */
  async function ensureAttached(session) {
    if ((await session.resume()) === "not_resumable") {
      throw new HttpError(409, "sessao nao e retomavel — sem session_id do SDK");
    }
  }

  app.post(
    "/api/sessions/:id/resume",
    withSession(async (session) => {
      await ensureAttached(session);
      return session.summary();
    })
  );

  app.post(
    "/api/sessions/:id/input",
    withSession(async (session, req) => {
      const text = req.body?.text;
      if (typeof text !== "string" || !text.trim()) throw new HttpError(400, "texto vazio");
      await ensureAttached(session);
      session.send(text.trim());
      return session.summary();
    })
  );

  app.post(
    "/api/sessions/:id/permission",
    withSession((session, req) => {
      const { requestId, decision, answers } = req.body ?? {};
      if (!["allow", "always", "deny", "answer"].includes(decision)) throw new HttpError(400, `decisao invalida: ${decision}`);
      if (decision === "answer" && (!answers || typeof answers !== "object")) throw new HttpError(400, "answers ausente");
      if (!session.answerPermission(requestId, decision, answers)) throw new HttpError(409, "pedido ja resolvido");
      return session.summary();
    })
  );

  app.post(
    "/api/sessions/:id/interrupt",
    withSession(async (session) => {
      await session.interrupt();
      return session.summary();
    })
  );

  app.delete("/api/sessions/:id", route((req) => ({ deleted: sessions.remove(req.params.id) })));

  app.get("/api/sessions/:id/stream", (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) {
      res.status(404).json({ error: "sessao nao encontrada" });
      return;
    }

    openSse(req, res);
    const from = Number(req.query.from ?? 0);
    for (const event of session.events) {
      if (event.seq > from) res.write(frame("event", event));
    }
    res.write(frame("status", { status: session.status }));

    session.subscribers.add(res);
    req.on("close", () => session.subscribers.delete(res));
  });

  return { app, sessions, store };
}
