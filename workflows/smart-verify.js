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
const MAX_ROUNDS = A.max_rounds ?? 2
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

const CRITERION = ['PASS', 'PARTIAL', 'FAIL', 'UNTESTABLE']
const VERDICTS = ['pass', 'fail', 'inconclusive']
// Reasons a code fix cannot clear; the others reenter the ladder when there are blocking findings to hand over.
const STRUCTURAL = ['G1_NOT_RUN', 'G2_NOT_RUN', 'G2_MALFORMED', 'G1_INCONCLUSIVE', 'G2_INCONCLUSIVE', 'NO_CRITERIA']

// Deterministic and fail-closed: anything missing, malformed or unknown is never evidence of PASS.
function decide({ g1, g2, skipG2 }) {
  const reasons = []
  const g1Ok = Array.isArray(g1) && g1.length > 0 && g1.every(v => v && VERDICTS.includes(v.verdict) && Array.isArray(v.findings))
  if (!g1Ok) reasons.push('G1_NOT_RUN')
  else {
    if (g1.some(v => v.verdict === 'inconclusive')) reasons.push('G1_INCONCLUSIVE')
    if (g1.some(v => v.verdict === 'fail')) reasons.push('G1_FAIL')
  }

  const counts = { total: 0, passed: 0, failed: 0, partial: 0, untestable: 0 }
  const criteriaFailed = []
  const criteriaUntestable = []
  let g2Verdict = null
  if (skipG2) reasons.push('QA_SKIPPED')
  else if (!g2) reasons.push('G2_NOT_RUN')
  else if (!VERDICTS.includes(g2.verdict) || !Array.isArray(g2.findings) || !Array.isArray(g2.criteria)) reasons.push('G2_MALFORMED')
  else {
    g2Verdict = g2.verdict
    if (g2.verdict === 'inconclusive') reasons.push('G2_INCONCLUSIVE')
    if (g2.verdict === 'fail') reasons.push('G2_FAIL')
    counts.total = g2.criteria.length
    for (const c of g2.criteria) {
      const st = c && CRITERION.includes(c.status) ? c.status : null
      if (!st) { reasons.push('G2_MALFORMED'); continue }
      if (st === 'PASS') {
        if (typeof c.evidence === 'string' && c.evidence.trim()) counts.passed++
        else { counts.untestable++; criteriaUntestable.push(c.criterion) }
      } else if (st === 'UNTESTABLE') { counts.untestable++; criteriaUntestable.push(c.criterion) }
      else { counts[st === 'FAIL' ? 'failed' : 'partial']++; criteriaFailed.push({ criterion: c.criterion, status: st }) }
    }
    if (counts.total === 0) reasons.push('NO_CRITERIA')
    if (criteriaFailed.length) reasons.push('CRITERIA_FAILED')
    if (counts.untestable) reasons.push('CRITERIA_UNTESTED')
    if (counts.total > 0 && counts.passed === 0) reasons.push('NO_POSITIVE_EVIDENCE')
  }

  const blockingFindings = [...(g1Ok ? g1 : []).filter(Boolean).flatMap(blocking), ...(g2Verdict ? blocking(g2) : [])]
  if (blockingFindings.length) reasons.push('BLOCKING_FINDINGS')

  const uniq = [...new Set(reasons)]
  const notRun = uniq.some(r => r === 'G1_NOT_RUN' || r === 'G2_NOT_RUN')
  return {
    status: uniq.length === 0 ? 'verified' : notRun ? 'blocked' : 'unverified',
    reason_code: uniq[0] || 'VERIFIED',
    reasons: uniq,
    g1: (Array.isArray(g1) ? g1 : []).map(v => (v ? { gate: v.gate, verdict: v.verdict } : { gate: null, verdict: 'not_run' })),
    g2: skipG2 ? { verdict: 'skipped' } : { verdict: g2Verdict || (g2 ? 'malformed' : 'not_run') },
    criteria: counts,
    criteria_failed: criteriaFailed,
    criteria_untestable: criteriaUntestable,
    blocking_findings: blockingFindings.map(f => ({ gate: f.gate, ...slim(f) })),
    evidence_refs: g2Verdict && Array.isArray(g2.evidence) ? g2.evidence : [],
    gates_run: [...(g1Ok ? g1.map(v => v.gate) : []), ...(g2Verdict ? ['G2'] : [])],
    human_override: false,
  }
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
Mapa da org: se existir .map/index.md em ${A.project_path} ou numa pasta acima (nunca abaixo), leia o índice e as notas/gerados relevantes antes de buscar no código; nota STALE não é confiável; o mapa descreve origin/development.
Foque no que só aparece olhando o conjunto: fronteiras entre camadas/pacotes, contratos entre tasks, duplicação entre arquivos, DI/rotas registradas, estado inconsistente entre BLoCs.
critical/major exigem linha, cenário concreto e rule_ref (rule, ADR ou convenção do CLAUDE.md). Resto é minor/nit.
Rodada ${round}. Ao final: \`python3 ${BIN}/wf-event.py log --run-dir ${A.run_dir} --role g1 --stage verify --verdict <pass|fail> --count <n bloqueantes> --note ${reviewer}\``
}

