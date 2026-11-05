import { promises as fs } from "node:fs";
import path from "node:path";

export function createStore(dir, { log = () => {} } = {}) {
  const pending = new Map();
  const queues = new Map();
  // Encerrar uma sessao tem que ser terminal, e ha escritas em voo quando isso acontece:
  // o debounce de `persist` e o `flush` do fim do processo. Sem este registro, o `flush`
  // disparado pelo proprio encerramento recria o arquivo recem-removido e a sessao
  // ressuscita como `detached` no boot seguinte.
  const closed = new Set();
  let tmpSeq = 0;

  const fileFor = (id) => path.join(dir, `${id}.json`);

  async function write(id, snapshot) {
    if (closed.has(id)) return;
    await fs.mkdir(dir, { recursive: true });
    const file = fileFor(id);
    // Tmp unico por escrita: com um nome fixo, o rename de uma escrita pode publicar o
    // arquivo pela metade de outra (debounce vs flush, ou outro processo no mesmo dir).
    const tmp = `${file}.${process.pid}.${++tmpSeq}.tmp`;
    try {
      await fs.writeFile(tmp, JSON.stringify(snapshot));
      if (closed.has(id)) return;
      await fs.rename(tmp, file);
    } finally {
      await fs.rm(tmp, { force: true });
    }
  }

  function enqueue(id, getSnapshot) {
    const next = (queues.get(id) ?? Promise.resolve())
      .then(() => write(id, getSnapshot()))
      .catch((err) => log("falha ao gravar sessao", id, err));
    queues.set(id, next);
    next.then(() => {
      if (queues.get(id) === next) queues.delete(id);
    });
    return next;
  }

  function cancelTimer(id) {
    const timer = pending.get(id);
    if (!timer) return;
    clearTimeout(timer);
    pending.delete(id);
  }

  return {
    /** Grava no maximo uma vez por janela: uma sessao ativa emite dezenas de eventos por segundo. */
    persist(id, getSnapshot, delay = 400) {
      if (closed.has(id) || pending.has(id)) return;
      pending.set(
        id,
        setTimeout(() => {
          pending.delete(id);
          enqueue(id, getSnapshot);
        }, delay)
      );
    },

    flush(id, snapshot) {
      cancelTimer(id);
      if (closed.has(id)) return Promise.resolve();
      return enqueue(id, () => snapshot);
    },

    async loadAll() {
      let files;
      try {
        files = await fs.readdir(dir);
      } catch {
        return [];
      }
      const snapshots = await Promise.all(
        files
          .filter((f) => f.endsWith(".json"))
          .map(async (f) => {
            try {
              return JSON.parse(await fs.readFile(path.join(dir, f), "utf8"));
            } catch {
              return null;
            }
          })
      );
      return snapshots.filter((s) => s && typeof s.id === "string");
    },

    async remove(id) {
      closed.add(id);
      cancelTimer(id);
      await queues.get(id);
      await fs.rm(fileFor(id), { force: true });
      const prefix = `${id}.json.`;
      const leftovers = (await fs.readdir(dir).catch(() => [])).filter((f) => f.startsWith(prefix) && f.endsWith(".tmp"));
      await Promise.all(leftovers.map((f) => fs.rm(path.join(dir, f), { force: true })));
    },
  };
}
