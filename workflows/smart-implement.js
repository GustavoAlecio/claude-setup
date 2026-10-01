export const meta = {
  name: 'smart-implement',
  description: 'Fluxo Smart: executa tasks com escada de modelos (haiku→sonnet→opus→fable), gates G0/G1 e diagnóstico ToT quando bloqueia',
  whenToUse: 'Invocado pela skill /implement (e pelo smart-verify na reentrada). Não chamar direto sem args.',
  phases: [
    { title: 'Implement', detail: 'dev-implementer no tier corrente' },
    { title: 'G0', detail: 'format, codegen, analyze, testes da task (determinístico)' },
    { title: 'G1', detail: 'review arquitetural do diff da task' },
    { title: 'Ops', detail: 'rollback de checkpoint na escalada' },
    { title: 'Diagnose', detail: 'ToT: 3 hipóteses independentes quando a escada esgota' },
  ],
}

const A = args || {}
const LADDER = ['haiku', 'sonnet', 'opus', 'fable']
const TIER0 = { S: 'haiku', M: 'sonnet', L: 'opus' }
const RANK = { haiku: 0, sonnet: 1, opus: 2, fable: 3 }
const BLOCKING = ['critical', 'major']
const MAX_ATTEMPTS = A.max_attempts || 5
const PER_TIER = A.per_tier || 2
const BIN = '~/.claude/bin'

const atLeast = (floor, tier) => (RANK[tier] >= RANK[floor] ? tier : floor)
const nextTier = t => LADDER[RANK[t] + 1] || 'human'
const fkey = f => `${f.gate || ''}:${f.file || ''}:${f.rule_ref || f.id || ''}`
const blocking = v => (v && v.findings ? v.findings.filter(f => BLOCKING.includes(f.severity)).map(f => ({ ...f, gate: v.gate })) : [])

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
    snapshot: { type: 'string' },
    changed_files: { type: 'array', items: { type: 'string' } },
  },
}
const DEV_RESULT = {
  type: 'object',
  required: ['status', 'summary', 'files_changed'],
  properties: {
    status: { type: 'string', enum: ['done', 'blocked'] },
    summary: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
    blocked_reason: { type: 'string' },
    decisions: { type: 'array', items: { type: 'string' } },
  },
}
const OPS = { type: 'object', required: ['ok', 'output'], properties: { ok: { type: 'boolean' }, output: { type: 'string' } } }
const HYPOTHESIS = {
  type: 'object',
  required: ['lens', 'hypothesis', 'confidence', 'evidence', 'recommended_action'],
  properties: {
    lens: { type: 'string' },
    hypothesis: { type: 'string' },
    confidence: { type: 'number' },
    evidence: { type: 'array', items: { type: 'string' } },
    recommended_action: { type: 'string', enum: ['fix_spec', 'replan', 'fix_environment', 'split_task', 'human_takeover'] },
  },
}

const trace = []
const spent = () => budget.spent()

async function step(role, task, attempt, tier, fn) {
  const before = spent()
  const out = await fn()
  trace.push({
    role,
    task: task.id,
    attempt,
    tier,
    verdict: out ? out.verdict || out.status || (out.ok === undefined ? null : out.ok ? 'ok' : 'error') : 'agent_failed',
    blocking: out && out.findings ? blocking(out).map(fkey) : [],
    tokens_out: spent() - before,
  })
  return out
}

function context(task) {
  return [
    `Repo: ${A.project_path}`,
    `Plano: ${A.plan_path}`,
    A.lessons_path ? `Lessons do projeto (constraints): ${A.lessons_path}` : null,
    `Rules do projeto: ${A.project_path}/${A.stack.rules_dir} (leia as que casam com os arquivos tocados; ausente = sem rules)`,
    `ADRs relevantes: rode \`python3 ${BIN}/adr-index.py match ${A.project_path} --dir ${A.stack.adr_dir} <arquivos>\` e leia os que voltarem.`,
    `Task ${task.id} [${task.complexity}${task.risk === 'high' ? ', risco alto' : ''}] — ${task.title}`,
    task.description ? `Descrição: ${task.description}` : null,
    task.affects && task.affects.length ? `Escopo esperado: ${task.affects.join(', ')}` : null,
    task.tests && task.tests.length ? `Testes da task (devem existir e passar): ${task.tests.join(', ')}` : null,
  ].filter(Boolean).join('\n')
}

