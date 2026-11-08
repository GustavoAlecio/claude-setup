#!/usr/bin/env node
// `agy` falso: fala o stream-json do headless e roda o hook PreToolUse que o engine gravou no HOME,
// como o real. Mensagens: `text:<texto>` responde texto; `tool:<nome>:<args json>` chama uma tool.
import { spawn } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import path from "node:path";
import readline from "node:readline";

const args = process.argv.slice(2);
const conversation = args.includes("--conversation") ? args[args.indexOf("--conversation") + 1] : "conv-1";
if (process.env.FAKE_AGY_LOG) {
  appendFileSync(process.env.FAKE_AGY_LOG, `${JSON.stringify({ args, home: process.env.HOME, cwd: process.cwd() })}\n`);
}

const out = (event) => process.stdout.write(`${JSON.stringify(event)}\n`);
let step = 0;
let turns = 0;
const update = (fields) => out({ event: "step_update", step_update: { conversation_id: conversation, ...fields } });

function hook(call) {
  const hooks = JSON.parse(readFileSync(path.join(process.env.HOME, ".gemini", "config", "hooks.json"), "utf8"));
  const command = Object.values(hooks)[0].PreToolUse[0].hooks[0].command;
  return new Promise((resolve) => {
    const child = spawn(command, { shell: true, stdio: ["pipe", "pipe", "inherit"] });
    let stdout = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.on("exit", (code) => resolve(code === 0 ? JSON.parse(stdout) : { decision: "deny", reason: `hook exit ${code}` }));
    child.stdin.end(JSON.stringify({ conversationId: conversation, stepIdx: step, toolCall: call }));
  });
}

out({ event: "init", conversation_id: conversation, init: { model: args[args.indexOf("--model") + 1] ?? "gemini-x", cwd: process.cwd(), tools: [] } });

for await (const line of readline.createInterface({ input: process.stdin })) {
  const content = JSON.parse(line).message.content;
  if (content === "quota") {
    process.stderr.write('error: Individual quota reached.\nAGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 159h3m32s.","retryable":true}\n');
    process.exit(3);
  }
  update({ step_index: step++, state: "DONE", step_type: "user_input" });
  if (content.startsWith("tool:")) {
    const [, name, raw] = content.match(/^tool:([^:]+):(.*)$/s);
    const toolArgs = JSON.parse(raw);
    const index = step++;
    update({ step_index: index, state: "ACTIVE", step_type: "tool", tool_name: name, tool_info: { name, parameters: toolArgs } });
    const { decision, reason } = await hook({ name, args: toolArgs });
    update(
      decision === "allow"
        ? { step_index: index, state: "DONE", step_type: "tool", tool_name: name, tool_info: { name, parameters: toolArgs, output: `ok:${name}` } }
        : { step_index: index, state: "ERROR", step_type: "tool", tool_name: name, tool_info: { name, parameters: toolArgs, error: { type: "TOOL_ERROR", message: `tool call denied by pre-tool hook: ${reason}` } } }
    );
  }
  const text = content.startsWith("text:") ? content.slice(5) : "feito";
  const index = step++;
  for (const piece of [text.slice(0, 2), text.slice(2)]) {
    if (piece) update({ step_index: index, state: "ACTIVE", step_type: "agent_response", text_delta: piece });
  }
  update({ step_index: index, state: "DONE", step_type: "agent_response" });
  // Como o real, os totais sao da conversa e so crescem.
  turns += 1;
  out({ event: "result", result: { conversation_id: conversation, status: "SUCCESS", response: text, duration_seconds: process.uptime(), num_turns: turns } });
}
