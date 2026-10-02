import { test } from 'node:test'
import assert from 'node:assert/strict'
import { loadWorkflow, STACK, pass, fail, meteredBudget } from './harness.mjs'

const implement = loadWorkflow('smart-implement')
const verify = loadWorkflow('smart-verify')
const baseArgs = tasks => ({ project_path: '/r', run_dir: '/d', stack_name: 'flutter', stack: STACK, checkpoint: 'cp0', plan_path: 'p', spec_path: 's', tasks })

function mockAgent(g1) {
  const calls = []
  const agent = async (_prompt, o) => {
    calls.push(o.label)
    if (o.label.startsWith('dev')) return { status: 'done', summary: 's', files_changed: ['lib/a.dart'] }
    if (o.label.startsWith('g0')) return pass('G0')
    if (o.label.startsWith('g1')) return g1(o.label)
    if (o.label.startsWith('rollback')) return { ok: true, output: 'restored 1 path(s)' }
    if (o.label.startsWith('diagnose')) return { lens: 'x', hypothesis: 'h', confidence: 0.5, evidence: [], recommended_action: 'replan' }
    throw new Error(`unexpected agent ${o.label}`)
  }
  return { agent, calls }
}

test('tier0 follows complexity and a clean task passes on the first attempt', async () => {
  const { agent, calls } = mockAgent(() => pass('G1'))
  const r = await implement({ args: baseArgs([{ id: 'T1', complexity: 'S' }, { id: 'T2', complexity: 'L' }]), agent })
  assert.equal(r.status, 'done')
  assert.deepEqual(r.tasks.map(t => t.tier), ['haiku', 'opus'])
  assert.equal(calls.filter(c => c.startsWith('dev')).length, 2)
})

test('two failures on a tier escalate with rollback and restart on the next tier', async () => {
  let n = 0
  const { agent, calls } = mockAgent(() => (++n <= 2 ? fail('G1', 'lib/a.dart', `rule${n}`) : pass('G1')))
  const r = await implement({ args: baseArgs([{ id: 'T1', complexity: 'S' }]), agent })
  assert.equal(r.status, 'done')
  assert.equal(r.tasks[0].tier, 'sonnet')
  assert.equal(r.tasks[0].attempts, 3)
  assert.ok(calls.includes('rollback:T1'))
})

test('the same failure on two different tiers trips the circuit breaker and runs ToT diagnosis', async () => {
  const { agent, calls } = mockAgent(() => fail('G1', 'lib/a.dart', 'adr/0001'))
  const r = await implement({ args: baseArgs([{ id: 'T1', complexity: 'M' }, { id: 'T2', complexity: 'S' }]), agent })
  assert.equal(r.status, 'blocked')
  assert.equal(r.reason, 'same_failure_across_tiers')
  assert.equal(calls.filter(c => c.startsWith('diagnose')).length, 3)
  assert.equal(r.tasks[1].status, 'pending')
})

test('ladder exhausts at fable', async () => {
  let n = 0
  const { agent } = mockAgent(() => fail('G1', 'lib/a.dart', `r${n++}`))
  const r = await implement({ args: baseArgs([{ id: 'T1', complexity: 'L' }]), agent })
  assert.equal(r.reason, 'ladder_exhausted')
  assert.equal(r.tasks[0].tier, 'fable')
})

test('dev-declared blocker becomes a backtrack without escalation', async () => {
  const agent = async (_p, o) => (o.label.startsWith('dev') ? { status: 'blocked', summary: '', files_changed: [], blocked_reason: 'no endpoint' } : null)
  const r = await implement({ args: baseArgs([{ id: 'T1', complexity: 'M' }]), agent })
  assert.equal(r.status, 'backtrack')
  assert.equal(r.reason, 'no endpoint')
})

test('verify maps findings to the owning task, creates a task for orphans and re-verifies', async () => {
  let qa = 0
  const agent = async (_p, o) => {
    if (o.label.startsWith('g1')) return pass('G1')
    qa++
    return qa === 1
      ? { gate: 'G2', verdict: 'fail', criteria: [], findings: [{ id: 'Q1', severity: 'major', file: 'lib/b.dart', message: 'm' }, { id: 'Q2', severity: 'major', file: 'lib/z.dart', message: 'm' }] }
      : { gate: 'G2', verdict: 'pass', criteria: [], findings: [] }
  }
  let reentry
  const workflow = async (_name, a) => {
    reentry = a.tasks.map(t => t.id)
    return { status: 'done', checkpoint: 'cp2', tasks: a.tasks.map(t => ({ id: t.id, status: 'done' })), trace: [] }
  }
  const tasks = [{ id: 'T1', tier: 'haiku', files_changed: ['lib/a.dart'] }, { id: 'T2', tier: 'sonnet', files_changed: ['lib/b.dart'] }]
  const r = await verify({ args: { ...baseArgs(tasks), base_checkpoint: 'cp0' }, agent, workflow })
  assert.equal(r.status, 'verified')
  assert.deepEqual(reentry, ['T2', 'V1'])
  assert.equal(r.checkpoint, 'cp2')
})

