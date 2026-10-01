import { test } from 'node:test'
import assert from 'node:assert/strict'
import { loadWorkflow, STACK, pass, fail } from './harness.mjs'

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
