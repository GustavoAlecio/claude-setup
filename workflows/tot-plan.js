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
  required: ['scores', 'winner'],
  properties: {
    scores: {
      type: 'array',
      items: { type: 'object', required: ['angle', 'fit', 'risk', 'simplicity', 'testability', 'total', 'rationale'], properties: {
        angle: { type: 'string' }, fit: { type: 'integer' }, risk: { type: 'integer' }, simplicity: { type: 'integer' },
        testability: { type: 'integer' }, total: { type: 'integer' }, rationale: { type: 'string' },
      } },
    },
    winner: { type: 'string' },
    graft: { type: 'array', items: { type: 'string' } },
  },
}
const SYNTH = {
  type: 'object',
  required: ['written', 'winner', 'adr_candidates'],
  properties: {
    written: { type: 'boolean' },
    winner: { type: 'string' },
    adr_candidates: { type: 'array', items: CANDIDATE.properties.key_decisions.items },
  },
}

const base = `Repo: ${A.project_path}
Spec aprovada: ${A.spec_path}
Rules: ${A.project_path}/${A.rules_dir} · ADRs aceitos: ${A.project_path}/${A.adr_dir}/INDEX.md${A.lessons_path ? ` · Lessons: ${A.lessons_path}` : ''}
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

phase('Judge')
const judges = (await parallel(['staff-engineer cético com custo de manutenção', 'tech lead focado em entrega e risco de regressão'].map((persona, j) => () =>
  agent(`${base}

Você é juiz ${j + 1} (${persona}). Pontue cada candidato de 1 a 5 em: fit com o codebase e ADRs, risco, simplicidade, testabilidade. total = soma.
Verifique no código as afirmações que pesam na nota — não confie no texto do candidato. Aponte em graft as ideias de perdedores que valem enxertar no vencedor.

${listing}`,
    { label: `judge:${j + 1}`, phase: 'Judge', model: 'opus', effort: 'high', schema: SCORES })))).filter(Boolean)

const totals = {}
for (const j of judges) for (const s of j.scores) totals[s.angle] = (totals[s.angle] || 0) + s.total
const winner = Object.keys(totals).sort((a, b) => totals[b] - totals[a])[0] || candidates[0].angle
const grafts = judges.flatMap(j => j.graft || [])
log(`vencedor: ${winner} (${JSON.stringify(totals)})`)

phase('Synthesize')
const synth = await agent(`${base}

Sintetize o plano final a partir do candidato vencedor "${winner}", enxertando só o que os juízes indicaram:
${JSON.stringify(grafts)}

Escreva o resultado em ${A.plan_path} seguindo o template. Na seção "Decisões", liste cada decisão-chave com as alternativas consideradas (dos 3 candidatos) — elas viram ADRs propostos.

Candidatos:
${listing}

Notas dos juízes: ${JSON.stringify(judges.map(j => j.scores))}`,
  { label: 'synthesize', phase: 'Synthesize', model: 'opus', effort: 'high', schema: SYNTH })

return { status: synth && synth.written ? 'written' : 'failed', winner, totals, grafts, adr_candidates: synth ? synth.adr_candidates : [] }
