import { randomUUID } from "node:crypto";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { CLAUDE_HOME, HttpError } from "./data.mjs";
import { redact, redactDeep, sessionEnv } from "./gh_env.mjs";
import { liveTerminalSessions } from "./terminal.mjs";

const TITLE_MAX = 60;

/** O que o app oferece; `plan` e `dontAsk` ficam de fora. */
export const PERMISSION_MODES = new Set(["default", "acceptEdits", "auto", "bypassPermissions", "plan"]);

export const PROVIDERS = new Set(["anthropic", "antigravity"]);

export const IMAGE_TYPES = { "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp" };

function titleFor(command) {
  const line = command.replace(/\s+/g, " ").trim();
  return line.length > TITLE_MAX ? `${line.slice(0, TITLE_MAX - 1).trimEnd()}…` : line;
}

/** Last `/skill` the user sent: a free conversation turns into a pipeline session when it runs `/kickoff`. */
function skillOf(text) {
  const first = text.trimStart().split(/\s/, 1)[0];
  return first.startsWith("/") && first.length > 1 ? first : null;
}

function lastSkill(events) {
  for (let i = events.length - 1; i >= 0; i--) {
    const skill = events[i].kind === "user_text" ? skillOf(events[i].text ?? "") : null;
    if (skill) return skill;
  }
  return null;
}

function initModel(events) {
  return events?.findLast((e) => e.kind === "init")?.model ?? null;
}

function createInputStream() {
  const queue = [];
  let wake = null;
  let closed = false;

  return {
    push(message) {
      queue.push(message);
      wake?.();
      wake = null;
    },
    close() {
      closed = true;
      wake?.();
      wake = null;
    },
    async *[Symbol.asyncIterator]() {
      while (true) {
        if (queue.length) {
          yield queue.shift();
          continue;
        }
        if (closed) return;
        await new Promise((resolve) => {
          wake = resolve;
        });
      }
    },
  };
}

class Session {
  constructor(
    {
      project,
      org = null,
      githubAccount = null,
      provider = "anthropic",
      account = null,
      cwd,
      additionalDirectories = [],
      command,
      images = [],
      model,
      permissionMode = "default",
      forkFrom = null,
      asideOf = null,
      restored,
    },
    { query, agyQuery, store, changed, tokens, attachmentsDir, liveElsewhere }
  ) {
    this.attachmentsDir = attachmentsDir;
    this.queryFn = provider === "antigravity" ? agyQuery : query;
    this.liveElsewhere = liveElsewhere;
    this.store = store;
    this.tokens = tokens;
    this.changed = () => changed(this);
    this.id = restored?.id ?? randomUUID();
    this.project = project;
    this.org = org;
    this.githubAccount = githubAccount;
    this.provider = provider;
    this.account = account;
    this.cwd = cwd;
    this.additionalDirectories = additionalDirectories;
    this.command = command;
    // So vao na primeira mensagem; depois disso ficam em attachments, como as de qualquer send.
    this.initialImages = images;
    this.title = titleFor(command);
    this.requestedModel = model ?? null;
    // Lido pelo `attach`: uma troca durante o `attaching` ja vale para o resume em curso.
    this.permissionMode = permissionMode;
    // Pergunta lateral: nasce de um fork do transcript de [asideOf] e nunca grava nele.
    this.forkFrom = forkFrom;
    this.asideOf = asideOf;
    this.createdAt = restored?.createdAt ?? new Date().toISOString();
    this.events = restored?.events ?? [];
    this.model = initModel(this.events) ?? this.requestedModel;
    this.skill = lastSkill(this.events) ?? skillOf(command);
    this.sdkSessionId = restored?.sdkSessionId ?? null;
    this.cost = restored?.cost ?? 0;
    // Uma sessao vinda do disco nao tem processo por tras: so volta a viver via resume().
    this.status = restored ? "detached" : "starting";
    this.subscribers = new Set();
    this.pending = new Map();
    this.query = null;
    this.abort = null;
    this.input = null;
    this.consuming = null;
    this.attaching = null;
    // So em memoria: o snapshot guarda a conta, e o resume pede o token de novo.
    this.token = null;
  }

  snapshot() {
    return {
      id: this.id,
      project: this.project,
      org: this.org,
      githubAccount: this.githubAccount,
      provider: this.provider,
      account: this.account,
      cwd: this.cwd,
      additionalDirectories: this.additionalDirectories,
      command: this.command,
      permissionMode: this.permissionMode,
      ...(this.asideOf ? { asideOf: this.asideOf, forkFrom: this.forkFrom } : {}),
      requestedModel: this.requestedModel,
      createdAt: this.createdAt,
      sdkSessionId: this.sdkSessionId,
      cost: this.cost,
      events: this.events,
    };
  }