function qaPrompt(round) {
  return `Repo: ${A.project_path}
Você é o gate G2 (QA) do ciclo. Devolva pela StructuredOutput com gate="G2".
Mapa da org: se existir .map/index.md em ${A.project_path} ou numa pasta acima (nunca abaixo), leia o índice e as notas/gerados relevantes antes de buscar no código; nota STALE não é confiável; o mapa descreve origin/development.
1. Leia os critérios de aceite em ${A.spec_path} e a "Estratégia de testes" em ${A.plan_path}.
2. Rode a suíte dos pacotes tocados (arquivos: \`bash ${BIN}/wf-checkpoint.sh changed ${A.project_path} ${A.base_checkpoint}\`).
3. ${A.stack.g2_runtime || `Para critérios de comportamento visível, valide em runtime no device "${A.stack.g2_device}" com as ferramentas do dart MCP (launch_app, flutter_driver, get_widget_tree, get_runtime_errors, hot_reload). Pare o app ao terminar (stop_app).`}
4. Para cada critério: PASS / PARTIAL / FAIL / UNTESTABLE, com evidência (arquivo:linha, teste, ou o que observou no app). PASS só com evidência executada (teste que rodou, observação no app); leitura de código sem execução é UNTESTABLE. Não alegue execução de app, device ou golden sem artefato correspondente em evidence.
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
let revisionStart = A.revision_start || null

const finish = (decision, extra = {}) => ({
  status: extra.status || decision.status,
  reason: extra.reason || decision.reason_code,
  decision: { ...decision, ...(extra.status ? { status: extra.status, reason_code: extra.reason } : {}), repo: A.project_path, revision_start: revisionStart },
  report, tasks, checkpoint, trace,
})

for (let round = 1; round <= MAX_ROUNDS + 1; round++) {
  phase('G1')
  const g1 = (await parallel(A.stack.g1_reviewers.map(r => () =>
    timed(`g1:${r}`, round, () => agent(g1Prompt(r, round),
      { label: `g1:${r}:r${round}`, phase: 'G1', model: topTier(tasks), effort: 'high', agentType: r, schema: VERDICT })))))

  phase('G2')
  // Driving the app from a QA agent has repeatedly restarted the host session; skip_g2 leaves UI QA to a human,
  // which can never count as verified: the cycle closes only through accept-unverified.
  let g2 = null
  if (!A.skip_g2) {
    g2 = await timed('g2', round, () => agent(qaPrompt(round),
      { label: `g2:r${round}`, phase: 'G2', model: 'sonnet', agentType: A.stack.g2_agent, schema: QA }))
    if (g2 && g2.verdict === 'inconclusive') {
      g2 = await timed('g2', round, () => agent(qaPrompt(round),
        { label: `g2:r${round}:opus`, phase: 'G2', model: 'opus', effort: 'high', agentType: A.stack.g2_agent, schema: QA }))
    }
  }

  const decision = decide({ g1, g2, skipG2: !!A.skip_g2 })
  report = {
    round,
    g1: g1.filter(Boolean).map(v => ({ gate: v.gate, verdict: v.verdict, findings: v.findings })),
    g2: A.skip_g2 ? { verdict: 'skipped', criteria: [], findings: [], evidence: ['skip_g2: QA de UI manual guiado fora do workflow'] }
      : g2 ? { verdict: g2.verdict, criteria: g2.criteria, findings: g2.findings, evidence: g2.evidence } : null,
  }

  if (decision.status !== 'unverified' || decision.blocking_findings.length === 0) return finish(decision)
  if (decision.reasons.some(r => STRUCTURAL.includes(r))) return finish(decision)
  if (round > MAX_ROUNDS) return finish(decision, { status: 'blocked', reason: 'VERIFY_ROUNDS_EXHAUSTED' })

  const failing = [...g1.filter(Boolean).flatMap(blocking), ...(g2 ? blocking(g2) : [])]
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
  if (!child) return finish(decision, { status: 'blocked', reason: 'REENTRY_FAILED_TO_RUN' })

  checkpoint = child.checkpoint || checkpoint
  // The next round judges the tree the reentry left behind; its last G0 snapshot is that tree.
  revisionStart = child.checkpoint || null
  for (const r of child.tasks || []) {
    const i = tasks.findIndex(t => t.id === r.id)
    if (i >= 0) tasks[i] = { ...tasks[i], ...r, status: r.status === 'done' ? 'done' : r.status }
    else if (r.status) tasks.push(r)
  }
  if (child.status !== 'done') {
    return { ...finish(decision, { status: child.status, reason: child.reason || 'REENTRY_NOT_DONE' }), blocked_task: child.blocked_task, diagnosis: child.diagnosis, history: child.history }
  }
}

return finish(decide({ g1: [], g2: null }), { status: 'blocked', reason: 'UNREACHABLE' })
