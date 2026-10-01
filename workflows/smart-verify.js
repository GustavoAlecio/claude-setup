export const meta = {
  name: 'smart-verify',
  description: 'Fluxo Smart: G1 arquitetural do ciclo inteiro + G2 QA; reprovou → reentra no smart-implement com a escada',
  whenToUse: 'Invocado pela skill /verify. Não chamar direto sem args.',
  phases: [
    { title: 'G1', detail: 'reviewers da stack sobre o diff do ciclo' },
    { title: 'G2', detail: 'QA: critérios de aceite, testes e runtime' },
    { title: 'Reentry', detail: 'findings mapeados para tasks → smart-implement' },
  ],
}

const A = args || {}
const RANK = { haiku: 0, sonnet: 1, opus: 2, fable: 3 }
const BLOCKING = ['critical', 'major']
const MAX_ROUNDS = A.max_rounds || 2
const BIN = '~/.claude/bin'

const FINDING = {
  type: 'object',
  required: ['id', 'severity', 'file', 'message'],
  properties: {
    id: { type: 'string' },
    severity: { type: 'string', enum: ['critical', 'major', 'minor', 'nit'] },
    file: { type: 'string' },
    line: { type: 'integer' },
    rule_ref: { type: 'string' },
    message: { type: 'string' },
    fix_hint: { type: 'string' },
  },
}
const VERDICT = {
  type: 'object',
  required: ['gate', 'verdict', 'findings'],
  properties: {
    gate: { type: 'string' },
    verdict: { type: 'string', enum: ['pass', 'fail', 'inconclusive'] },
    findings: { type: 'array', items: FINDING },
    evidence: { type: 'array', items: { type: 'string' } },
  },
}
const QA = {
  type: 'object',
  required: ['gate', 'verdict', 'findings', 'criteria'],
  properties: {
    ...VERDICT.properties,
    criteria: {
      type: 'array',
      items: {
        type: 'object',
        required: ['criterion', 'status', 'evidence'],
        properties: {
          criterion: { type: 'string' },
          status: { type: 'string', enum: ['PASS', 'PARTIAL', 'FAIL', 'UNTESTABLE'] },
          evidence: { type: 'string' },
        },
      },
    },
  },
}

const blocking = v => (v && v.findings ? v.findings.filter(f => BLOCKING.includes(f.severity)).map(f => ({ ...f, gate: v.gate })) : [])
const slim = f => ({ id: f.id, severity: f.severity, file: f.file, line: f.line, rule_ref: f.rule_ref, message: (f.message || '').slice(0, 300) })
const topTier = tasks => tasks.reduce((t, x) => (RANK[x.tier] > RANK[t] ? x.tier : t), 'opus')
const trace = []

function g1Prompt(reviewer, round) {
  return `Repo: ${A.project_path}
Você é o gate G1 (arquitetural) do ciclo inteiro, lente ${reviewer}. Ignore o formato em array JSON da sua definição: devolva pela StructuredOutput com gate="G1:${reviewer}".
Escopo: o diff do ciclo, \`bash ${BIN}/wf-checkpoint.sh diff ${A.project_path} ${A.base_checkpoint}\`.
Referências: spec ${A.spec_path}, plano ${A.plan_path}, rules em ${A.project_path}/${A.stack.rules_dir}, ADRs via \`python3 ${BIN}/adr-index.py match ${A.project_path} --dir ${A.stack.adr_dir} <arquivos>\`${A.lessons_path ? `, lessons ${A.lessons_path}` : ''}.
Foque no que só aparece olhando o conjunto: fronteiras entre camadas/pacotes, contratos entre tasks, duplicação entre arquivos, DI/rotas registradas, estado inconsistente entre BLoCs.
critical/major exigem linha, cenário concreto e rule_ref (rule, ADR ou convenção do CLAUDE.md). Resto é minor/nit.
Rodada ${round}. Ao final: \`python3 ${BIN}/wf-event.py log --run-dir ${A.run_dir} --role g1 --stage verify --verdict <pass|fail> --count <n bloqueantes> --note ${reviewer}\``
}

function qaPrompt(round) {
  return `Repo: ${A.project_path}
Você é o gate G2 (QA) do ciclo. Devolva pela StructuredOutput com gate="G2".
1. Leia os critérios de aceite em ${A.spec_path} e a "Estratégia de testes" em ${A.plan_path}.
2. Rode a suíte dos pacotes tocados (arquivos: \`bash ${BIN}/wf-checkpoint.sh changed ${A.project_path} ${A.base_checkpoint}\`).
3. Para critérios de comportamento visível, valide em runtime no device "${A.stack.g2_device}" com as ferramentas do dart MCP (launch_app, flutter_driver, get_widget_tree, get_runtime_errors, hot_reload). Pare o app ao terminar (stop_app).
4. Para cada critério: PASS / PARTIAL / FAIL / UNTESTABLE, com evidência (arquivo:linha, teste, ou o que observou no app).
5. Cada PARTIAL ou FAIL vira um finding major com o arquivo mais provável de conter a correção. Erro de runtime (exception, overflow, assert) é critical.
6. verdict: fail se houver finding bloqueante; inconclusive se não conseguiu validar (app não subiu, device indisponível) — explique em evidence.
Rodada ${round}. Ao final: \`python3 ${BIN}/wf-event.py log --run-dir ${A.run_dir} --role g2 --stage verify --verdict <pass|fail|inconclusive> --count <n bloqueantes>\``
}

