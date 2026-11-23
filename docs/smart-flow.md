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

`/auto` skips the confirmations between stages that depend on it (such as the kickoff classification). It does not decide the `spec`, `plan`, `tasks` and `pr` gates: `wf-report.py gate` does, from the report (see Decision gates). It never auto-decides a `BLOQUEANTE` challenge, a `backtrack` or a `blocked` run.

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

The verify outcome is decided by code (`decide` in `smart-verify.js`), never by an agent, and fails closed: `verified` needs every G1 reviewer at `pass`, G2 at `pass`, at least one criterion PASS with evidence, no FAIL/PARTIAL/UNTESTABLE criterion and no open `critical`/`major` finding. Anything else is `unverified` (or `blocked` when a gate did not run) with a `reason_code` (`G2_FAIL`, `CRITERIA_FAILED`, `CRITERIA_UNTESTED`, `NO_CRITERIA`, `QA_SKIPPED`, `G2_INCONCLUSIVE`, `G2_MALFORMED`, …). `skip_g2` is always `unverified`. `wf-event.py persist` pins the result to the tree it judged (`revision_start` vs. the tree at persist); a tree that moved is `REVISION_CHANGED`.

`/complete` and `archive-cycle.sh completed` both run `wf_gate.py complete-check`: the last verify must be `verified` for the tree on disk (re-derived from the raw gate report), or a human must have accepted that exact tree with `wf_gate.py accept-unverified --reason … --risk …`, confirmed in a macOS dialog. The record is kept in `exec.override` and `overrides.jsonl` and archived with `human_override: true`; it never turns into `verified`. An agent with shell access can still write `exec.override` by hand: the dialog stops an agent from approving through the tool, not from forging the file.

`/tasks` and `/implement` run `wf_gate.py tasks-check`, which rejects plans G0 cannot approve by construction: a Red-only task (ends with failing tests, or only writes a test a later task makes pass), a test no task creates, dependencies on later tasks.

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

## Decision gates

The `spec`, `plan`, `tasks` and `pr` gates are decision summaries, not document approvals. Before a gate, the skill drafts candidates, the `gate-critic` agent writes `$WF_DIR/.gate-<g>.json`, and `wf-report.py brief` validates it and stores it as the optional `stages[owner].gate` block of `report.json` (version 1; a report without a block is unchanged). The block carries `summary`, `risks`, `questions` (options with the author's and the critic's preference, and an optional `header` of up to 12 characters shown above the question in place of its id), `omitted` (what the cut dropped, always whole) and, in `pr`, the `why`/`anchor` of each point plus the `base` and `tree` it was judged against. Limits and the one-sentence rule are checked before any write, and the refusal text goes back to the critic once.

| Command | Does |
|---|---|
| `brief <g> --workflow-dir W --file JSON [--candidates FILE] [--tree @REF]` | validates and records the block, prints the rendered summary. `pr` requires `--tree` |
| `gate <g> --workflow-dir W` | prints `ask` or `skip` (the stop rule below); writes `passed` only on `skip` for an `open` plan/tasks block |
| `show <g> --workflow-dir W` | read-only: `{status, round, text_md, questions}` ready for `AskUserQuestion`; in `pr`, each pending question also carries `why`/`anchor` and `text_md` lists them under `Pontos:`; `{"status":"absent"}` without a block |
| `answer <g> --workflow-dir W (--question ID (--option ID \| --text-file MD) \| --text-file MD \| --approve \| --reject)` | records the answer; `--text-file` alone is the Adjust of the no-questions branch and moves the block to `revising` (up to a round limit, then the skill offers approve as is, go back or abort) |
| `reopen pr --workflow-dir W` | for every answer other than `ok` in a `revising` `pr` block, appends a pending `P<round>.<n>` task (risk high, tier0 opus, `affects` the anchor path) to `current.json` and `tasks.md`; idempotent by id, leaves `report.json` alone |

None of these archives `report.json`: a missing block or a report from another cycle is exit 2 and the file keeps its bytes. `gate` without `--workflow-dir` exits 2.

**Stop rule.** The `auto_mode.flag` is not read. `required` is `spec` and `pr`, plus whatever `~/.claude/workflow/gates.json` (`{"required": [...]}`) adds; an invalid or empty file means only `spec` and `pr`.

| Gate state | In `required` (`spec`, `pr`, or listed) | Not in `required` (`plan`, `tasks` by default) |
|---|---|---|
| no block, other cycle, no `current.json`/`report.json` | ask | ask |
| block `open` with an unanswered question | ask | ask |
| block `open`, every question answered | ask | skip, writes `passed` |
| `approved` or `passed` | skip | skip |
| any other status (`revising`, `rejected`) | ask | ask |

Unconditional stops (a blocking challenge, `backtrack`, `blocked`, an existing branch, a `release/*` base, reset, push) stay outside this table. `stage-start` on the owner stage drops the block unless it is `revising`, so the `pr` round pending a `reopen pr` survives the re-entry; the next `brief` records `round: 2` and moves the previous one to `history`.

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
  "g2_device": "auto"
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
- Flutter stack: `dart` / `flutter` on PATH (or `fvm`), the `dart-flutter` MCP server for G2 runtime checks, and a connected device for at least one platform of the app. With `g2_device: "auto"` the harness derives the G2 runtime targets from the repo: one per app root (`pubspec.yaml` + `lib/main.dart`, monorepo members included) and platform folder (`web/`, `macos/`, `ios/`, `android/`, `windows/`, `linux/`) that has a connected device; G2 validates on all of them. A fixed device id still works.

## When to use the full flow vs `/fix`

Use the **full flow** when the change spans several files or modules, involves design decisions, or you want a written record of intent and approach. Use **`/fix`** for a single-cause bug where the fix is obvious once the root cause is found.