  /**
   * Reimport do terminal: traz os turnos que o terminal teve depois do ultimo import, pelo timestamp de cada linha do
   * transcript. So enquanto o app nao conversou na sessao; depois disso o transcript tambem tem os turnos do app e
   * copiar duplicaria. Um processo ja retomado partiu do ponto antigo do transcript: para, e o proximo Retomar parte
   * do ponto atual.
   */
  async catchUp(events) {
    const since = this.events.findLastIndex((e) => e.kind === "imported");
    if (since < 0 || this.events.slice(since + 1).some((e) => e.kind === "user_text")) return;
    const last = this.events.slice(0, since).findLast((e) => e.at)?.at ?? "";
    const fresh = events.filter((e) => e.at && e.at > last);
    if (!fresh.length) return;
    if (this.query) {
      const consuming = this.consuming;
      this.stop();
      await consuming;
      // `stopped` nao oferece Retomar no app; para ele e a mesma sessao vinda do terminal, sem processo.
      this.setStatus("detached");
    }
    for (const event of fresh) this.emit(event);
    this.emit({ kind: "imported", dropped: 0 });
  }

  save() {
    this.store.persist(this.id, () => this.snapshot());
  }

  get secrets() {
    return this.token ? [this.token] : [];
  }

  /** Redige antes de guardar: o mesmo objeto vai para o snapshot e para o SSE. */
  emit(event) {
    const stored = redactDeep({ seq: this.events.length + 1, at: new Date().toISOString(), ...event }, this.secrets);
    this.events.push(stored);
    this.broadcast("event", stored);
    this.save();
    this.changed();
    return stored;
  }

  /** Deltas de streaming ficam fora do log: replay reconstroi so as mensagens finais. */
  broadcast(type, payload) {
    const frame = `event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`;
    for (const res of this.subscribers) res.write(frame);
  }

  setStatus(status) {
    if (this.status === status) return;
    this.status = status;
    this.broadcast("status", { status });
    this.changed();
  }

  summary() {
    return {
      id: this.id,
      project: this.project,
      org: this.org,
      githubAccount: this.githubAccount,
      provider: this.provider,
      account: this.account,
      cwd: this.cwd,
      additionalDirectories: this.additionalDirectories,
      command: this.command,
      skill: this.skill,
      title: this.title,
      status: this.status,
      createdAt: this.createdAt,
      cost: this.cost,
      model: this.model,
      permissionMode: this.permissionMode,
      asideOf: this.asideOf,
      events: this.events.length,
      pendingPermissions: this.pending.size,
      resumable: Boolean(this.sdkSessionId),
    };
  }

  canUseTool = (toolName, input, { signal, suggestions, toolUseID }) =>
    new Promise((resolve) => {
      const requestId = randomUUID();
      this.pending.set(requestId, { resolve, suggestions, input });
      this.emit({ kind: "permission", requestId, toolUseID, toolName, input });
      this.setStatus("waiting_permission");

      signal?.addEventListener("abort", () => {
        if (!this.pending.delete(requestId)) return;
        this.emit({ kind: "permission_resolved", requestId, decision: "aborted" });
        resolve({ behavior: "deny", message: "cancelado" });
      });
    });

  answerPermission(requestId, decision, answers) {
    const entry = this.pending.get(requestId);
    if (!entry) return false;
    this.pending.delete(requestId);

    if (decision === "answer") {
      // AskUserQuestion nao e um gate de permissao: a escolha do usuario volta como
      // `answers` no input, e o proprio tool devolve isso ao modelo.
      entry.resolve({ behavior: "allow", updatedInput: { ...entry.input, answers } });
    } else if (decision === "allow" || decision === "always") {
      entry.resolve({
        behavior: "allow",
        ...(decision === "always" && entry.suggestions ? { updatedPermissions: entry.suggestions } : {}),
      });
    } else {
      entry.resolve({ behavior: "deny", message: "negado pelo usuario no dashboard" });
    }

    this.emit({ kind: "permission_resolved", requestId, decision });
    if (this.pending.size === 0) this.setStatus("running");
    return true;
  }

