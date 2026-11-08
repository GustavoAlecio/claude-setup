import { execFile } from "node:child_process";
import { existsSync, promises as fs, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { format, promisify } from "node:util";
import express from "express";
import { readConfig, resolveCwd } from "./cwd.mjs";
import { listTerminalSessions, transcriptEvents } from "./terminal.mjs";
import { CLAUDE_HOME, HttpError, listSkills, readCurrent, safeSegment } from "./data.mjs";
import { createTokens, loginParam, ownersParam, redact } from "./gh_env.mjs";
import { createGitHub } from "./github.mjs";
import { DEFAULT_ACCOUNT, accountParam, agyBin, createAccounts } from "./accounts.mjs";
import { createAgy } from "./agy.mjs";
import { MAX_DIAGRAM_CHARS, THEMES, createMermaid } from "./mermaid.mjs";
import { IMAGE_TYPES, PERMISSION_MODES, PROVIDERS, createSessions } from "./sessions.mjs";
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

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function absoluteDirParam(dir) {
  if (typeof dir !== "string" || !path.isAbsolute(dir) || !existsSync(dir)) throw new HttpError(400, `diretorio invalido: ${dir}`);
  return dir;
}

function providerParam(value) {
  if (value === undefined || value === null) return "anthropic";
  if (!PROVIDERS.has(value)) throw new HttpError(400, `provider invalido: ${value}`);
  return value;
}

const CYCLE_ACTIONS = new Set(["pause", "resume", "archive"]);
const WF_CYCLE = fileURLToPath(new URL("../bin/wf-cycle.py", import.meta.url));
const MODELS_TTL_MS = 10 * 60_000;
const MAX_IMAGES = 6;
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
const ATTACHMENT = /^[0-9a-f-]{36}\.(png|jpg|gif|webp)$/;

/** Ate [MAX_IMAGES] imagens de ate 5 MB (o limite do Claude por imagem), so nos tipos que o modelo le. */
function imagesParam(value) {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > MAX_IMAGES) throw new HttpError(400, `ate ${MAX_IMAGES} imagens`);
  return value.map((image) => {
    const { mediaType, data } = image ?? {};
    if (!IMAGE_TYPES[mediaType] || typeof data !== "string" || !data) throw new HttpError(400, "imagem invalida");
    if (Buffer.byteLength(data, "base64") > MAX_IMAGE_BYTES) throw new HttpError(413, "imagem acima de 5 MB");
    return { mediaType, data };
  });
}
const CLAUDE_MODELS_TIMEOUT_MS = 30_000;
const MODEL = /^[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,99}$/;

function modelParam(value) {
  if (typeof value !== "string" || !MODEL.test(value)) throw new HttpError(400, "modelo invalido");
  return value;
}

/** Fila de prompt que nunca entrega nada: a consulta so existe para responder `supportedModels()`. */
async function* idlePrompt(signal) {
  await new Promise((resolve) => signal.addEventListener("abort", resolve));
}

/** O SDK so responde modelos e conta com uma sessao aberta: abre uma descartavel, pergunta e a encerra. */
async function probeClaude(query, ask) {
  const abort = new AbortController();
  const q = query({ prompt: idlePrompt(abort.signal), options: { abortController: abort, cwd: os.homedir() } });
  const timeout = new Promise((_, reject) =>
    setTimeout(() => reject(new Error("timeout consultando o Claude Code")), CLAUDE_MODELS_TIMEOUT_MS).unref()
  );
  try {
    return await Promise.race([ask(q), timeout]);
  } finally {
    abort.abort();
  }
}

async function listClaudeModels(query) {
  const models = await probeClaude(query, (q) => q.supportedModels());
  return models.map((m) => ({ id: m.value, label: m.displayName || m.value }));
}
const ARTIFACT_MAX_BYTES = 2 * 1024 * 1024;

/** So arquivos de topo da conversa: `.system_generated` e os `.metadata.json` sao internos do `agy`. */
const isArtifactName = (name) =>
  typeof name === "string" && !name.startsWith(".") && !name.includes("/") && !name.endsWith(".metadata.json");

/** `agy models` imprime `slug<TAB>rotulo` por linha depois de um cabecalho. */
export function parseAgyModels(stdout) {
  return stdout
    .split("\n")
    .map((line) => line.split("\t"))
    .filter((cols) => cols.length >= 2 && cols[0].trim())
    .map(([id, label]) => ({ id: id.trim(), label: label.trim() }));
}

