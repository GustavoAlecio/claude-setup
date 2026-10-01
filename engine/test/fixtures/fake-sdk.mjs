import { randomUUID } from "node:crypto";

/**
 * Substituto de `query` do Agent SDK, roteirizado pelo texto de cada mensagem do usuario:
 * - `perm:Edit`: pede permissao de Edit e reporta o resultado da decisao;
 * - `perm2`: duas chamadas de Bash em paralelo, cada uma com seu pedido de permissao;
 * - `ask2`: AskUserQuestion com duas perguntas (a segunda multiSelect);
 * - `slow`: um delta a cada 100 ms ate `interrupt()` ou abort;
 * - `leak`: ecoa `options.env.GH_TOKEN` em tool_use, tool_result, delta, texto e result;
 * - qualquer outro: 3 deltas, texto final e result.
 * Abort rejeita como o SDK real; `interrupt()` encerra o turno corrente com um result.
 * O modo vem de `options.permissionMode` e muda com `setPermissionMode` (registrado em
 * `permissionModeCalls`); em `bypassPermissions` so o AskUserQuestion chama `canUseTool`.
 */
export function query({ prompt, options }) {
  const signal = options.abortController?.signal;
  const sessionId = options.resume ?? `fake-${randomUUID()}`;
  let interrupted = false;
  let wakeInterrupt = null;
  let mode = options.permissionMode ?? "default";
  const permissionModeCalls = [];

  const decide = (name, input, id) =>
    mode === "bypassPermissions" && name !== "AskUserQuestion"
      ? Promise.resolve({ behavior: "allow" })
      : options.canUseTool(name, input, { signal, suggestions: [], toolUseID: id });

  const abortError = () => Object.assign(new Error("aborted by user"), { name: "AbortError" });

  function guard(promise) {
    return new Promise((resolve, reject) => {
      if (signal?.aborted) return reject(abortError());
      const onAbort = () => reject(abortError());
      signal?.addEventListener("abort", onAbort, { once: true });
      promise.then(
        (value) => {
          signal?.removeEventListener("abort", onAbort);
          resolve(value);
        },
        (err) => {
          signal?.removeEventListener("abort", onAbort);
          reject(err);
        }
      );
    });
  }

  const pause = (ms) =>
    guard(
      new Promise((resolve) => {
        const timer = setTimeout(resolve, ms);
        wakeInterrupt = () => {
          clearTimeout(timer);
          resolve();
        };
      })
    );

  const delta = (text) => ({ type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text } } });
  const assistant = (content) => ({ type: "assistant", message: { content } });
  const toolResult = (id, text, isError = false) => ({
    type: "user",
    message: { content: [{ type: "tool_result", tool_use_id: id, content: text, is_error: isError }] },
  });
  const result = (text, extra = {}) => ({
    type: "result",
    subtype: "success",
    result: text,
    is_error: false,
    total_cost_usd: 0.01,
    duration_ms: 5,
    num_turns: 1,
    ...extra,
  });

  async function* askTool(name, input) {
    const id = `tool-${randomUUID()}`;
    yield assistant([{ type: "tool_use", id, name, input }]);
    const decision = await guard(decide(name, input, id));
    if (decision.behavior === "allow") {
      const answers = decision.updatedInput?.answers;
      yield toolResult(id, answers ? JSON.stringify(answers) : "ok");
      yield result(answers ? `respostas: ${JSON.stringify(answers)}` : `${name} aplicado`);
    } else {
      yield toolResult(id, decision.message ?? "negado", true);
      yield result(`${name} negado`);
    }
  }

  async function* turn(text) {
    if (text === "perm:Edit") {
      yield* askTool("Edit", { file_path: "/tmp/fake.txt", old_string: "a\nb", new_string: "a\nc" });
      return;
    }
    if (text === "perm2") {
      const calls = ["a", "b"].map((tag) => ({ id: `tool-${randomUUID()}`, input: { command: `echo ${tag}` } }));
      yield assistant(calls.map(({ id, input }) => ({ type: "tool_use", id, name: "Bash", input })));
      const decisions = await guard(Promise.all(calls.map(({ id, input }) => decide("Bash", input, id))));
      for (const [i, { id }] of calls.entries()) {
        const allowed = decisions[i].behavior === "allow";
        yield toolResult(id, allowed ? "ok" : decisions[i].message ?? "negado", !allowed);
      }
      yield result("perm2 resolvido");
      return;
    }
    if (text === "ask2") {
      yield* askTool("AskUserQuestion", {
        questions: [
          { question: "Qual banco?", header: "Banco", multiSelect: false, options: [{ label: "Postgres" }, { label: "SQLite" }] },
          { question: "Quais alvos?", header: "Alvos", multiSelect: true, options: [{ label: "macOS" }, { label: "iOS" }] },
        ],
      });
      return;
    }
    if (text === "leak") {
      const token = options.env?.GH_TOKEN ?? "";
      const id = `tool-${randomUUID()}`;
      yield assistant([{ type: "tool_use", id, name: "Bash", input: { command: `echo ${token}` } }]);
      yield toolResult(id, `token=${token}`);
      yield delta(token);
      yield assistant([{ type: "text", text: `vi ${token}` }]);
      yield result(`fim ${token}`);
      return;
    }
    if (text === "slow") {
      while (!interrupted) {
        yield delta(".");
        await pause(100);
      }
      yield result("interrompido", { subtype: "error_during_execution", is_error: false });
      return;
    }
    for (const part of ["ol", "a ", "mundo"]) yield delta(part);
    yield assistant([{ type: "text", text: "ola mundo" }]);
    yield result("ola mundo");
  }

  async function* run() {
    const messages = prompt[Symbol.asyncIterator]();
    let initialized = false;
    while (true) {
      const next = await guard(messages.next());
      if (next.done) return;
      if (!initialized) {
        initialized = true;
        yield { type: "system", subtype: "init", session_id: sessionId, model: options.model ?? "fake-model", tools: [], cwd: options.cwd };
      }
      interrupted = false;
      yield* turn(next.value.message.content);
    }
  }

  const iterator = run();
  return {
    [Symbol.asyncIterator]: () => iterator,
    next: (...args) => iterator.next(...args),
    async interrupt() {
      interrupted = true;
      wakeInterrupt?.();
    },
    permissionModeCalls,
    async setPermissionMode(next) {
      permissionModeCalls.push(next);
      if (next === "bypassPermissions" && options.allowDangerouslySkipPermissions !== true) {
        throw new Error("bypass_disabled");
      }
      mode = next;
    },
  };
}

/** Espiao de `options`: registra o que cada `query` recebeu e delega ao fake; `queries` guarda os retornos. */
export function spyQuery() {
  const calls = [];
  const queries = [];
  return {
    calls,
    queries,
    query(args) {
      calls.push(args.options);
      const q = query(args);
      queries.push(q);
      return q;
    },
  };
}