function devPrompt(task, tier, attempt, feedback) {
  const fb = !feedback ? '' : feedback.mode === 'fix_in_place'
    ? `\n\n## Tentativa anterior reprovou — corrija no lugar\nO diff atual é da sua tentativa anterior. Corrija exatamente os findings abaixo sem reescrever o que já está certo.\n${JSON.stringify(feedback.findings, null, 2)}`
    : `\n\n## Recomeço do zero (escalado de ${feedback.previous_tier} para ${tier})\nO working tree foi restaurado para o checkpoint da task. Um modelo anterior tentou e falhou nestes pontos — não repita a abordagem que levou a eles.\nResumo da tentativa anterior: ${feedback.previous_summary || 'n/d'}\nFindings que ficaram abertos:\n${JSON.stringify(feedback.findings, null, 2)}`
  return `${context(task)}

Tentativa ${attempt}, tier ${tier}.
Antes de tudo, registre o início: \`python3 ${BIN}/wf-event.py log --run-dir ${A.run_dir} --role dev --task ${task.id} --attempt ${attempt} --tier ${tier} --verdict start\`

Implemente SOMENTE esta task, seguindo o plano. Crie os testes listados se ainda não existirem.
- Não commite, não faça stash, não mude de branch.
- Não rode format/analyze como gate final: o G0 roda depois de você, de forma determinística.
- Se o plano for inviável para esta task (contrato inexistente, premissa falsa), pare e devolva status "blocked" com blocked_reason concreto — não force.
- "decisions": decisões não-óbvias que tomou e que podem merecer ADR.${fb}`
}

function g1Prompt(task, checkpoint) {
  return `${context(task)}

Você é o gate G1 (arquitetural) desta task. Ignore o formato de saída em array JSON da sua definição: devolva pela ferramenta StructuredOutput no schema dado, com gate="G1".
Escopo: SOMENTE o diff desta task: \`bash ${BIN}/wf-checkpoint.sh diff ${A.project_path} ${checkpoint}\`.
Julgue contra rules do projeto, ADRs aceitos que casam com os arquivos, CLAUDE.md do projeto e o plano.
- critical/major só com prova (linha, cenário, regra violada em rule_ref: caminho da rule ou ADR). Esses reprovam.
- Estilo, preferência, melhoria opcional → minor/nit (não reprovam).
- Não revise o que o G0 já cobre (format, lints do analyzer, testes).
Ao final rode: \`python3 ${BIN}/wf-event.py log --run-dir ${A.run_dir} --role g1 --task ${task.id} --verdict <pass|fail> --count <n bloqueantes>\``
}

async function diagnose(task, history) {
  const lenses = [
    ['spec', 'A spec ou os critérios de aceite são ambíguos, contraditórios ou incompletos para esta task?'],
    ['plan', 'O plano técnico é inviável para esta task (contrato, arquitetura, ordem de tasks, escopo grande demais)?'],
    ['environment', 'A falha vem do ambiente: teste flaky, codegen, dependência, tooling, rule/ADR conflitante ou gate errado?'],
  ]
  const hyps = await parallel(lenses.map(([lens, q]) => () =>
    agent(`${context(task)}

A task esgotou a escada de modelos. Histórico de tentativas (tier, findings bloqueantes):
${JSON.stringify(history, null, 2)}

Investigue de forma independente pela lente "${lens}": ${q}
Leia spec (${A.spec_path}), plano e código. Não implemente nada. Seja específico; confidence entre 0 e 1.`,
      { label: `diagnose:${task.id}:${lens}`, phase: 'Diagnose', model: 'opus', effort: 'high', schema: HYPOTHESIS })))
  return hyps.filter(Boolean).sort((a, b) => b.confidence - a.confidence)
}

let checkpoint = A.checkpoint
const results = []