const QUOTA_TTL_MS = 60_000;

/**
 * `agy -p /quota`: `<grupo>\t<rotulo>\t<n>%\t<reset ISO>` por linha. As familias saem do nome do grupo
 * ("Claude and GPT models" -> claude, gpt) e casam com o prefixo do id do modelo.
 */
export function parseAgyQuota(stdout) {
  return stdout
    .split("\n")
    .map((line) => line.split("\t").map((c) => c.trim()))
    .filter((cols) => cols.length >= 4 && /^\d+%$/.test(cols[2]))
    .map(([group, , percent, resetsAt]) => ({
      families: group
        .toLowerCase()
        .replace(/\bmodels?\b/g, "")
        .split(/\band\b|,/)
        .map((f) => f.trim())
        .filter(Boolean),
      remaining: Number.parseInt(percent, 10) / 100,
      resetsAt: Number.isNaN(Date.parse(resetsAt)) ? null : new Date(resetsAt).toISOString(),
    }));
}

export function quotaFor(modelId, groups) {
  const id = modelId.toLowerCase();
  const group = groups.find((g) => g.families.some((f) => id.startsWith(f)));
  return group ? { remaining: group.remaining, resetsAt: group.resetsAt } : null;
}

/** Ausente e `default`: o engine nunca le o modo da config, quem resolve sessao > org > global e o app. */
function permissionModeParam(value) {
  if (value === undefined) return "default";
  if (!PERMISSION_MODES.has(value)) throw new HttpError(400, `permissionMode invalido: ${value}`);
  return value;
}

