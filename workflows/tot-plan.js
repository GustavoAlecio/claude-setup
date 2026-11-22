export const meta = {
  name: 'tot-plan',
  description: 'Tree of Thoughts orquestrado para o /plan: 3 planos por ângulos distintos, 2 juízes independentes, síntese no plan.md',
  whenToUse: 'Invocado pela skill /plan quando a feature é de risco alto, mexe em contrato/módulo novo ou pede ADR.',
  phases: [
    { title: 'Branch', detail: '3 planejadores independentes', model: 'opus' },
    { title: 'Judge', detail: '2 juízes pontuam os 3 planos', model: 'opus' },
    { title: 'Synthesize', detail: 'escreve o plan.md a partir do vencedor', model: 'opus' },
  ],
}

const A = args || {}
const ANGLES = A.angles || [
  ['reuse-first', 'Maximize reuso do que já existe no codebase; a menor mudança estrutural que entrega os critérios.'],
  ['risk-first', 'Ataque primeiro o maior risco técnico (contrato, concorrência, estado, real-time); isole o desconhecido.'],
  ['testability-first', 'Desenhe para verificabilidade: fronteiras que permitem teste de unidade e widget sem mocks frágeis.'],
]

const CANDIDATE = {
  type: 'object',
  required: ['angle', 'plan_md', 'key_decisions', 'risks', 'files_impacted'],
  properties: {
    angle: { type: 'string' },
    plan_md: { type: 'string' },
    key_decisions: {
      type: 'array',
      items: { type: 'object', required: ['title', 'choice', 'alternatives', 'rationale'], properties: {
        title: { type: 'string' }, choice: { type: 'string' }, alternatives: { type: 'array', items: { type: 'string' } }, rationale: { type: 'string' },
      } },
    },
    risks: { type: 'array', items: { type: 'string' } },
    files_impacted: { type: 'integer' },
  },
}
const SCORES = {
  type: 'object',
  required: ['scores', 'winner', 'verified_claims'],
  properties: {
    scores: {
      type: 'array',
      items: { type: 'object', required: ['candidate', 'fit', 'risk', 'simplicity', 'testability', 'total', 'rationale'], properties: {
        candidate: { type: 'integer' }, fit: { type: 'integer' }, risk: { type: 'integer' }, simplicity: { type: 'integer' },
        testability: { type: 'integer' }, total: { type: 'integer' }, rationale: { type: 'string' },
      } },
    },
    winner: { type: 'integer' },
    verified_claims: {
      type: 'array',
      items: { type: 'object', required: ['candidate', 'claim', 'evidence', 'holds'], properties: {
        candidate: { type: 'integer' }, claim: { type: 'string' }, evidence: { type: 'string' }, holds: { type: 'boolean' },
      } },
    },
    graft: {
      type: 'array',
      items: { type: 'object', required: ['from_candidate', 'idea'], properties: { from_candidate: { type: 'integer' }, idea: { type: 'string' } } },
    },
  },
}
const SYNTH = {
  type: 'object',
  required: ['written', 'adr_candidates', 'grafts_applied'],
  properties: {
    written: { type: 'boolean' },
    adr_candidates: { type: 'array', items: CANDIDATE.properties.key_decisions.items },
    grafts_applied: {
      type: 'array',
      items: { type: 'object', required: ['idea', 'applied', 'reason'], properties: { idea: { type: 'string' }, applied: { type: 'boolean' }, reason: { type: 'string' } } },
    },
  },
}

const base = `Repo: ${A.project_path}
Spec aprovada: ${A.spec_path}
Rules: ${A.project_path}/${A.rules_dir} · ADRs aceitos: ${A.project_path}/${A.adr_dir}/INDEX.md${A.lessons_path ? ` · Lessons: ${A.lessons_path}` : ''}
Mapa da org: se existir .map/index.md em ${A.project_path} ou numa pasta acima (nunca abaixo), leia o índice e as notas/gerados relevantes antes de buscar no código; nota STALE não é confiável; o mapa descreve origin/development.
Template obrigatório do plano: seção 7 de ~/.claude/skills/plan/SKILL.md (mesmas seções, mesmo limite de itens), incluindo a seção "Decisões" com ADRs citados.`

phase('Branch')
const candidates = (await parallel(ANGLES.map(([angle, brief]) => () =>
  agent(`${base}

Você é um dos três planejadores independentes. Ângulo: ${angle} — ${brief}
Explore o código real antes de planejar (convenções, componentes reutilizáveis, contratos). Não escreva arquivos.
Devolva o plano completo em plan_md e as decisões-chave com as alternativas que descartou.`,
    { label: `plan:${angle}`, phase: 'Branch', model: 'opus', effort: 'high', schema: CANDIDATE })))).filter(Boolean)

if (candidates.length < 2) return { status: 'failed', reason: 'not_enough_candidates', candidates: candidates.length }