async function timed(role, round, fn) {
  const before = budget.spent()
  const out = await fn()
  const open = blocking(out)
  trace.push({ role, stage: 'verify', round, verdict: out ? out.verdict : 'agent_failed', blocking: open.map(f => `${f.gate}:${f.file}:${f.rule_ref || f.id}`), findings: open.map(slim), tokens_out: budget.spent() - before })
  return out
}

let tasks = (A.tasks || []).map(t => ({ ...t }))
let checkpoint = A.checkpoint
let report = null

for (let round = 1; round <= MAX_ROUNDS + 1; round++) {
  phase('G1')
  const g1 = (await parallel(A.stack.g1_reviewers.map(r => () =>
    timed(`g1:${r}`, round, () => agent(g1Prompt(r, round),
      { label: `g1:${r}:r${round}`, phase: 'G1', model: topTier(tasks), effort: 'high', agentType: r, schema: VERDICT })))))
  const g1Failed = g1.some(v => v === null)

  phase('G2')
  // Driving the app from a QA agent has repeatedly restarted the host session; skip_g2 leaves UI QA to a human.
  let g2 = A.skip_g2
    ? { gate: 'G2', verdict: 'pass', findings: [], criteria: [], evidence: ['skip_g2: QA de UI manual guiado fora do workflow'] }
    : await timed('g2', round, () => agent(qaPrompt(round),
      { label: `g2:r${round}`, phase: 'G2', model: 'sonnet', agentType: A.stack.g2_agent, schema: QA }))
  if (!A.skip_g2 && g2 && g2.verdict === 'inconclusive') {
    g2 = await timed('g2', round, () => agent(qaPrompt(round),
      { label: `g2:r${round}:opus`, phase: 'G2', model: 'opus', effort: 'high', agentType: A.stack.g2_agent, schema: QA }))
  }

  const failing = [...g1.filter(Boolean).flatMap(blocking), ...blocking(g2)]
  report = {
    round,
    g1: g1.filter(Boolean).map(v => ({ gate: v.gate, verdict: v.verdict, findings: v.findings })),
    g2: g2 ? { verdict: g2.verdict, criteria: g2.criteria, findings: g2.findings, evidence: g2.evidence } : null,
  }

  if (g1Failed || !g2) {
    return { status: 'blocked', reason: 'gate_failed_to_run', report, tasks, checkpoint, trace }
  }
  if (g2.verdict === 'inconclusive') {
    return { status: 'inconclusive', reason: 'qa_inconclusive', report, tasks, checkpoint, trace }
  }
  if (failing.length === 0) {
    return { status: 'verified', report, tasks, checkpoint, trace }
  }
  if (round > MAX_ROUNDS) {
    return { status: 'blocked', reason: 'verify_rounds_exhausted', report, tasks, checkpoint, trace }
  }

  const byTask = new Map()
  const unmapped = []
  for (const f of failing) {
    const owner = [...tasks].reverse().find(t => (t.files_changed || []).includes(f.file))
    if (owner) byTask.set(owner.id, [...(byTask.get(owner.id) || []), f])
    else unmapped.push(f)
  }
  const reentry = tasks.filter(t => byTask.has(t.id)).map(t => ({
    ...t,
    title: `${t.title} (correção verify r${round})`,
    feedback: { mode: 'fix_in_place', findings: byTask.get(t.id) },
  }))
  if (unmapped.length) {
    reentry.push({
      id: `V${round}`,
      title: `Correções transversais do verify r${round}`,
      description: 'Findings do verify sem task dona (arquivos fora do que as tasks tocaram).',
      complexity: unmapped.length > 3 ? 'L' : 'M',
      risk: 'high',
      affects: [...new Set(unmapped.map(f => f.file))],
      tests: [],
      feedback: { mode: 'fix_in_place', findings: unmapped },
    })
  }
  log(`rodada ${round}: ${failing.length} finding(s) bloqueante(s) → reentrada em ${reentry.map(t => t.id).join(', ')}`)

  phase('Reentry')
  const child = await workflow('smart-implement', { ...A, tasks: reentry, checkpoint })
  trace.push(...((child && child.trace) || []).map(e => ({ ...e, stage: 'verify-reentry', round })))
  if (!child) return { status: 'blocked', reason: 'reentry_failed_to_run', report, tasks, checkpoint, trace }

  checkpoint = child.checkpoint || checkpoint
  for (const r of child.tasks || []) {
    const i = tasks.findIndex(t => t.id === r.id)
    if (i >= 0) tasks[i] = { ...tasks[i], ...r, status: r.status === 'done' ? 'done' : r.status }
    else if (r.status) tasks.push(r)
  }
  if (child.status !== 'done') {
    return { status: child.status, reason: child.reason, blocked_task: child.blocked_task, diagnosis: child.diagnosis, history: child.history, report, tasks, checkpoint, trace }
  }
}

return { status: 'blocked', reason: 'unreachable', report, tasks, checkpoint, trace }
