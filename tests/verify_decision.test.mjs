import { test } from 'node:test'
import assert from 'node:assert/strict'
import { loadWorkflow, STACK, pass } from './harness.mjs'

const verify = loadWorkflow('smart-verify')
const tasks = [{ id: 'T1', tier: 'sonnet', files_changed: ['lib/a.dart'] }]
const args = extra => ({ project_path: '/r', run_dir: '/d', stack: STACK, checkpoint: 'cp0', base_checkpoint: 'cp0', revision_start: '@/d/rev.tree', plan_path: 'p', spec_path: 's', tasks, ...extra })
const ok = (criterion = 'c1') => ({ criterion, status: 'PASS', evidence: 'test/a_test.dart passou' })
const g2 = (verdict, criteria, findings = []) => ({ gate: 'G2', verdict, criteria, findings, evidence: ['flutter test test/a_test.dart'] })

async function run({ g1 = () => pass('G1'), qa, extra = {}, workflow }) {
  const calls = []
  const agent = async (_p, o) => {
    calls.push(o.label)
    return o.label.startsWith('g1') ? g1(o.label) : typeof qa === 'function' ? qa(o.label) : qa
  }
  const r = await verify({ args: args(extra), agent, workflow })
  return { r, calls }
}

test('AC-01: G2 fail with no findings is never verified', async () => {
  const { r } = await run({ qa: g2('fail', [ok()]) })
  assert.equal(r.status, 'unverified')
  assert.equal(r.decision.reason_code, 'G2_FAIL')
})

test('AC-02: G2 pass does not override FAIL or PARTIAL criteria, and they are listed', async () => {
  for (const st of ['FAIL', 'PARTIAL']) {
    const { r } = await run({ qa: g2('pass', [ok(), { criterion: 'c2', status: st, evidence: 'e' }]) })
    assert.equal(r.status, 'unverified')
    assert.ok(r.decision.reasons.includes('CRITERIA_FAILED'))
    assert.deepEqual(r.decision.criteria_failed, [{ criterion: 'c2', status: st }])
  }
})

test('AC-03: all criteria UNTESTABLE is not evidence', async () => {
  const { r } = await run({ qa: g2('pass', [{ criterion: 'c1', status: 'UNTESTABLE', evidence: 'sem device' }]) })
  assert.equal(r.status, 'unverified')
  assert.ok(r.decision.reasons.includes('CRITERIA_UNTESTED'))
  assert.ok(r.decision.reasons.includes('NO_POSITIVE_EVIDENCE'))
})

test('a required UNTESTABLE criterion blocks verified even when others pass', async () => {
  const { r } = await run({ qa: g2('pass', [ok(), { criterion: 'c2', status: 'UNTESTABLE', evidence: 'x' }]) })
  assert.equal(r.status, 'unverified')
  assert.deepEqual(r.decision.criteria_untestable, ['c2'])
})

test('PASS without evidence counts as untested', async () => {
  const { r } = await run({ qa: g2('pass', [{ criterion: 'c1', status: 'PASS', evidence: ' ' }]) })
  assert.equal(r.status, 'unverified')
  assert.equal(r.decision.criteria.passed, 0)
})

test('AC-04: zero criteria is a coverage error', async () => {
  const { r } = await run({ qa: g2('pass', []) })
  assert.equal(r.status, 'unverified')
  assert.equal(r.decision.reason_code, 'NO_CRITERIA')
})

test('AC-05: skip_g2 is QA_SKIPPED and never spawns QA', async () => {
  const { r, calls } = await run({ qa: null, extra: { skip_g2: true } })
  assert.equal(r.status, 'unverified')
  assert.equal(r.decision.reason_code, 'QA_SKIPPED')
  assert.equal(r.decision.g2.verdict, 'skipped')
  assert.ok(!calls.some(c => c.startsWith('g2')))
})