const listing = candidates.map((c, i) => `### Candidato ${i + 1} — ${c.angle}\n${c.plan_md}\n\nDecisões: ${JSON.stringify(c.key_decisions)}\nRiscos: ${JSON.stringify(c.risks)}`).join('\n\n---\n\n')
const n = candidates.length
const PERSONAS = ['staff-engineer cético com custo de manutenção', 'tech lead focado em entrega e risco de regressão']

phase('Judge')
const judgeRuns = await parallel(PERSONAS.map((persona, j) => () =>
  agent(`${base}

Você é juiz ${j + 1} (${persona}). Há ${n} candidatos, numerados de 1 a ${n}; identifique-os pelo número em candidate/winner/from_candidate.
Pontue cada candidato de 1 a 5 em: fit com o codebase e ADRs, risco, simplicidade, testabilidade. Em todas, nota maior = melhor (risco 5 = risco mais baixo). total = soma.
Verifique no código as afirmações que pesam na nota — não confie no texto do candidato. Registre cada verificação em verified_claims com evidence em arquivo:linha e se a afirmação se sustenta.
Aponte em graft as ideias de perdedores que valem enxertar no vencedor.

${listing}`,
    { label: `judge:${j + 1}`, phase: 'Judge', model: 'opus', effort: 'high', schema: SCORES })))

const judges = judgeRuns.map((r, j) => r && { persona: PERSONAS[j], ...r }).filter(Boolean)
if (!judges.length) return { status: 'failed', reason: 'no_judges', candidates: candidates.map(c => c.angle) }

const totals = candidates.map(() => 0)
const riskSums = candidates.map(() => 0)
for (const j of judges) {
  const seen = new Set()
  j.invalid_scores = 0
  for (const s of j.scores) {
    const i = s.candidate - 1
    if (!(i >= 0 && i < n) || seen.has(i)) { j.invalid_scores++; continue }
    seen.add(i)
    totals[i] += s.total
    riskSums[i] += s.risk
  }
  j.scored_all = seen.size === n
}

const order = candidates.map((_, i) => i).sort((a, b) => totals[b] - totals[a] || riskSums[b] - riskSums[a] || a - b)
const [w, runnerUp] = order
const tieBreak = runnerUp !== undefined && totals[w] === totals[runnerUp] ? (riskSums[w] !== riskSums[runnerUp] ? 'risk' : 'angle_order') : null
const winner = candidates[w].angle
const grafts = judges.flatMap(j => (j.graft || []).map(g => ({ ...g, from_angle: candidates[g.from_candidate - 1]?.angle, judge: j.persona })))

const byAngle = arr => Object.fromEntries(candidates.map((c, i) => [c.angle, arr[i]]))
const spread = judges.length === 2 ? candidates.map((_, i) => {
  const pick = j => j.scores.find(s => s.candidate === i + 1)?.total
  const [a, b] = judges.map(pick)
  return a === undefined || b === undefined ? null : Math.abs(a - b)
}) : null
const agreement = {
  same_winner: judges.length === 2 ? judges[0].winner === judges[1].winner : null,
  total_spread: spread && byAngle(spread),
  claims_checked: judges.map(j => j.verified_claims.length),
  claims_refuted: judges.map(j => j.verified_claims.filter(c => !c.holds).length),
}
const degraded = judges.length < PERSONAS.length || judges.some(j => !j.scored_all || j.invalid_scores > 0)
log(`vencedor: ${winner} (${JSON.stringify(byAngle(totals))})${tieBreak ? ` desempate=${tieBreak}` : ''}${degraded ? ' [degraded]' : ''}`)

phase('Synthesize')
const synth = await agent(`${base}

Sintetize o plano final a partir do candidato vencedor "${winner}" (candidato ${w + 1}), avaliando os enxertos indicados pelos juízes:
${JSON.stringify(grafts)}

Para cada enxerto, registre em grafts_applied se aplicou e por quê (aplique só o que melhora o vencedor sem contradizê-lo).
Escreva o resultado em ${A.plan_path} seguindo o template. Na seção "Decisões", liste cada decisão-chave com as alternativas consideradas (dos ${n} candidatos) — elas viram ADRs propostos.

Candidatos:
${listing}

Notas dos juízes: ${JSON.stringify(judges.map(j => ({ persona: j.persona, scores: j.scores })))}`,
  { label: 'synthesize', phase: 'Synthesize', model: 'opus', effort: 'high', schema: SYNTH })

return {
  status: synth && synth.written ? 'written' : 'failed',
  winner,
  totals: byAngle(totals),
  tie_break: tieBreak,
  degraded,
  agreement,
  judges: judges.map(j => ({ persona: j.persona, winner_angle: candidates[j.winner - 1]?.angle, scored_all: j.scored_all, invalid_scores: j.invalid_scores, scores: j.scores.map(s => ({ ...s, angle: candidates[s.candidate - 1]?.angle })), verified_claims: j.verified_claims, graft: j.graft || [] })),
  grafts_applied: synth ? synth.grafts_applied : [],
  candidates: candidates.map(c => ({ angle: c.angle, files_impacted: c.files_impacted, key_decisions: c.key_decisions, risks: c.risks, plan_md: c.plan_md })),
  adr_candidates: synth ? synth.adr_candidates : [],
}