test('trace entries carry blocking findings ≤300', async () => {
  const budget = meteredBudget()
  const cost = { dev: 100, g0: 10, g1: 1000 }
  const long = 'x'.repeat(500)
  let n = 0
  const agent = async (_p, o) => {
    const kind = o.label.split(':')[0]
    budget.spend(cost[kind] || 0)
    if (kind === 'dev') return { status: 'done', summary: 's', files_changed: ['lib/a.dart'] }
    if (kind === 'g0') return pass('G0')
    return ++n === 1
      ? { gate: 'G1', verdict: 'fail', findings: [
        { id: 'F1', severity: 'major', file: 'lib/a.dart', line: 7, rule_ref: 'adr/0001', message: long, fix_hint: 'h' },
        { id: 'F2', severity: 'minor', file: 'lib/a.dart', message: 'nit' },
      ] }
      : pass('G1')
  }
  const r = await implement({ args: baseArgs([{ id: 'T1', complexity: 'M' }]), agent, budget })
  assert.equal(r.status, 'done')
  const g1 = r.trace.filter(e => e.role === 'g1')
  assert.deepEqual(g1[0].findings, [{ id: 'F1', severity: 'major', file: 'lib/a.dart', line: 7, rule_ref: 'adr/0001', message: 'x'.repeat(300) }])
  assert.deepEqual(g1[0].blocking, ['G1:lib/a.dart:adr/0001'])
  assert.deepEqual(g1[1].findings, [])
  assert.ok(r.trace.every(e => Array.isArray(e.findings)))
  assert.deepEqual([...new Set(r.trace.map(e => e.tokens_out))].sort((a, b) => a - b), [10, 100, 1000])

  const vbudget = meteredBudget()
  const vagent = async (_p, o) => {
    vbudget.spend(o.label.startsWith('g2') ? 7 : 3)
    return o.label.startsWith('g1')
      ? pass('G1')
      : { gate: 'G2', verdict: 'fail', criteria: [], findings: [{ id: 'Q1', severity: 'critical', file: 'lib/a.dart', message: long }] }
  }
  const v = await verify({ args: { ...baseArgs([{ id: 'T1', tier: 'haiku', files_changed: ['lib/a.dart'] }]), base_checkpoint: 'cp0' }, agent: vagent, budget: vbudget })
  assert.equal(v.reason, 'reentry_failed_to_run')
  const g2 = v.trace.find(e => e.role === 'g2')
  assert.equal(g2.findings.length, 1)
  assert.equal(g2.findings[0].message.length, 300)
  assert.equal(g2.tokens_out, 7)
  assert.deepEqual(v.trace.filter(e => e.role.startsWith('g1')).map(e => e.findings), [[], []])
})

test('g1/escalate prompts pass --attempt', async () => {
  const prompts = {}
  let n = 0
  const { agent: base } = mockAgent(() => (++n <= 2 ? fail('G1', 'lib/a.dart', `rule${n}`) : pass('G1')))
  const agent = (p, o) => { prompts[o.label] = p; return base(p, o) }
  const r = await implement({ args: baseArgs([{ id: 'T1', complexity: 'S' }]), agent })
  assert.equal(r.status, 'done')
  assert.match(prompts['g1:T1#1'], /--role g1 --task T1 --attempt 1 --tier haiku /)
  assert.match(prompts['g1:T1#2'], /--role g1 --task T1 --attempt 2 --tier haiku /)
  assert.match(prompts['g1:T1#3'], /--role g1 --task T1 --attempt 3 --tier sonnet /)
  assert.match(prompts['rollback:T1'], /--role escalate --task T1 --attempt 2 --tier sonnet /)
})

