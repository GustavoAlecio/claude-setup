import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

export function loadWorkflow(name) {
  const src = readFileSync(join(root, 'workflows', `${name}.js`), 'utf8').replace('export const meta', 'const meta')
  const fn = new AsyncFunction('args', 'budget', 'agent', 'parallel', 'pipeline', 'log', 'phase', 'workflow', src)
  return ({ args, agent, workflow = async () => null, budget = { spent: () => 0, total: null, remaining: () => Infinity } }) => {
    const parallel = thunks => Promise.all(thunks.map(t => t().catch(() => null)))
    return fn(args, budget, agent, parallel, null, () => {}, () => {}, workflow)
  }
}

export const STACK = {
  rules_dir: '.claude/rules', adr_dir: 'docs/adr', g1_task_reviewer: 'flutter-architecture',
  g1_reviewers: ['flutter-architecture', 'dart-correctness'], g2_agent: 'qa-flutter', g2_device: 'macos',
}
export const pass = gate => ({ gate, verdict: 'pass', findings: [], snapshot: 'cpN' })
export function meteredBudget() {
  let spent = 0
  return { spend: n => { spent += n }, spent: () => spent, total: null, remaining: () => Infinity }
}
export const fail = (gate, file, rule) => ({ gate, verdict: 'fail', findings: [{ id: 'X', severity: 'major', file, rule_ref: rule, message: 'm' }] })