for (const task of A.tasks || []) {
  const tier0 = task.tier0 || TIER0[task.complexity] || 'sonnet'
  let tier = task.tier || tier0
  let attempts = 0
  let tierAttempts = 0
  let feedback = task.feedback || null
  let prevCount = Infinity
  let lastDev = null
  let lastTierKeys = new Set()
  const escalations = []
  const history = []
  const cp = checkpoint
  let outcome = null

  while (!outcome) {
    if (attempts >= MAX_ATTEMPTS) { outcome = { status: 'blocked', reason: 'max_attempts' }; break }
    attempts++; tierAttempts++
    log(`${task.id} tentativa ${attempts} @ ${tier}`)

    const dev = await step('dev', task, attempts, tier, () =>
      agent(devPrompt(task, tier, attempts, feedback),
        { label: `dev:${task.id}#${attempts}@${tier}`, phase: 'Implement', model: tier, agentType: 'dev-implementer', schema: DEV_RESULT }))
    if (!dev) { outcome = { status: 'blocked', reason: 'agent_failed' }; break }
    lastDev = dev
    if (dev.status === 'blocked') { outcome = { status: 'backtrack', reason: dev.blocked_reason }; break }

    const g0 = await step('g0', task, attempts, tier, () =>
      agent(`Rode exatamente o comando abaixo e devolva o JSON impresso no stdout, campo a campo, sem interpretar nem resumir:
python3 ${BIN}/gate_g0.py --repo ${A.project_path} --stack ${A.stack_name} --checkpoint ${cp} --tests "${(task.tests || []).join(',')}" --run-dir ${A.run_dir} --task ${task.id} --attempt ${attempts} --tier ${tier}`,
        { label: `g0:${task.id}#${attempts}`, phase: 'G0', model: 'haiku', effort: 'low', schema: VERDICT }))
    if (!g0) { outcome = { status: 'blocked', reason: 'g0_failed_to_run' }; break }

    let g1 = null
    if (g0.verdict === 'pass') {
      g1 = await step('g1', task, attempts, tier, () =>
        agent(g1Prompt(task, cp),
          { label: `g1:${task.id}#${attempts}`, phase: 'G1', model: atLeast('opus', tier), effort: 'high', agentType: A.stack.g1_task_reviewer, schema: VERDICT }))
      if (!g1) { outcome = { status: 'blocked', reason: 'g1_failed_to_run' }; break }
    }

    const failing = [...blocking(g0), ...blocking(g1)]
    history.push({ attempt: attempts, tier, failing: failing.map(f => ({ gate: f.gate, file: f.file, rule_ref: f.rule_ref, message: (f.message || '').slice(0, 300) })) })

    if (g0.verdict === 'pass' && g1 && g1.verdict !== 'fail' && failing.length === 0) {
      checkpoint = g0.snapshot || checkpoint
      outcome = { status: 'done' }
      break
    }

    const keys = new Set(failing.map(fkey))
    const escalate = tierAttempts >= PER_TIER || failing.length >= prevCount
    if (!escalate) {
      feedback = { mode: 'fix_in_place', findings: failing }
      prevCount = failing.length
      continue
    }

    const repeatedAcrossTiers = [...keys].some(k => lastTierKeys.has(k))
    const nt = nextTier(tier)
    if (nt === 'human' || repeatedAcrossTiers) {
      outcome = { status: 'blocked', reason: repeatedAcrossTiers ? 'same_failure_across_tiers' : 'ladder_exhausted' }
      break
    }

    const ops = await step('ops', task, attempts, tier, () =>
      agent(`Rode exatamente: bash ${BIN}/wf-checkpoint.sh restore ${A.project_path} ${cp}
Depois: python3 ${BIN}/wf-event.py log --run-dir ${A.run_dir} --role escalate --task ${task.id} --tier ${nt} --note "from ${tier}"
Devolva ok=true se o restore imprimiu "restored", e o stdout em output.`,
        { label: `rollback:${task.id}`, phase: 'Ops', model: 'haiku', effort: 'low', schema: OPS }))
    if (!ops || !ops.ok) { outcome = { status: 'blocked', reason: 'rollback_failed' }; break }

    escalations.push({ from: tier, to: nt, at_attempt: attempts, open: [...keys] })
    feedback = { mode: 'fresh_start', previous_tier: tier, previous_summary: dev.summary, findings: failing }
    lastTierKeys = keys
    tier = nt
    tierAttempts = 0
    prevCount = Infinity
  }

  const rec = {
    id: task.id,
    complexity: task.complexity,
    risk: task.risk || 'low',
    tier0,
    tier,
    attempts: (task.attempts || 0) + attempts,
    escalations,
    status: outcome.status,
    reason: outcome.reason || null,
    files_changed: lastDev ? lastDev.files_changed : [],
    decisions: lastDev ? lastDev.decisions || [] : [],
    summary: lastDev ? lastDev.summary : null,
  }
  results.push(rec)

  if (outcome.status !== 'done') {
    const diagnosis = outcome.status === 'blocked' && outcome.reason !== 'agent_failed' ? await diagnose(task, history) : []
    const pending = (A.tasks || []).slice((A.tasks || []).indexOf(task) + 1).map(t => ({ id: t.id, status: 'pending' }))
    return {
      status: outcome.status,
      blocked_task: task.id,
      reason: outcome.reason,
      diagnosis,
      history,
      checkpoint,
      tasks: [...results, ...pending],
      trace,
    }
  }
}

return { status: 'done', checkpoint, tasks: results, trace }
