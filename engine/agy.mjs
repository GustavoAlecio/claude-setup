import { spawn as nodeSpawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import readline from "node:readline";
import { DEFAULT_ACCOUNT, agyBin } from "./accounts.mjs";
import { HttpError } from "./data.mjs";

// Passam em qualquer modo, como as leituras do Claude Code. `ask_question` nunca: vira pergunta no app.
const READ_TOOLS = new Set([
  "view_file", "list_dir", "grep_search", "find_by_name", "read_url_content", "search_web", "command_status",
  "read_resource", "list_resources", "list_permissions", "list_plugin_accounts", "list_browser_pages",
  "read_browser_page", "capture_browser_console_logs", "capture_browser_screenshot", "browser_get_dom",
  "browser_get_network_request", "browser_list_network_requests", "manage_task", "finish", "wait", "wait_5_seconds",
]);
const EDIT_TOOLS = new Set(["write_to_file", "replace_file_content", "multi_replace_file_content", "sed_file", "notebook_edit"]);
const EDIT_MODES = new Set(["acceptEdits", "auto"]);
const STDERR_TAIL = 4096;

/** Nome e input como o app já sabe mostrar (card de Bash/Write); o resto segue com o nome do `agy`. */
export function present(name, args = {}) {
  switch (name) {
    case "run_command":
      return { name: "Bash", input: { command: args.CommandLine ?? "", description: args.toolSummary ?? "" } };
    case "write_to_file":
      return { name: "Write", input: { file_path: args.TargetFile ?? "", content: args.CodeContent ?? "" } };
    default: {
      const file = args.TargetFile ?? args.AbsolutePath ?? args.DirectoryPath;
      return { name, input: typeof file === "string" ? { file_path: file, ...args } : args };
    }
  }
}

/** Motivo curto de uma saida do `agy`: o `short_error` do AGY_ERROR (cota, rede), senao a ultima linha de erro. */
export function exitReason(stderr, code, signal) {
  const agyError = /AGY_ERROR: (\{.*\})/.exec(stderr)?.[1];
  if (agyError) {
    try {
      const { short_error: short } = JSON.parse(agyError);
      if (short) return short;
    } catch {}
  }
  const lines = stderr.trim().split("\n").filter((l) => l.trim());
  return lines.findLast((l) => /error/i.test(l))?.trim() ?? `agy saiu (${signal ?? code})`;
}

function userText(message) {
  const content = message?.message?.content;
  if (typeof content === "string") return content;
  return (content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("\n");
}

/** Fila assíncrona de mensagens no formato do SDK; `end(err)` faz o `for await` lançar. */
function createChannel() {
  const queue = [];
  let wake = null;
  let done = false;
  let error = null;
  return {
    push(message) {
      if (done) return;
      queue.push(message);
      wake?.();
      wake = null;
    },
    end(err = null) {
      if (done) return;
      done = true;
      error = err;
      wake?.();
      wake = null;
    },
    async *[Symbol.asyncIterator]() {
      while (true) {
        if (queue.length) {
          yield queue.shift();
          continue;
        }
        if (done) {
          if (error) throw error;
          return;
        }
        await new Promise((resolve) => {
          wake = resolve;
        });
      }
    },
  };
}

/**
 * Uma sessão Antigravity com a interface do `query()` do SDK. O `agy` roda sempre em bypass: quem decide
 * é o hook do HOME sombra, que chega a [decide] pelo engine. `interrupt` mata o processo, e a próxima
 * mensagem o religa com `--conversation`.
 */
class AgyRun {
  constructor({ prompt, options }, deps) {
    this.prompt = prompt;
    this.options = options;
    this.deps = deps;
    this.mode = options.permissionMode ?? "default";
    this.conversation = options.resume ?? null;
    this.sessionId = options.env?.CLAUDE_FLOW_SESSION_ID ?? randomUUID();
    this.secret = randomUUID();
    this.out = createChannel();
    this.proc = null;
    this.spawning = null;
    // Processos encerrados de proposito (interrupt, troca de modelo): a saida deles nao encerra a sessao.
    this.retired = new Set();
    this.busy = false;
    this.promptDone = false;
    this.closed = false;
    this.finished = false;
    this.texts = new Map();
    this.openTools = new Set();
    this.stderr = "";
    // `result` do agy traz totais da conversa (duracao, turnos): o turno e a diferenca para o anterior.
    this.totals = null;

    deps.runs.set(this.sessionId, this);
    options.abortController?.signal.addEventListener("abort", () => this.close());
    this.pump().catch((err) => this.finish(err));
  }

  [Symbol.asyncIterator]() {
    return this.out[Symbol.asyncIterator]();
  }

  async pump() {
    for await (const message of this.prompt) {
      if (this.closed) return;
      const proc = await this.ensureProcess();
      this.busy = true;
      proc.stdin.write(`${JSON.stringify({ event: "user", message: { content: userText(message) } })}\n`);
    }
    this.promptDone = true;
    if (this.proc) this.proc.stdin.end();
    else this.finish();
  }

  ensureProcess() {
    if (this.proc) return Promise.resolve(this.proc);
    this.spawning ??= this.spawnProcess().finally(() => {
      this.spawning = null;
    });
    return this.spawning;
  }

  async spawnProcess() {
    const { options, deps } = this;
    const home = await deps.accounts.prepare(options.account ?? DEFAULT_ACCOUNT);
    const args = ["--input-format", "stream-json", "--output-format", "stream-json", "--dangerously-skip-permissions"];
    if (options.model) args.push("--model", options.model);
    if (this.conversation) args.push("--conversation", this.conversation);
    for (const dir of options.additionalDirectories ?? []) args.push("--add-dir", dir);

    const proc = deps.spawn(deps.bin, args, {
      cwd: options.cwd,
      env: {
        ...options.env,
        HOME: home,
        CLAUDE_FLOW_SESSION_ID: this.sessionId,
        CLAUDE_FLOW_GATE_URL: deps.gateUrl(),
        CLAUDE_FLOW_GATE_SECRET: this.secret,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.proc = proc;
    proc.stdin.on("error", () => {});
    proc.stderr.on("data", (chunk) => {
      this.stderr = (this.stderr + chunk.toString("utf8")).slice(-STDERR_TAIL);
    });
    readline.createInterface({ input: proc.stdout }).on("line", (line) => this.onLine(line));
    proc.on("error", (err) => this.finish(err));
    proc.on("exit", (code, signal) => this.onExit(proc, code, signal));
    return proc;
  }

  onExit(proc, code, signal) {
    if (this.retired.delete(proc)) return;
    if (this.proc === proc) this.proc = null;
    if (this.closed || this.promptDone) return this.finish();
    // So o turno morreu (cota, rede, crash): a sessao segue, e a proxima mensagem religa na mesma conversa,
    // inclusive com outro modelo.
    this.busy = false;
    this.out.push({
      type: "result",
      subtype: `error: ${exitReason(this.stderr, code, signal)}`,
      is_error: true,
      result: "",
      total_cost_usd: 0,
      duration_ms: 0,
      num_turns: 0,
    });
    this.stderr = "";
  }

  onLine(line) {
    let ev;
    try {
      ev = JSON.parse(line);
    } catch {
      return;
    }
    switch (ev.event) {
      case "init":
        this.conversation = ev.conversation_id ?? this.conversation;
        this.out.push({
          type: "system",
          subtype: "init",
          session_id: ev.conversation_id,
          model: ev.init?.model,
          tools: ev.init?.tools ?? [],
          cwd: ev.init?.cwd,
        });
        return;
      case "step_update":
        this.onStep(ev.step_update ?? {});
        return;
      case "result": {
        this.busy = false;
        const r = ev.result ?? {};
        const totals = { duration: r.duration_seconds ?? 0, turns: r.num_turns ?? 0 };
        // O agy as vezes repete o mesmo result: totais iguais aos do ultimo sao o mesmo turno.
        if (this.totals && totals.duration === this.totals.duration && totals.turns === this.totals.turns) return;
        const before = this.totals ?? { duration: 0, turns: 0 };
        this.totals = totals;
        // O status e da conversa e fica em ERROR depois de qualquer falha (cota, tool): um turno com resposta deu certo.
        const ok = r.status === "SUCCESS" || Boolean(r.response?.trim());
        this.out.push({
          type: "result",
          subtype: ok ? "success" : `error: ${r.error?.message ?? r.status ?? "desconhecido"}`,
          is_error: !ok,
          result: r.response ?? "",
          total_cost_usd: 0,
          duration_ms: Math.round(Math.max(0, totals.duration - before.duration) * 1000),
          num_turns: Math.max(0, totals.turns - before.turns),
        });
        return;
      }
      default:
        return;
    }
  }

  onStep(step) {
    const id = `${step.conversation_id}:${step.step_index}`;
    if (step.step_type === "tool") {
      if (!this.openTools.has(id)) {
        this.openTools.add(id);
        const { name, input } = present(step.tool_name, step.tool_info?.parameters);
        this.out.push({ type: "assistant", message: { content: [{ type: "tool_use", id, name, input }] } });
      }
      if (step.state === "DONE" || step.state === "ERROR") {
        this.openTools.delete(id);
        const text = step.tool_info?.error?.message ?? step.tool_info?.output ?? "";
        this.out.push({
          type: "user",
          message: { content: [{ type: "tool_result", tool_use_id: id, is_error: step.state === "ERROR", content: text }] },
        });
      }
      return;
    }
    if (step.step_type !== "agent_response") return;
    if (step.text_delta) {
      this.texts.set(id, (this.texts.get(id) ?? "") + step.text_delta);
      this.out.push({ type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: step.text_delta } } });
    }
    if (step.state === "DONE") {
      const text = this.texts.get(id);
      this.texts.delete(id);
      if (text?.trim()) this.out.push({ type: "assistant", message: { content: [{ type: "text", text }] } });
    }
  }

  /** O modo vale aqui, não no `agy`: leitura sempre passa, edição conforme o modo, o resto pergunta (`plan` recusa). */
  async decide(call, signal) {
    const name = call?.toolCall?.name;
    const args = call?.toolCall?.args ?? {};
    const toolUseID = `${call?.conversationId}:${call?.stepIdx}`;
    if (name === "ask_question") return this.ask(args, signal, toolUseID);
    if (READ_TOOLS.has(name) || this.mode === "bypassPermissions" || (EDIT_MODES.has(this.mode) && EDIT_TOOLS.has(name))) {
      return { decision: "allow" };
    }
    if (this.mode === "plan") return { decision: "deny", reason: "modo só leitura: nada que edite ou rode comandos" };
    const shown = present(name, args);
    const result = await this.options.canUseTool(shown.name, shown.input, { signal, toolUseID });
    return result.behavior === "allow"
      ? { decision: "allow" }
      : { decision: "deny", reason: result.message ?? "negado pelo usuario no dashboard" };
  }

  /** A pergunta vira `AskUserQuestion`; a resposta volta ao modelo como motivo do `deny`. */
  async ask(args, signal, toolUseID) {
    const questions = (args.questions ?? []).map((q) => ({
      question: String(q.question ?? ""),
      header: "",
      multiSelect: Boolean(q.is_multi_select),
      options: (q.options ?? []).map((label) => ({ label: String(label), description: "" })),
    }));
    const result = await this.options.canUseTool("AskUserQuestion", { questions }, { signal, toolUseID });
    if (result.behavior !== "allow") return { decision: "deny", reason: "The user dismissed the question without answering." };
    const answers = result.updatedInput?.answers ?? {};
    const lines = questions.map((q) => `- ${q.question}: ${answers[q.question] ?? "(no answer)"}`);
    return {
      decision: "deny",
      reason: `The question was shown to the user in another interface and they already answered:\n${lines.join("\n")}\nProceed using these answers.`,
    };
  }

  /** Solta o processo antes de ele sair: uma mensagem que chegue antes do `exit` ja abre outro. */
  retire() {
    const proc = this.proc;
    if (!proc) return;
    this.proc = null;
    this.busy = false;
    this.retired.add(proc);
    proc.kill("SIGINT");
  }

  async interrupt() {
    this.retire();
  }

  /** O modelo e argumento do processo: encerra o atual, e a proxima mensagem religa com `--model` e `--conversation`. */
  async setModel(model) {
    if (this.busy) throw new Error("aguarde o turno terminar para trocar o modelo");
    this.options = { ...this.options, model };
    this.retire();
  }

  async setPermissionMode(mode) {
    this.mode = mode;
  }

  close() {
    this.closed = true;
    if (this.proc) this.proc.kill("SIGTERM");
    else this.finish();
  }

  finish(err = null) {
    if (this.finished) return;
    this.finished = true;
    this.closed = true;
    if (this.deps.runs.get(this.sessionId) === this) this.deps.runs.delete(this.sessionId);
    this.proc?.kill("SIGTERM");
    this.out.end(err);
  }
}

export function createAgy({ accounts, gateUrl, bin = agyBin(), spawn = nodeSpawn }) {
  const runs = new Map();
  const deps = { accounts, gateUrl, bin, spawn, runs };

  return {
    query: (params) => new AgyRun(params, deps),

    /** Chamado pela rota do hook; segredo errado ou sessão sem processo é 403, e o hook nega. */
    decide({ session, secret, call }, signal) {
      const run = runs.get(session);
      if (!run || run.secret !== secret) throw new HttpError(403, "gate desconhecido");
      return run.decide(call, signal);
    },
  };
}
