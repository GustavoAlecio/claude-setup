import { test } from 'node:test'
import assert from 'node:assert/strict'
import { loadWorkflow } from './harness.mjs'

const tot = loadWorkflow('tot-plan')
const sc = (candidate, total, risk) => ({ candidate, fit: 1, risk, simplicity: 1, testability: 1, total, rationale: 'r' })
const judge = (scores, winner) => ({ scores, winner, verified_claims: [{ candidate: 1, claim: 'c', evidence: 'a.ts:1', holds: false }], graft: [{ from_candidate: 3, idea: 'i' }] })

function run(judges) {
  const agent = async (_p, o) => {
    if (o.label.startsWith('plan:')) return { angle: o.label.slice(5), plan_md: 'p', key_decisions: [], risks: [], files_impacted: 3 }
    if (o.label.startsWith('judge:')) return judges[+o.label.slice(6) - 1]
    if (o.label === 'synthesize') return { written: true, adr_candidates: [], grafts_applied: [{ idea: 'i', applied: true, reason: 'r' }] }
    throw new Error(`unexpected agent ${o.label}`)
  }
  return tot({ args: { project_path: '/r', plan_path: 'p' }, agent })
}

test('totals sum both judges by candidate index and expose the audit trail', async () => {
  const r = await run([judge([sc(1, 10, 2), sc(2, 15, 3), sc(3, 12, 3)], 2), judge([sc(1, 11, 2), sc(2, 14, 3), sc(3, 12, 3)], 2)])
  assert.equal(r.status, 'written')
  assert.equal(r.winner, 'risk-first')
  assert.deepEqual(r.totals, { 'reuse-first': 21, 'risk-first': 29, 'testability-first': 24 })
  assert.equal(r.tie_break, null)
  assert.equal(r.degraded, false)
  assert.equal(r.agreement.same_winner, true)
  assert.deepEqual(r.agreement.claims_refuted, [1, 1])
  assert.equal(r.judges[0].scores[1].angle, 'risk-first')
  assert.equal(r.candidates.length, 3)
  assert.equal(r.grafts_applied.length, 1)
})

test('a tie is broken by the risk score, then by angle order', async () => {
  const byRisk = await run([judge([sc(1, 12, 2), sc(2, 12, 4), sc(3, 5, 1)], 1), judge([sc(1, 12, 2), sc(2, 12, 4), sc(3, 5, 1)], 2)])
  assert.equal(byRisk.winner, 'risk-first')
  assert.equal(byRisk.tie_break, 'risk')
  const byOrder = await run([judge([sc(1, 12, 3), sc(2, 12, 3), sc(3, 5, 1)], 1), judge([sc(1, 12, 3), sc(2, 12, 3), sc(3, 5, 1)], 2)])
  assert.equal(byOrder.winner, 'reuse-first')
  assert.equal(byOrder.tie_break, 'angle_order')
})

test('out-of-range or duplicate indices are dropped and flag the run as degraded', async () => {
  const r = await run([judge([sc(1, 10, 2), sc(9, 20, 5), sc(3, 12, 3), sc(3, 15, 3)], 3), null])
  assert.equal(r.winner, 'testability-first')
  assert.equal(r.totals['risk-first'], 0)
  assert.equal(r.judges[0].invalid_scores, 2)
  assert.equal(r.judges[0].scored_all, false)
  assert.equal(r.degraded, true)
  assert.equal(r.agreement.same_winner, null)
})

test('without any judge the workflow fails instead of picking the first candidate', async () => {
  const r = await run([null, null])
  assert.equal(r.status, 'failed')
  assert.equal(r.reason, 'no_judges')
})
