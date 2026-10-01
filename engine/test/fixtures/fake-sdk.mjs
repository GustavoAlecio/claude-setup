import { randomUUID } from "node:crypto";

/**
 * Substituto de `query` do Agent SDK, roteirizado pelo texto de cada mensagem do usuario:
 * - `perm:Edit`: pede permissao de Edit e reporta o resultado da decisao;
 * - `ask2`: AskUserQuestion com duas perguntas (a segunda multiSelect);
 * - `slow`: um delta a cada 100 ms ate `interrupt()` ou abort;
 * - qualquer outro: 3 deltas, texto final e result.
 * Abort rejeita como o SDK real; `interrupt()` encerra o turno corrente com um result.
 */
export function query({ prompt, options }) {
  const signal = options.abortController?.signal;
  const sessionId = options.resume ?? `fake-${randomUUID()}`;
  let interrupted = false;
  let wakeInterrupt = null;

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
    const decision = await guard(options.canUseTool(name, input, { signal, suggestions: [], toolUseID: id }));
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
    if (text === "ask2") {
      yield* askTool("AskUserQuestion", {
        questions: [
          { question: "Qual banco?", header: "Banco", multiSelect: false, options: [{ label: "Postgres" }, { label: "SQLite" }] },
          { question: "Quais alvos?", header: "Alvos", multiSelect: true, options: [{ label: "macOS" }, { label: "iOS" }] },
        ],
      });
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
  };
}
