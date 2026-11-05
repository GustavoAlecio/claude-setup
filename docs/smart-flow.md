# Smart Flow

A staged workflow for non-trivial tasks. Planning stages are judgment work and run on a strong model with a human gate. Execution stages run as [dynamic workflows](https://code.claude.com/docs/en/workflows): each task starts on the cheapest model its complexity allows and escalates step by step when deterministic and LLM gates reject it.

```
kickoff ─► specify ─► challenge-spec ─► plan ─► tasks ─► implement ─► verify ─► complete
 (triage)   (HITL)     (adversarial)    (HITL,   (tier0    (ladder,     (G1+G2,    (ADRs, lessons,
                                         ToT)    per task)  G0+G1)       re-entry)   routing, archive)
                                          ▲                    │
                                          └── circuit breaker ─┘
```

| Stage | Runs as | Model | Output |
|---|---|---|---|
| `/specify` | skill | sonnet | `spec.md` |
| `/challenge-spec` | skill + `spec-challenger` agent | opus | spec fixes, rewritten acceptance criteria |
| `/plan` | skill, or `tot-plan` workflow | opus | `plan.md` (+ `tot-plan.json`) |
| `/tasks` | skill | sonnet | `tasks.md`, `current.json.tasks` with `tier0`, `tests`, `affects`, `risk` |
| `/implement` | `smart-implement` workflow | ladder | code, `runs/<id>/` |
| `/verify` | `smart-verify` workflow | opus / sonnet | verify report, re-entry runs |
| `/complete` | skill | sonnet | proposed ADRs, lessons, `routing.json`, archived cycle |

`/auto` removes the approval gates between stages. It never auto-decides a `BLOQUEANTE` challenge, a `backtrack` or a `blocked` run.

## The model ladder

```
tier0 = f(complexity, risk)      S → haiku   M → sonnet   L → opus      risk: high → one step up (max opus)

┌─► dev-implementer @ tier ──► G0 deterministic ──► G1 architecture ──► pass → next task
│                               format, codegen,     task diff vs rules,
│                               analyze, task tests  ADRs, plan
│                                     │ fail               │ fail
│                                     └─────────┬──────────┘
│                                   retry on the same tier (fix in place, with findings)
│                                   2 attempts on a tier, or no progress → escalate:
│                                   restore checkpoint, restart fresh on the next tier
└──────────────────────────── haiku → sonnet → opus → fable → blocked (ToT diagnosis)
```

Rules the workflow enforces in code, not in a prompt:

- **Retry vs. escalate.** A retry on the same tier keeps the diff and fixes the reported findings. An escalation restores the task checkpoint and the next model starts clean, with a summary of what the previous one got wrong.
- **No progress means escalate.** If a retry has as many blocking findings as the attempt before it, the ladder moves up early.
- **Circuit breaker.** If the same finding (`gate:file:rule_ref`) is still open after two different tiers, the problem is the spec or the plan, not model capability. The run stops instead of paying for the next tier.
- **Caps.** 5 attempts per task in total, 2 per tier (`max_attempts`, `per_tier`).
- **Verifiers are never weaker than implementers.** G1 runs on `max(opus, implementer tier)`. G2 runs on sonnet and is re-run on opus when it comes back `inconclusive`.
- **Only `critical`/`major` block.** `minor`/`nit` are reported and never enter the loop.

When a task is blocked, three independent `opus` agents diagnose it through different lenses (spec, plan, environment) and return ranked hypotheses with a recommended action. The human decides what happens next.

## Gates

| Gate | When | What | Who judges |
|---|---|---|---|
| **G0** | every attempt | autofix format, run codegen when `part` files are involved, analyze the changed files, run the task's tests (one flaky retry) | `bin/gate_g0.py`; the haiku agent only runs it and relays the JSON |
| **G1** (task) | G0 passed | the task diff against `.claude/rules/`, matching ADRs, the plan and `CLAUDE.md` | the stack's `g1_task_reviewer` agent |
| **G1** (cycle) | `/verify` | the whole cycle diff, one agent per reviewer in the stack profile; looks for cross-task problems | `g1_reviewers` |
| **G2** | `/verify` | each acceptance criterion: PASS / PARTIAL / FAIL / UNTESTABLE, using tests plus the running app (dart MCP: `launch_app`, `flutter_driver`, `get_runtime_errors`) | `qa-flutter` |

When `/verify` fails, findings go back to the task that touched the file. Findings with no owner become a new task, `V<round>`. These re-enter `smart-implement` and keep the tier each task already reached. There are at most 2 verify rounds.

All gates return the same verdict shape:

```json
{
  "gate": "G1",
  "verdict": "pass | fail | inconclusive",
  "findings": [{ "id": "…", "severity": "critical|major|minor|nit", "file": "lib/…", "line": 42,
                 "rule_ref": ".claude/rules/bloc.md | docs/adr/0007-… | lint_code", "message": "…", "fix_hint": "…" }],
  "evidence": ["…"]
}
```

## Checkpoints

`bin/wf-checkpoint.sh` snapshots the working tree as a git **tree object**, using a temporary index: no commit, no ref, no stash, and the real index is never touched. `restore` reverts only the paths that changed since the snapshot. G0 returns the post-autofix tree, which becomes the checkpoint for the next task. The cycle's first tree (`exec.base_checkpoint`) is what `/verify` diffs against.

## Stack profiles

`stacks/<name>.json` tells the workflow how a stack is gated. `/implement` picks the profile whose `detect` file exists at the repo root.

```json
{
  "detect": ["pubspec.yaml"],
  "autofix": [["dart", "format", "{files}"]],
  "codegen": { "when_regex": "^part '.*\\.(freezed|g)\\.dart';", "cmd": ["dart", "run", "build_runner", "build", "--delete-conflicting-outputs"] },
  "analyze": { "cmd": ["dart", "analyze", "--format=machine", "{files}"], "parser": "dart_machine" },
  "test": { "cmd": ["flutter", "test", "{files}"], "flaky_retries": 1 },
  "g1_task_reviewer": "flutter-architecture",
  "g1_reviewers": ["flutter-architecture", "flutter-correctness", "dart-correctness"],
  "g2_agent": "qa-flutter",
  "g2_device": "macos"
}
```

Commands run from the nearest package root, so melos/monorepos work. `fvm` is prefixed automatically when the repo has `.fvmrc`. Adding a stack takes a profile, the analyzer parser in `gate_g0.py` and a QA agent. The workflows don't change.

## Project memory

| Layer | Where | Lifecycle | Read by |
|---|---|---|---|
| Rules | `<repo>/.claude/rules/*.md` (with `paths:`) | curated | dev-implementer, G1 |
| ADRs | `<repo>/docs/adr/NNNN-*.md` + `INDEX.md` | immutable; changed only by superseding | `/plan`, dev-implementer, G1, spec-challenger, matched on `affects` globs |
| Lessons | `~/.claude/projects/<project>/lessons.md` | appended by `/complete` from findings that failed 2+ attempts | every stage |
| Routing | `~/.claude/projects/<project>/routing.json` | written by `routing-stats.py` | `/tasks` (tier0 overrides) |

ADRs use frontmatter (`status`, `affects`, `supersedes`, `superseded_by`) and `[[wikilinks]]`, so `docs/` opens as an Obsidian vault with a working graph. `bin/adr-index.py match` is what keeps the graph useful to agents: they only ever read the accepted ADRs whose `affects` globs match the files they touch.

## Tree of Thoughts planning

`/plan` switches to the `tot-plan` workflow when any of these holds: `--tot` is passed, a contract changes (API, gRPC, WebSocket, schema), a new module is added, more than 8 files are impacted, or the spec calls for a structural decision. Three planners work independently (reuse-first, risk-first, testability-first), two judges score the plans against the code, and a synthesizer writes `plan.md` from the winner, grafting in what the judges flagged. The discarded alternatives become ADR candidates.

## Telemetry

Each run writes to `~/.claude/workflow/<project>/runs/<run-id>/`:

- `events.jsonl`: the live, best-effort stream (G0 writes it deterministically; agents append start/end).
- `trace.jsonl` + `result.json`: the canonical record the workflow returns, persisted by the skill.

`bin/routing-stats.py` aggregates every run, active and archived, into tier0 pass rates per complexity × risk. It suggests overrides once a bucket has at least 5 samples and passes on tier0 less than half the time.

## Requirements

- Claude Code with dynamic workflows enabled (`/config` → Dynamic workflows).
- `python3`, `git`, `node` (tests only).
- Flutter stack: `dart` / `flutter` on PATH (or `fvm`), the `dart-flutter` MCP server for G2 runtime checks, and the `g2_device` target enabled in the app.

## When to use the full flow vs `/fix`

Use the **full flow** when the change spans several files or modules, involves design decisions, or you want a written record of intent and approach. Use **`/fix`** for a single-cause bug where the fix is obvious once the root cause is found.
