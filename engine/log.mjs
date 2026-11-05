import { format } from "node:util";

/**
 * Com o pai morto, stdout/stderr viram pipes sem leitor: cada escrita gera EPIPE, e um
 * `error` sem listener derruba o processo antes do flush das sessoes.
 */
export function guardStream(stream) {
  const state = { dead: false };
  const markDead = () => {
    state.dead = true;
  };
  stream.on("error", markDead);
  stream.on("close", markDead);
  stream.on("finish", markDead);
  return {
    write(text) {
      if (state.dead || stream.destroyed || !stream.writable) return false;
      try {
        return stream.write(text);
      } catch {
        state.dead = true;
        return false;
      }
    },
  };
}

export function createLog(stream = process.stderr) {
  const out = guardStream(stream);
  return (...args) => {
    out.write(`[${new Date().toISOString()}] ${format(...args)}\n`);
  };
}

export function installCrashGuards(log) {
  process.on("uncaughtException", (err) => log("uncaughtException", err));
  process.on("unhandledRejection", (err) => log("unhandledRejection", err));
}