  /**
   * [images] `{mediaType, data}` (base64, ja validados) ficam em disco para o app mostrar no historico. O Claude os
   * recebe como blocos de imagem; o `agy` so aceita texto no stream-json, entao recebe os caminhos e os abre com
   * `view_file`, uma leitura que o gate libera.
   */
  send(text, images = []) {
    const names = [];
    if (images.length) {
      const dir = path.join(this.attachmentsDir, this.id);
      mkdirSync(dir, { recursive: true });
      for (const image of images) {
        const name = `${randomUUID()}.${IMAGE_TYPES[image.mediaType]}`;
        writeFileSync(path.join(dir, name), Buffer.from(image.data, "base64"));
        names.push(name);
      }
    }
    let content = text;
    if (images.length && this.provider === "antigravity") {
      const paths = names.map((name) => `- ${path.join(this.attachmentsDir, this.id, name)}`);
      content = `${text}\n\nImagens anexadas pelo usuário (abra cada uma com view_file):\n${paths.join("\n")}`;
    } else if (images.length) {
      content = [
        { type: "text", text },
        ...images.map((image) => ({ type: "image", source: { type: "base64", media_type: image.mediaType, data: image.data } })),
      ];
    }
    this.input.push({
      type: "user",
      message: { role: "user", content },
      parent_tool_use_id: null,
      session_id: this.sdkSessionId ?? this.id,
    });
    this.skill = skillOf(text) ?? this.skill;
    this.emit({ kind: "user_text", text, ...(names.length ? { images: names } : {}) });
    this.setStatus("running");
  }

