import { createHash } from "node:crypto";
import { existsSync, promises as fs } from "node:fs";
import path from "node:path";
import { HttpError } from "./data.mjs";

const IDLE_CLOSE_MS = 5 * 60_000;
const RENDER_TIMEOUT_MS = 30_000;
export const MAX_DIAGRAM_CHARS = 50_000;
// Muda quando a paleta ou a escala mudam: a chave do cache inclui o visual, nao so o texto.
const STYLE = "app-2x-v3";

/**
 * Paletas do app (`app_colors.dart`); [bg] e o `elevated` do bloco de codigo, onde o PNG aparece. O tema `dark` do
 * mermaid pinta faixas de secao claras sob texto claro.
 */
const PALETTES = {
  dark: { bg: "#1D2027", raised: "#262A33", alt: "#21242C", line: "#3A3F4B", text: "#E8EAF0", soft: "#A3A9B7", accent: "#D97757" },
  light: { bg: "#FFFFFF", raised: "#F1F2F5", alt: "#F7F7F9", line: "#C9CBD3", text: "#16181D", soft: "#4B5160", accent: "#C2603F" },
};

export const THEMES = new Set(Object.keys(PALETTES));

function mermaidConfig(theme) {
  const p = PALETTES[theme];
  return {
    theme: "base",
    themeVariables: {
      darkMode: theme === "dark",
      background: p.bg,
      fontFamily: "-apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif",
      primaryColor: p.raised,
      primaryTextColor: p.text,
      primaryBorderColor: p.accent,
      secondaryColor: p.alt,
      tertiaryColor: p.bg,
      lineColor: p.soft,
      textColor: p.text,
      titleColor: p.text,
      noteBkgColor: p.raised,
      noteTextColor: p.text,
      sectionBkgColor: p.raised,
      altSectionBkgColor: p.alt,
      sectionBkgColor2: p.raised,
      taskBkgColor: p.line,
      taskBorderColor: p.accent,
      taskTextColor: p.text,
      taskTextLightColor: p.text,
      taskTextDarkColor: p.text,
      taskTextOutsideColor: p.text,
      activeTaskBkgColor: p.accent,
      doneTaskBkgColor: p.alt,
      gridColor: p.line,
      todayLineColor: p.accent,
      edgeLabelBackground: p.bg,
      clusterBkg: p.alt,
      clusterBorder: p.line,
    },
    // O gantt ignora parte das variaveis: faixas, grade e rotulos fora da barra vem do CSS dele.
    themeCSS: [
      `.section0, .section2 { fill: ${p.raised}; opacity: 1; }`,
      `.section1, .section3 { fill: ${p.alt}; opacity: 1; }`,
      `.grid .tick line { stroke: ${p.line}; }`,
      `.grid .tick text, .sectionTitle { fill: ${p.soft}; }`,
      `.titleText { fill: ${p.text}; }`,
      `.taskTextOutsideRight, .taskTextOutsideLeft { fill: ${p.text}; }`,
      `.edgeLabel, .edgeLabel p, .labelBkg { background-color: ${p.bg}; }`,
    ].join("\n"),
  };
}

/**
 * Erros comuns de LLM que o mermaid recusa, reescritos so depois de o texto original falhar:
 * `subgraph Fase 1: Spec (Dev)` sem id vira `subgraph sg1["Fase 1: Spec (Dev)"]`.
 */
export function repairMermaid(code) {
  let n = 0;
  return code.replace(
    /^(\s*)subgraph\s+(?![A-Za-z0-9_-]+\s*(?:\[|$))(.+?)\s*$/gm,
    (_, indent, title) => `${indent}subgraph sg${++n}["${title.replaceAll('"', "'")}"]`
  );
}

const CHROMES = [
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
];

/** Chrome ja instalado: o puppeteer do mermaid-cli foi instalado sem baixar o Chromium dele. */
export function findChrome(env = process.env) {
  if (env.CHROME_PATH) return env.CHROME_PATH;
  return CHROMES.find((p) => existsSync(p)) ?? null;
}

function withTimeout(promise, ms, what) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what}: timeout`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/**
 * Diagramas mermaid em PNG para o app, que nao tem renderer proprio (ADR 0015). Um Chrome headless e reaproveitado
 * entre renders e fecha depois de [IDLE_CLOSE_MS] parado; o PNG fica em [cacheDir] pela hash do texto e do estilo.
 * [render] e injetavel nos testes.
 */
export function createMermaid({ cacheDir, chromePath = findChrome(), log = () => {}, render } = {}) {
  let browser = null;
  let idle = null;
  let tail = Promise.resolve();

  async function launch() {
    if (!chromePath) throw new HttpError(501, "Chrome nao encontrado: defina CHROME_PATH para renderizar mermaid");
    if (!browser) {
      const { default: puppeteer } = await import("puppeteer");
      browser = puppeteer.launch({ executablePath: chromePath, headless: true });
      browser.catch(() => {
        browser = null;
      });
    }
    clearTimeout(idle);
    idle = setTimeout(close, IDLE_CLOSE_MS).unref();
    return browser;
  }

  async function renderWithChrome(code, theme) {
    const { renderMermaid } = await import("@mermaid-js/mermaid-cli");
    const instance = await launch();
    const { data } = await renderMermaid(instance, code, "png", {
      backgroundColor: PALETTES[theme].bg,
      mermaidConfig: mermaidConfig(theme),
      viewport: { width: 1200, height: 800, deviceScaleFactor: 2 },
    });
    return Buffer.from(data);
  }

  /** Um render por vez: o Chrome e compartilhado e o custo e de CPU, nao de espera. */
  function png(code, theme = "dark") {
    const key = createHash("sha256").update(`${STYLE}\n${theme}\n${code}`).digest("hex");
    const file = path.join(cacheDir, `${key}.png`);
    const job = tail.then(async () => {
      const cached = await fs.readFile(file).catch(() => null);
      if (cached) return cached;
      const draw = (text) => withTimeout((render ?? renderWithChrome)(text, theme), RENDER_TIMEOUT_MS, "mermaid");
      let data;
      try {
        data = await draw(code);
      } catch (err) {
        if (err instanceof HttpError) throw err;
        const repaired = repairMermaid(code);
        data = repaired === code ? null : await draw(repaired).catch(() => null);
        // Sintaxe invalida chega como erro do mermaid: o app mostra o texto e volta ao codigo.
        if (!data) throw new HttpError(422, String(err?.message ?? err).split("\n").slice(0, 3).join(" ").trim());
      }
      await fs.mkdir(cacheDir, { recursive: true });
      const tmp = `${file}.${process.pid}.tmp`;
      await fs.writeFile(tmp, data);
      await fs.rename(tmp, file);
      return data;
    });
    tail = job.catch(() => {});
    return job;
  }

  async function close() {
    clearTimeout(idle);
    const current = browser;
    browser = null;
    if (!current) return;
    try {
      await (await current).close();
    } catch (err) {
      log("falha ao fechar o Chrome do mermaid", err);
    }
  }

  return { png, close };
}