test('AC-06: G2 inconclusive (after the opus retry), absent or malformed is not verified', async () => {
  const inc = await run({ qa: g2('inconclusive', [ok()]) })
  assert.equal(inc.r.status, 'unverified')
  assert.equal(inc.r.decision.reason_code, 'G2_INCONCLUSIVE')
  assert.deepEqual(inc.calls.filter(c => c.startsWith('g2')), ['g2:r1', 'g2:r1:opus'])

  const absent = await run({ qa: null })
  assert.equal(absent.r.status, 'blocked')
  assert.equal(absent.r.decision.reason_code, 'G2_NOT_RUN')

  for (const bad of [{ gate: 'G2', verdict: 'ok', criteria: [ok()], findings: [] }, { gate: 'G2', verdict: 'pass', findings: [] },
    g2('pass', [{ criterion: 'c1', status: 'MAYBE', evidence: 'e' }])]) {
    const { r } = await run({ qa: bad })
    assert.equal(r.status, 'unverified')
    assert.ok(r.decision.reasons.includes('G2_MALFORMED'), JSON.stringify(r.decision.reasons))
  }
})

test('AC-07: blocking or inconclusive G1 is not approved even when G2 passes', async () => {
  const inc = await run({ g1: () => ({ gate: 'G1', verdict: 'inconclusive', findings: [] }), qa: g2('pass', [ok()]) })
  assert.equal(inc.r.status, 'unverified')
  assert.equal(inc.r.decision.reason_code, 'G1_INCONCLUSIVE')

  const failNoFindings = await run({ g1: () => ({ gate: 'G1', verdict: 'fail', findings: [] }), qa: g2('pass', [ok()]) })
  assert.equal(failNoFindings.r.status, 'unverified')
  assert.equal(failNoFindings.r.decision.reason_code, 'G1_FAIL')

  const down = await run({ g1: l => (l.includes('dart') ? null : pass('G1')), qa: g2('pass', [ok()]) })
  assert.equal(down.r.status, 'blocked')
  assert.equal(down.r.decision.reason_code, 'G1_NOT_RUN')

  const rounds = await run({
    g1: () => ({ gate: 'G1', verdict: 'fail', findings: [{ id: 'F', severity: 'major', file: 'lib/a.dart', message: 'm' }] }),
    qa: g2('pass', [ok()]),
    extra: { max_rounds: 0 },
  })
  assert.equal(rounds.r.status, 'blocked')
  assert.equal(rounds.r.decision.reason_code, 'VERIFY_ROUNDS_EXHAUSTED')
  assert.equal(rounds.r.decision.blocking_findings.length, 2)
})

test('a malformed G2 with blocking findings stops instead of reentering', async () => {
  let reentered = false
  const { r } = await run({ qa: g2('fail', [], [{ id: 'Q', severity: 'major', file: 'lib/a.dart', message: 'm' }]), workflow: async () => { reentered = true; return null } })
  assert.equal(r.status, 'unverified')
  assert.equal(r.decision.reason_code, 'G2_FAIL')
  assert.ok(r.decision.reasons.includes('NO_CRITERIA'))
  assert.equal(reentered, false)
})

test('AC-08 / AC-16: everything passing is verified with counts, gates, refs and revision', async () => {
  const { r } = await run({ qa: g2('pass', [ok('c1'), ok('c2')], [{ id: 'N', severity: 'minor', file: 'lib/a.dart', message: 'nit' }]) })
  assert.equal(r.status, 'verified')
  const d = r.decision
  assert.equal(d.reason_code, 'VERIFIED')
  assert.deepEqual(d.reasons, [])
  assert.deepEqual(d.criteria, { total: 2, passed: 2, failed: 0, partial: 0, untestable: 0 })
  assert.deepEqual(d.gates_run, ['G1', 'G1', 'G2'])
  assert.deepEqual(d.evidence_refs, ['flutter test test/a_test.dart'])
  assert.deepEqual(d.blocking_findings, [])
  assert.equal(d.human_override, false)
  assert.equal(d.repo, '/r')
  assert.equal(d.revision_start, '@/d/rev.tree')
})
