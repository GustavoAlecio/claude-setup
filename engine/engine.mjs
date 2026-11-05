import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import express from "express";
import { readConfig, resolveCwd } from "./cwd.mjs";
import { HttpError, listSkills, readCurrent } from "./data.mjs";
import { createSessions } from "./sessions.mjs";
import { createStore } from "./store.mjs";

export const VERSION = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")).version;

const KEEPALIVE_MS = 20_000;

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

export function createEngine({ query, sessionsDir, log = () => {} }) {
  const store = createStore(sessionsDir, { log });
  const sessions = createSessions({ query, store });
  const app = express();
  app.use(express.json());

  const route = (handler) => async (req, res) => {
    try {
      res.json(await handler(req));
    } catch (err) {
      const status = err instanceof HttpError ? err.status : 500;
      if (status === 500) log(req.method, req.path, err);
      res.status(status).json({ error: err.message });
    }
  };

  app.get("/api/health", route(() => ({ ok: true, version: VERSION })));

  app.get("/api/skills", route(paletteSkills));

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

      if (org !== undefined) {
        const dirs = validateOrgDirs(org, explicitCwd, additionalDirectories);
        const session = sessions.create({
          project: "",
          org,
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
        const session = sessions.create({
          project: project || path.basename(explicitCwd),
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

      const session = sessions.create({ project, cwd, command: command.trim(), model });
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
  function ensureAttached(session) {
    if (session.resume() === "not_resumable") throw new HttpError(409, "sessao nao e retomavel — sem session_id do SDK");
  }

  app.post(
    "/api/sessions/:id/resume",
    withSession((session) => {
      ensureAttached(session);
      return session.summary();
    })
  );

  app.post(
    "/api/sessions/:id/input",
    withSession((session, req) => {
      const text = req.body?.text;
      if (typeof text !== "string" || !text.trim()) throw new HttpError(400, "texto vazio");
      ensureAttached(session);
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