  handle(message) {
    switch (message.type) {
      case "system":
        if (message.subtype === "init") {
          this.sdkSessionId = message.session_id;
          this.model = message.model ?? this.model;
          this.save();
          this.emit({ kind: "init", model: message.model, tools: message.tools?.length ?? 0, cwd: message.cwd });
        }
        return;

      case "assistant":
        for (const block of message.message.content ?? []) {
          if (block.type === "text" && block.text.trim()) this.emit({ kind: "assistant_text", text: block.text });
          else if (block.type === "thinking" && block.thinking?.trim()) this.emit({ kind: "thinking", text: block.thinking });
          else if (block.type === "tool_use") this.emit({ kind: "tool_use", id: block.id, name: block.name, input: block.input });
        }
        return;

      case "user": {
        const content = message.message?.content;
        if (!Array.isArray(content)) return;
        for (const block of content) {
          if (block.type !== "tool_result") continue;
          const text = typeof block.content === "string"
            ? block.content
            : (block.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("\n");
          this.emit({ kind: "tool_result", id: block.tool_use_id, isError: Boolean(block.is_error), text });
        }
        return;
      }

      case "result":
        this.cost = message.total_cost_usd ?? this.cost;
        this.emit({
          kind: "result",
          isError: Boolean(message.is_error),
          text: message.subtype === "success" ? message.result : message.subtype,
          cost: this.cost,
          durationMs: message.duration_ms,
          numTurns: message.num_turns,
        });
        this.setStatus("idle");
        return;

      case "stream_event": {
        const event = message.event;
        if (event?.type !== "content_block_delta") return;
        if (event.delta?.type === "text_delta") {
          this.broadcast("delta", { kind: "text", text: redact(event.delta.text, this.secrets) });
        } else if (event.delta?.type === "thinking_delta") {
          this.broadcast("delta", { kind: "thinking", text: redact(event.delta.thinking, this.secrets) });
        }
        return;
      }

      default:
        return;
    }
  }

  /** Liga (ou religa) um processo a esta sessao. `resume` reaproveita o transcript no disco. */
  attach({ resume = false, token = null } = {}) {
    const forked = resume && Boolean(this.sdkSessionId) && this.liveElsewhere(this.sdkSessionId);
    // Antes do primeiro init a lateral ainda nao tem transcript proprio: parte de um fork do da sessao de origem.
    const asideStart = !resume && !this.sdkSessionId && this.forkFrom;
    this.input = createInputStream();
    this.abort = new AbortController();
    this.token = token;

    this.query = this.queryFn({
      prompt: this.input,
      options: {
        cwd: this.cwd,
        // As skills gravam este id no relatório (`stage-start --session`) para o app ligar etapa e sessão.
        env: { ...sessionEnv(process.env, token), CLAUDE_FLOW_SESSION_ID: this.id },
        ...(this.additionalDirectories.length ? { additionalDirectories: this.additionalDirectories } : {}),
        canUseTool: this.canUseTool,
        abortController: this.abort,
        includePartialMessages: true,
        permissionMode: this.permissionMode,
        // Sempre ligada: sem ela o CLI recusa trocar para bypass ao vivo. O modo efetivo vem so de `permissionMode`.
        allowDangerouslySkipPermissions: true,
        skills: "all",
        systemPrompt: { type: "preset", preset: "claude_code" },
        ...(resume && this.sdkSessionId ? { resume: this.sdkSessionId } : {}),
        ...(asideStart ? { resume: this.forkFrom } : {}),
        // Com o transcript aberto num terminal, dois processos gravariam nele: o app segue num ramo proprio.
        ...(forked || asideStart ? { forkSession: true } : {}),
        ...(this.requestedModel ? { model: this.requestedModel } : {}),
        ...(this.provider === "antigravity" ? { account: this.account } : {}),
      },
    });

    if (resume) {
      this.emit({ kind: "reattached", ...(forked ? { forked: true } : {}) });
      this.setStatus("idle");
    } else {
      this.send(this.command, this.initialImages);
      this.initialImages = [];
      this.setStatus("running");
    }

    this.consuming = this.consume();
  }

  async consume() {
    const { query, abort, input } = this;
    try {
      for await (const message of query) this.handle(message);
      this.setStatus("done");
    } catch (err) {
      if (!abort.signal.aborted) this.emit({ kind: "error", message: String(err?.message ?? err) });
      this.setStatus(abort.signal.aborted ? "stopped" : "error");
    } finally {
      input.close();
      // Sem zerar, `resume()` responde "attached" para um processo morto e o input seguinte
      // vai para uma fila que ninguem le. Um resume concorrente ja trocou os campos: preserva.
      if (this.query === query) {
        this.query = null;
        this.abort = null;
        this.consuming = null;
      }
      this.broadcast("closed", {});
      await this.store.flush(this.id, this.snapshot());
    }
  }

  /**
   * "attached" quando ja ha processo — chamar de novo nao religa nem emite `reattached`. Chamadas
   * concorrentes esperam a mesma `attaching`, entao o token e pedido uma vez e ha um so `attach`.
   * Conta que nao loga mais e 409 e a sessao fica como estava: nunca cai para a conta ativa.
   */
  resume() {
    if (this.query) return Promise.resolve("attached");
    if (!this.sdkSessionId) return Promise.resolve("not_resumable");
    if (this.attaching) return this.attaching;
    const attaching = (async () => {
      // Sem `githubAccount` o corpo seria sincrono e o `finally` rodaria antes da atribuicao,
      // deixando em `attaching` uma promise ja resolvida que nunca mais religa o processo.
      await null;
      try {
        let token = null;
        if (this.githubAccount) {
          token = await this.tokens.tokenFor(this.githubAccount).catch((err) => {
            throw new HttpError(409, err.message);
          });
        }
        this.attach({ resume: true, token });
        return "resumed";
      } finally {
        if (this.attaching === attaching) this.attaching = null;
      }
    })();
    this.attaching = attaching;
    return attaching;
  }

  /**
   * Cards pendentes seguem esperando: o modo novo vale da proxima chamada em diante. Recusa do SDK
   * e 409 sem gravar nem emitir. Sem processo, so grava e vale no proximo `attach`.
   */
  async setPermissionMode(mode) {
    if (this.query) {
      try {
        await this.query.setPermissionMode(mode);
      } catch (err) {
        throw new HttpError(409, String(err?.message ?? err));
      }
    }
    this.permissionMode = mode;
    this.emit({ kind: "permission_mode", mode });
  }

  /**
   * Vale da proxima chamada ao modelo em diante; recusa (no `agy`, troca no meio de um turno) e 409 sem gravar.
   * Sem processo, so grava e vale no proximo `attach`.
   */
  async setModel(model) {
    if (this.query) {
      try {
        await this.query.setModel(model);
      } catch (err) {
        throw new HttpError(409, String(err?.message ?? err));
      }
    }
    this.requestedModel = model;
    this.model = model;
    this.emit({ kind: "model", model });
  }

  async interrupt() {
    try {
      await this.query?.interrupt();
    } catch {
      this.abort?.abort();
    }
    this.setStatus("idle");
  }

  stop() {
    for (const [requestId, entry] of this.pending) {
      entry.resolve({ behavior: "deny", message: "sessao encerrada" });
      this.pending.delete(requestId);
    }
    this.changed();
    this.abort?.abort();
    this.input?.close();
  }
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms).unref());

const changeKey = (s) => JSON.stringify([s.status, s.pendingPermissions, s.cost, s.model, s.permissionMode, s.skill]);