test('dev prompt registers the task checkpoint in the start event', async () => {
  const prompts = []
  const agent = async (p, o) => {
    if (o.label.startsWith('dev')) { prompts.push(p); return { status: 'done', summary: 's', files_changed: ['lib/a.dart'] } }
    if (o.label.startsWith('g0')) return pass('G0')
    return pass('G1')
  }
  await implement({ args: baseArgs([{ id: 'T1', complexity: 'S' }]), agent })
  assert.match(prompts[0], /--role dev --task T1 --attempt 1 --tier haiku --verdict start --checkpoint cp0/)
})

test('dev without structured result: gates judge the diff and the task can still pass', async () => {
  const agent = async (_p, o) => {
    if (o.label.startsWith('dev')) throw new Error('subagent completed without calling StructuredOutput')
    if (o.label.startsWith('g0')) return { ...pass('G0'), changed_files: ['lib/a.dart'] }
    if (o.label.startsWith('g1')) return pass('G1')
    throw new Error(`unexpected ${o.label}`)
  }
  const r = await implement({ args: baseArgs([{ id: 'T1', complexity: 'S' }]), agent })
  assert.equal(r.status, 'done')
  assert.deepEqual(r.tasks[0].files_changed, ['lib/a.dart'])
})

test('dev without structured result and no changes counts as a failed attempt and escalates', async () => {
  const calls = []
  const agent = async (_p, o) => {
    calls.push(o.label)
    if (o.label.startsWith('dev') && o.label.includes('@haiku')) throw new Error('no structured output')
    if (o.label.startsWith('dev')) return { status: 'done', summary: 's', files_changed: ['lib/a.dart'] }
    if (o.label.startsWith('g0')) return { ...pass('G0'), changed_files: calls.some(c => c.includes('@sonnet')) ? ['lib/a.dart'] : [] }
    if (o.label.startsWith('g1')) return pass('G1')
    if (o.label.startsWith('rollback')) return { ok: true, output: 'restored 0 path(s)' }
    throw new Error(`unexpected ${o.label}`)
  }
  const r = await implement({ args: baseArgs([{ id: 'T1', complexity: 'S' }]), agent })
  assert.equal(r.status, 'done')
  assert.equal(r.tasks[0].tier, 'sonnet')
})

test('verify with skip_g2 never spawns the QA agent', async () => {
  const labels = []
  const agent = async (_p, o) => { labels.push(o.label); return { gate: 'G1', verdict: 'pass', findings: [] } }
  const r = await verify({ args: { ...baseArgs([{ id: 'T1', tier: 'sonnet', files_changed: ['lib/a.dart'] }]), base_checkpoint: 'cp0', skip_g2: true }, agent })
  assert.equal(r.status, 'verified')
  assert.ok(!labels.some(l => l.startsWith('g2')))
})

test('the next task checkpoint is the file gate_g0 wrote, never the relayed sha', async () => {
  const prompts = []
  const agent = async (p, o) => {
    if (o.label.startsWith('dev')) { prompts.push(p); return { status: 'done', summary: 's', files_changed: ['lib/a.dart'] } }
    if (o.label.startsWith('g0')) return { ...pass('G0'), snapshot: 'corrupted-by-relay' }
    return pass('G1')
  }
  const r = await implement({ args: baseArgs([{ id: 'T1', complexity: 'S' }, { id: 'T2', complexity: 'S' }]), agent })
  assert.match(prompts[1], /--checkpoint @\/d\/checkpoints\/T1\.tree/)
  assert.equal(r.checkpoint, '@/d/checkpoints/T2.tree')
  assert.ok(!prompts.join('\n').includes('corrupted-by-relay'))
})

test('verify G2 prompt uses stack.g2_runtime when present and the dart MCP text otherwise', async () => {
  const run = async stack => {
    let prompt = ''
    const agent = async (p, o) => {
      if (o.label.startsWith('g2')) { prompt = p; return { gate: 'G2', verdict: 'pass', criteria: [], findings: [] } }
      return pass('G1')
    }
    await verify({ args: { ...baseArgs([{ id: 'T1', tier: 'sonnet', files_changed: ['a.go'] }]), base_checkpoint: 'cp0', stack }, agent })
    return prompt
  }
  const withRuntime = await run({ ...STACK, g2_runtime: 'RUNTIME-GENERICO-GO' })
  assert.ok(withRuntime.includes('RUNTIME-GENERICO-GO'))
  assert.ok(!withRuntime.includes('dart MCP'))
  const without = await run(STACK)
  assert.ok(without.includes('dart MCP'))
})