export function createEngine({
  query,
  sessionsDir,
  log: rawLog = () => {},
  gh = execGh,
  git = execGit,
  ssh = execSsh,
  now = Date.now,
  accounts = createAccounts(),
  agy: agyOverride,
  mermaid: mermaidOverride,
  reveal = (file) => execFileAsync("open", ["-R", file], { timeout: 10_000 }),
  execAgy = (args, { env }) => execFileAsync(agyBin(), args, { timeout: 60_000, env, maxBuffer: 1024 * 1024 }),
  cycleCommand = (action, project) =>
    execFileAsync("python3", [WF_CYCLE, action, project], { timeout: 60_000, maxBuffer: 1024 * 1024 }),
}) {
  const tokens = createTokens({ gh, now });
  // Todo log passa por aqui ja formatado: um Error com o token no stderr nao sai inteiro.
  const log = (...args) => rawLog(redact(format(...args), tokens.known()));
  const store = createStore(sessionsDir, { log });
  let gateUrl = null;
  const agy = agyOverride ?? createAgy({ accounts, gateUrl: () => gateUrl });
  const attachmentsDir = path.join(sessionsDir, "attachments");
  const sessions = createSessions({ query, agyQuery: agy.query, store, tokens, attachmentsDir });
  const mermaid = mermaidOverride ?? createMermaid({ cacheDir: path.join(sessionsDir, "mermaid-cache"), log });
  const github = createGitHub({ gh, git, ssh, now, resolveCwd, log, tokens });
  const app = express();

  // Antes do parser global: o hook manda o conteudo inteiro do arquivo, acima do limite padrao.
  app.post("/internal/agy-gate", express.json({ limit: "64mb" }), async (req, res) => {
    const abort = new AbortController();
    res.on("close", () => {
      if (!res.writableEnded) abort.abort();
    });
    try {
      res.json(await agy.decide(req.body ?? {}, abort.signal));
    } catch (err) {
      const status = err instanceof HttpError ? err.status : 500;
      if (status === 500) log("gate", err);
      res.status(status).json({ error: err.message });
    }
  });

  // Imagens anexadas chegam em base64 no corpo do `input`.
  app.use(express.json({ limit: "48mb" }));

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

  // Pausar, retomar e arquivar o ciclo passam pelo bin/wf-cycle.py, que respeita o lock do current.json.
  app.post(
    "/api/projects/:project/cycle",
    route(async (req) => {
      const project = safeSegment(req.params.project);
      const action = req.body?.action;
      if (!CYCLE_ACTIONS.has(action)) throw new HttpError(400, "acao invalida");
      try {
        await cycleCommand(action, project);
      } catch (err) {
        const message = String(err?.stderr ?? "").trim() || err.message;
        throw new HttpError(err?.code === 1 ? 409 : 500, message);
      }
      log("ciclo", action, project);
      return { ok: true };
    })
  );

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

  app.get("/api/agy/accounts/:account", route((req) => accounts.status(accountParam(req.params.account))));

  app.post("/api/agy/accounts/:account/login", route((req) => accounts.login(accountParam(req.params.account))));

  const modelsCache = new Map();
  const quotaCache = new Map();
  app.get(
    "/api/agy/models",
    route(async (req) => {
      const account = accountParam(req.query.account);
      const home = await accounts.prepare(account);
      const env = { ...process.env, HOME: home };
      let models = modelsCache.get(account)?.at > now() - MODELS_TTL_MS ? modelsCache.get(account).models : null;
      if (!models) {
        let stdout;
        try {
          ({ stdout } = await execAgy(["models"], { env }));
        } catch (err) {
          throw new HttpError(502, `agy models falhou: ${String(err.stderr || err.stdout || err.message).trim()}`);
        }
        models = parseAgyModels(stdout);
        if (!models.length) throw new HttpError(409, `conta ${account} sem login no Antigravity`);
        // Uma lista vazia nao entra no cache: o login no Terminal pode acontecer logo depois.
        modelsCache.set(account, { at: now(), models });
      }
      // A cota muda a cada turno: cache curto e separado. Falhar aqui so deixa os modelos sem cota.
      let quota = quotaCache.get(account)?.at > now() - QUOTA_TTL_MS ? quotaCache.get(account).groups : null;
      if (!quota) {
        quota = await execAgy(["-p", "/quota"], { env })
          .then(({ stdout }) => parseAgyQuota(stdout))
          .catch((err) => {
            log("agy /quota falhou", err.message);
            return [];
          });
        if (quota.length) quotaCache.set(account, { at: now(), groups: quota });
      }
      return { models: models.map((m) => ({ ...m, quota: quotaFor(m.id, quota) })) };
    })
  );

  let claudeModels = null;
  app.get(
    "/api/claude/models",
    route(async () => {
      if (claudeModels && now() - claudeModels.at < MODELS_TTL_MS) return { models: claudeModels.models };
      let models;
      try {
        models = await listClaudeModels(query);
      } catch (err) {
        throw new HttpError(502, `modelos do Claude indisponiveis: ${err.message}`);
      }
      claudeModels = { at: now(), models };
      return { models };
    })
  );

  app.post("/api/mermaid", async (req, res) => {
    const { code, theme = "dark" } = req.body ?? {};
    try {
      if (typeof code !== "string" || !code.trim() || code.length > MAX_DIAGRAM_CHARS || !THEMES.has(theme)) {
        throw new HttpError(400, "diagrama invalido");
      }
      res.type("png").send(await mermaid.png(code, theme));
    } catch (err) {
      const status = err instanceof HttpError ? err.status : 500;
      if (status === 500) log("mermaid", err);
      res.status(status).json({ error: err.message });
    }
  });

  /** Checklist do primeiro uso: Claude Code logado (e com qual conta), `gh` logado, Node do engine. */
  let readiness = null;
  app.get(
    "/api/readiness",
    route(async (req) => {
      if (readiness && req.query.fresh !== "1" && now() - readiness.at < QUOTA_TTL_MS) return readiness.value;
      const [claude, gh] = await Promise.all([
        probeClaude(query, (q) => q.accountInfo()).then(
          (info) => ({
            ok: Boolean(info?.email || info?.apiKeySource || (info?.apiProvider && info.apiProvider !== "firstParty")),
            account: info?.email ?? info?.apiProvider ?? null,
            plan: info?.subscriptionType ?? null,
          }),
          (err) => ({ ok: false, error: err.message })
        ),
        github.accounts().then(
          ({ accounts: list }) => {
            const valid = list.filter((a) => a.valid);
            return { ok: valid.length > 0, accounts: valid.map((a) => a.login), active: valid.find((a) => a.active)?.login ?? null };
          },
          (err) => ({ ok: false, error: err.message })
        ),
      ]);
      const value = { claude, gh, node: { ok: true, version: process.version } };
      readiness = { at: now(), value };
      return value;
    })
  );

  app.get("/api/sessions", route(() => sessions.list()));

  // Antes de `/api/sessions/:id`: senao "stream" vira um id e responde 404.
  // Quem ouve o stream global e o app aberto: `/api/ui` diz se ha alguem para receber um `open-terminal`.
  const appClients = new Set();

  app.get("/api/sessions/stream", (req, res) => {
    openSse(req, res);
    appClients.add(res);
    req.on("close", () => appClients.delete(res));
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
      const permissionMode = permissionModeParam(req.body?.permissionMode);
      const provider = providerParam(req.body?.provider);
      const agent = { provider, account: provider === "antigravity" ? accountParam(req.body?.account) : null };
      const images = imagesParam(req.body?.images);

      if (org !== undefined) {
        const dirs = validateOrgDirs(org, explicitCwd, additionalDirectories);
        const session = await sessions.create({
          project: "",
          org,
          githubAccount,
          ...agent,
          cwd: explicitCwd,
          additionalDirectories: dirs,
          command: command.trim(),
          images,
          model,
          permissionMode,
        });
        log("sessao criada", session.id, `org ${org}`);
        return session.summary();
      }

      if (explicitCwd) {
        if (!existsSync(explicitCwd)) throw new HttpError(400, `diretorio invalido: ${explicitCwd}`);
        const session = await sessions.create({
          project: project || path.basename(explicitCwd),
          githubAccount,
          ...agent,
          cwd: explicitCwd,
          command: command.trim(),
          images,
          model,
          permissionMode,
        });
        log("sessao criada", session.id, session.project);
        return session.summary();
      }

      const current = await readCurrent(project);
      const { cwd } = await resolveCwd(project, current);
      if (!cwd) {
        throw new HttpError(400, `sem diretório para ${project}: defina cwds.${project} em ~/.claude/workflow/.dashboard.json`);
      }

      const session = await sessions.create({
        project,
        githubAccount,
        ...agent,
        cwd,
        command: command.trim(),
        images,
        model,
        permissionMode,
      });
      log("sessao criada", session.id, session.project);
      return session.summary();
    })
  );

  app.get(
    "/api/terminal-sessions",
    route(async (req) => {
      const cwd = absoluteDirParam(req.query.cwd);
      return listTerminalSessions(CLAUDE_HOME, cwd, { exclude: sessions.sdkSessionIds() });
    })
  );

  app.get("/api/ui", route(() => ({ clients: appClients.size })));

  /** Pedido de fora do app (o `/app` no terminal): o app importa a sessao com as regras dele e a abre. */
  app.post(
    "/api/ui/open-terminal",
    route((req) => {
      const { sdkSessionId } = req.body ?? {};
      if (typeof sdkSessionId !== "string" || !UUID.test(sdkSessionId)) throw new HttpError(400, `sdkSessionId invalido: ${sdkSessionId}`);
      const cwd = absoluteDirParam(req.body?.cwd);
      if (appClients.size === 0) throw new HttpError(409, "nenhum app conectado");
      for (const res of appClients) res.write(frame("open-terminal", { sdkSessionId, cwd }));
      return { clients: appClients.size };
    })
  );

  app.post(
    "/api/sessions/import",
    route(async (req) => {
      const { sdkSessionId, project } = req.body ?? {};
      if (typeof sdkSessionId !== "string" || !UUID.test(sdkSessionId)) throw new HttpError(400, `sdkSessionId invalido: ${sdkSessionId}`);
      if (typeof project !== "string" || !project) throw new HttpError(400, "projeto vazio");
      const cwd = absoluteDirParam(req.body?.cwd);
      const transcript = await transcriptEvents(CLAUDE_HOME, cwd, sdkSessionId).catch((err) => {
        if (err.code === "ENOENT") throw new HttpError(404, `transcript nao encontrado: ${sdkSessionId}`);
        throw err;
      });
      const command = transcript.firstPrompt ?? "Sessão do terminal";
      const session = await sessions.adopt(
        {
          project,
          githubAccount: loginParam(req.body?.githubAccount),
          cwd,
          command,
          model: transcript.model ?? undefined,
          permissionMode: permissionModeParam(req.body?.permissionMode),
        },
        { sdkSessionId, ...transcript }
      );
      log("sessao importada do terminal", session.id, sdkSessionId);
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

  /**
   * Pergunta lateral: uma sessao nova que ve tudo o que [id] fez (fork do transcript) mas nao entra no contexto dela,
   * em `plan` para so ler. Antigravity nao tem fork de conversa.
   */
  app.post(
    "/api/sessions/:id/aside",
    withSession(async (parent, req) => {
      const text = req.body?.text;
      if (typeof text !== "string" || !text.trim()) throw new HttpError(400, "pergunta vazia");
      if (parent.provider !== "anthropic") throw new HttpError(409, "pergunta lateral so em sessoes Anthropic");
      if (!parent.sdkSessionId) throw new HttpError(409, "a sessao ainda nao tem historico para a pergunta partir dele");
      const session = await sessions.create({
        project: parent.project,
        org: parent.org,
        githubAccount: parent.githubAccount,
        cwd: parent.cwd,
        additionalDirectories: parent.additionalDirectories,
        command: text.trim(),
        model: parent.model ?? undefined,
        permissionMode: "plan",
        forkFrom: parent.sdkSessionId,
        asideOf: parent.id,
      });
      log("pergunta lateral", session.id, "de", parent.id);
      return session.summary();
    })
  );

  /** Pasta onde o `agy` grava os artefatos da conversa; `null` fora do Antigravity ou antes do primeiro init. */
  const artifactsDir = (session) =>
    session.provider === "antigravity" && session.sdkSessionId
      ? path.join(accounts.dirFor(session.account ?? DEFAULT_ACCOUNT), ".gemini", "antigravity-cli", "brain", session.sdkSessionId)
      : null;

  app.get("/api/sessions/:id/attachments/:name", (req, res) => {
    const { id, name } = req.params;
    if (!sessions.get(id) || !ATTACHMENT.test(name)) return res.status(404).json({ error: "anexo nao encontrado" });
    res.sendFile(path.join(attachmentsDir, id, name), (err) => {
      if (err && !res.headersSent) res.status(404).json({ error: "anexo nao encontrado" });
    });
  });

  app.get(
    "/api/sessions/:id/artifacts",
    withSession(async (session) => {
      const dir = artifactsDir(session);
      if (!dir) return { artifacts: [] };
      const entries = await fs.readdir(dir, { withFileTypes: true }).catch(() => []);
      const artifacts = [];
      for (const entry of entries) {
        if (!entry.isFile() || !isArtifactName(entry.name)) continue;
        const stat = await fs.stat(path.join(dir, entry.name));
        artifacts.push({ name: entry.name, size: stat.size, modifiedAt: stat.mtime.toISOString() });
      }
      return { artifacts: artifacts.sort((a, b) => b.modifiedAt.localeCompare(a.modifiedAt)) };
    })
  );

  app.get(
    "/api/sessions/:id/artifacts/:name",
    withSession(async (session, req) => {
      const dir = artifactsDir(session);
      const { name } = req.params;
      if (!dir || !isArtifactName(name)) throw new HttpError(404, "artefato nao encontrado");
      const file = path.join(dir, name);
      const stat = await fs.stat(file).catch(() => null);
      if (!stat?.isFile()) throw new HttpError(404, "artefato nao encontrado");
      if (stat.size > ARTIFACT_MAX_BYTES) throw new HttpError(413, "artefato grande demais");
      return { name, content: await fs.readFile(file, "utf8") };
    })
  );

  /** A pasta da conversa fica dentro do HOME sombra: o Finder ja abre com o arquivo selecionado. */
  app.post(
    "/api/sessions/:id/artifacts/:name/reveal",
    withSession(async (session, req) => {
      const dir = artifactsDir(session);
      const { name } = req.params;
      if (!dir || !isArtifactName(name) || !existsSync(path.join(dir, name))) throw new HttpError(404, "artefato nao encontrado");
      await reveal(path.join(dir, name));
      return { revealed: true };
    })
  );

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
      const images = imagesParam(req.body?.images);
      await ensureAttached(session);
      session.send(text.trim(), images);
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
    "/api/sessions/:id/permission-mode",
    withSession(async (session, req) => {
      const mode = req.body?.mode;
      if (!PERMISSION_MODES.has(mode)) throw new HttpError(400, `modo invalido: ${mode}`);
      await session.setPermissionMode(mode);
      return session.summary();
    })
  );

  app.post(
    "/api/sessions/:id/model",
    withSession(async (session, req) => {
      await session.setModel(modelParam(req.body?.model));
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

  /** O hook do `agy` precisa da porta, que so existe depois do `listen`. */
  function listening(port) {
    gateUrl = `http://127.0.0.1:${port}/internal/agy-gate`;
  }

  return { app, sessions, store, listening, mermaid };
}
