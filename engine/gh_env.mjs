import { HttpError } from "./data.mjs";

const TOKEN_TTL_MS = 5 * 60_000;

export const LOGIN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/;
export const INVALID_PARAM = "parâmetro inválido";

const INHERITED_CREDENTIALS = ["GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"];
const TOKEN_SHAPE = /gh[opsu]_[A-Za-z0-9_]{20,}/g;

export const notLoggedIn = (login) => `conta ${login} não está logada no gh (gh auth login)`;

/** `undefined`/`null` viram `null`; qualquer outra coisa tem que ser um login do GitHub antes de virar argumento. */
export function loginParam(value) {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || !LOGIN.test(value)) throw new HttpError(400, INVALID_PARAM);
  return value;
}

/** Owners em minúsculas, sem duplicatas e ordenados: a mesma forma vira argumento e chave de cache. */
export function ownersParam(value) {
  if (value === undefined) return [];
  const list = Array.isArray(value) ? value : [value];
  return [...new Set(list.map((owner) => loginParam(owner ?? "").toLowerCase()))].sort();
}

/** Ambiente de todo `gh` do engine: nada herdado decide a conta; com `token`, é ele quem decide. */
export function ghEnv(base, token) {
  const env = { ...base };
  for (const key of INHERITED_CREDENTIALS) delete env[key];
  env.GH_PROMPT_DISABLED = "1";
  if (token) env.GH_TOKEN = token;
  return env;
}

/** O git da sessão herda chave SSH e helper do usuário; só não pode travar pedindo senha. */
export function sessionEnv(base, token) {
  return { ...ghEnv(base, token), GIT_TERMINAL_PROMPT: "0" };
}

export function redact(text, tokens = []) {
  let out = String(text);
  for (const token of tokens) if (token) out = out.split(token).join("***");
  return out.replace(TOKEN_SHAPE, "***");
}

export function redactDeep(value, tokens = []) {
  if (typeof value === "string") return redact(value, tokens);
  if (Array.isArray(value)) return value.map((item) => redactDeep(item, tokens));
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, redactDeep(item, tokens)]));
  }
  return value;
}

/**
 * Token por conta via `gh auth token --user`, em memória por 5 min e com a promise compartilhada.
 * Falha nunca fica em cache nem expõe o erro cru: vira a mensagem fixa de conta não logada.
 */
export function createTokens({ gh, now = Date.now, env = () => process.env }) {
  const entries = new Map();
  const seen = new Set();

  function tokenFor(login) {
    if (typeof login !== "string" || !LOGIN.test(login)) return Promise.reject(new HttpError(400, INVALID_PARAM));
    const hit = entries.get(login);
    if (hit && now() - hit.at < TOKEN_TTL_MS) return hit.value;
    const entry = { at: now() };
    entry.value = gh(["auth", "token", "--hostname", "github.com", "--user", login], { env: ghEnv(env()) })
      .then(({ stdout }) => {
        const token = String(stdout ?? "").trim();
        if (!token) throw new Error("token vazio");
        seen.add(token);
        return token;
      })
      .catch(() => {
        if (entries.get(login) === entry) entries.delete(login);
        throw new HttpError(400, notLoggedIn(login));
      });
    entries.set(login, entry);
    return entry.value;
  }

  return {
    tokenFor,
    invalidate(login) {
      entries.delete(login);
    },
    /** Todo token já obtido, inclusive os expirados: um texto antigo ainda pode carregá-lo. */
    known: () => [...seen],
  };
}
