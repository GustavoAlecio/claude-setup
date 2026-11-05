import { randomUUID } from "node:crypto";

const TITLE_MAX = 60;

function titleFor(command) {
  const line = command.replace(/\s+/g, " ").trim();
  return line.length > TITLE_MAX ? `${line.slice(0, TITLE_MAX - 1).trimEnd()}…` : line;
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
  constructor({ project, org = null, cwd, additionalDirectories = [], command, model, restored }, { query, store, changed }) {
    this.queryFn = query;
    this.store = store;
    this.changed = () => changed(this);
    this.id = restored?.id ?? randomUUID();
    this.project = project;
    this.org = org;
    this.cwd = cwd;
    this.additionalDirectories = additionalDirectories;
    this.command = command;
    this.title = titleFor(command);
    this.requestedModel = model ?? null;
    this.createdAt = restored?.createdAt ?? new Date().toISOString();
    this.events = restored?.events ?? [];
    this.model = initModel(this.events) ?? this.requestedModel;
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
  }

  snapshot() {
    return {
      id: this.id,
      project: this.project,
      org: this.org,
      cwd: this.cwd,
      additionalDirectories: this.additionalDirectories,
      command: this.command,
      createdAt: this.createdAt,
      sdkSessionId: this.sdkSessionId,
      cost: this.cost,
      events: this.events,
    };
  }

  save() {
    this.store.persist(this.id, () => this.snapshot());
  }

  emit(event) {
    const stored = { seq: this.events.length + 1, at: new Date().toISOString(), ...event };
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
      cwd: this.cwd,
      additionalDirectories: this.additionalDirectories,
      command: this.command,
      title: this.title,
      status: this.status,
      createdAt: this.createdAt,
      cost: this.cost,
      model: this.model,
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

  send(text) {
    this.input.push({
      type: "user",
      message: { role: "user", content: text },
      parent_tool_use_id: null,
      session_id: this.sdkSessionId ?? this.id,
    });
    this.emit({ kind: "user_text", text });
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
        if (event.delta?.type === "text_delta") this.broadcast("delta", { kind: "text", text: event.delta.text });
        else if (event.delta?.type === "thinking_delta") this.broadcast("delta", { kind: "thinking", text: event.delta.thinking });
        return;
      }

      default:
        return;
    }
  }

  /** Liga (ou religa) um processo a esta sessao. `resume` reaproveita o transcript no disco. */
  attach({ resume = false } = {}) {
    this.input = createInputStream();
    this.abort = new AbortController();

    this.query = this.queryFn({
      prompt: this.input,
      options: {
        cwd: this.cwd,
        ...(this.additionalDirectories.length ? { additionalDirectories: this.additionalDirectories } : {}),
        canUseTool: this.canUseTool,
        abortController: this.abort,
        includePartialMessages: true,
        permissionMode: "default",
        skills: "all",
        systemPrompt: { type: "preset", preset: "claude_code" },
        ...(resume && this.sdkSessionId ? { resume: this.sdkSessionId } : {}),
        ...(this.requestedModel ? { model: this.requestedModel } : {}),
      },
    });

    if (resume) {
      this.emit({ kind: "reattached" });
      this.setStatus("idle");
    } else {
      this.send(this.command);
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

  /** "attached" quando ja ha processo — chamar de novo nao religa nem emite `reattached`. */
  resume() {
    if (this.query) return "attached";
    if (!this.sdkSessionId) return "not_resumable";
    this.attach({ resume: true });
    return "resumed";
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

const changeKey = (s) => JSON.stringify([s.status, s.pendingPermissions, s.cost, s.model]);

export function createSessions({ query, store }) {
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

  const deps = { query, store, changed };

  function flushAll() {
    return Promise.all([...sessions.values()].map((s) => store.flush(s.id, s.snapshot())));
  }

  return {
    create(params) {
      const session = new Session(params, deps);
      sessions.set(session.id, session);
      session.attach();
      return session;
    },

    get(id) {
      return sessions.get(id);
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
            cwd: snapshot.cwd,
            additionalDirectories: snapshot.additionalDirectories ?? [],
            command: snapshot.command,
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