export function createSessions({
  query,
  agyQuery,
  store,
  tokens,
  attachmentsDir,
  liveElsewhere = (sdkSessionId) => liveTerminalSessions(CLAUDE_HOME).has(sdkSessionId),
}) {
  const sessions = new Map();
  const listeners = new Set();
  const lastKeys = new Map();

  function publish(change) {
    for (const listener of listeners) listener(change);
  }

  /** So mudancas que a lista global mostra viram `summary`; eventos de log sao frequentes demais. */
  function changed(session) {
    if (sessions.get(session.id) !== session) return;
    const summary = session.summary();
    const key = changeKey(summary);
    if (lastKeys.get(session.id) === key) return;
    lastKeys.set(session.id, key);
    publish({ type: "summary", summary });
  }

  const deps = { query, agyQuery, store, changed, tokens, attachmentsDir, liveElsewhere };

  function flushAll() {
    return Promise.all([...sessions.values()].map((s) => store.flush(s.id, s.snapshot())));
  }

  return {
    /** Com `githubAccount`, o token vem antes da sessao existir: conta que nao loga e 400 sem sessao orfa. */
    async create(params) {
      const token = params.githubAccount ? await tokens.tokenFor(params.githubAccount) : null;
      const session = new Session(params, deps);
      sessions.set(session.id, session);
      session.attach({ token });
      return session;
    },

    get(id) {
      return sessions.get(id);
    },

    /** Transcripts que ja tem sessao aqui, para a lista do terminal nao repetir nem as do proprio engine. */
    sdkSessionIds() {
      return new Set([...sessions.values()].map((s) => s.sdkSessionId).filter(Boolean));
    },

    /**
     * Sessao do terminal trazida para o app: nasce `detached` com o historico do transcript e volta a viver pelo
     * `resume()` de sempre. Importar de novo o mesmo transcript devolve a sessao que ja existe.
     */
    async adopt(params, { sdkSessionId, createdAt, events, dropped }) {
      const existing = [...sessions.values()].find((s) => s.sdkSessionId === sdkSessionId);
      if (existing) {
        await existing.catchUp(events);
        return existing;
      }
      const note = { at: new Date().toISOString(), kind: "imported", dropped };
      const restored = {
        id: randomUUID(),
        createdAt: createdAt ?? new Date().toISOString(),
        sdkSessionId,
        cost: 0,
        events: [...events, note].map((e, i) => ({ seq: i + 1, ...e })),
      };
      const session = new Session({ ...params, restored }, deps);
      sessions.set(session.id, session);
      session.save();
      session.changed();
      return session;
    },

    /** `listener({type: "summary", summary} | {type: "removed", id})`; devolve o cancelamento. */
    onChange(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },

    list() {
      return [...sessions.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt)).map((s) => s.summary());
    },

    remove(id) {
      const session = sessions.get(id);
      if (!session) return false;
      sessions.delete(id);
      lastKeys.delete(id);
      publish({ type: "removed", id });
      // `remove` marca o id como encerrado, entao o `flush` que o `stop` provoca ja nasce inerte.
      store.remove(id);
      session.stop();
      rmSync(path.join(attachmentsDir, id), { recursive: true, force: true });
      return true;
    },

    async restore() {
      const snapshots = await store.loadAll();
      for (const snapshot of snapshots) {
        if (sessions.has(snapshot.id)) continue;
        const session = new Session(
          {
            project: snapshot.project,
            org: snapshot.org ?? null,
            githubAccount: typeof snapshot.githubAccount === "string" ? snapshot.githubAccount : null,
            provider: PROVIDERS.has(snapshot.provider) ? snapshot.provider : "anthropic",
            account: typeof snapshot.account === "string" ? snapshot.account : null,
            cwd: snapshot.cwd,
            additionalDirectories: snapshot.additionalDirectories ?? [],
            command: snapshot.command,
            model: typeof snapshot.requestedModel === "string" ? snapshot.requestedModel : undefined,
            permissionMode: PERMISSION_MODES.has(snapshot.permissionMode) ? snapshot.permissionMode : "default",
            forkFrom: snapshot.forkFrom ?? null,
            asideOf: snapshot.asideOf ?? null,
            restored: snapshot,
          },
          deps
        );
        sessions.set(session.id, session);
        lastKeys.set(session.id, changeKey(session.summary()));
      }
      return snapshots.length;
    },

    flushAll,

    /** O `finally` de cada `consume` grava o fim da sessao; esperar por ele evita perder o `result`. */
    async shutdown({ waitMs = 1500 } = {}) {
      const running = [];
      for (const session of sessions.values()) {
        const consuming = session.consuming;
        session.stop();
        if (consuming) running.push(consuming);
      }
      await Promise.race([Promise.allSettled(running), delay(waitMs)]);
      await flushAll();
    },
  };
}
