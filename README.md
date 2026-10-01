# claude-setup

My personal [Claude Code](https://claude.com/claude-code) configuration — skills, agents, workflows and helper scripts I use across projects.

> Opinionated, shared as-is. Borrow what's useful, ignore what isn't.

## What's inside

### Skills (`skills/`)

| Skill | Purpose |
|---|---|
| **Smart Flow** (`specify`, `challenge-spec`, `plan`, `tasks`, `implement`, `verify`, `complete`) | Spec-driven pipeline where execution runs as workflows with a model-escalation ladder (haiku → sonnet → opus → fable) and deterministic + LLM gates — see [docs/smart-flow.md](docs/smart-flow.md) |
| `adr` | Architecture Decision Records in `docs/adr/` — immutable, `affects` globs, supersede chain, Obsidian-friendly index |
| `auto` | Toggle the Smart Flow autopilot on/off |
| `status` | Show the current Smart Flow stage and what's next |
| `fix` | Lighter flow for bugs — investigate, diagnose, fix, verify (no full pipeline) |
| **Review Flow** (`review`, `approve-review`, `post-review`, `self-review`) | Multi-stack PR review with stack-specialized agents → user approval → post inline comments to GitHub |
| `design`, `ui` | Design and UI scaffolding skills |
| `dart-clean-arch` | Opinionated Dart conventions (sealed freezed, naming, extensions, lint) |
| `flutter-clean-arch` | Opinionated Flutter architecture (Cubit-first, multi-state, manual DI, go_router) |
| `refine` | Standalone technical refinement of a task against the project's codebase |
| **ADO Flow** (`kickoff`, `ado-get`, `ado-comment`, `ado-close`, `ado-refine`) | Azure DevOps work item pipeline — triage, refine, comment, close (set `ADO_ORG` / `ADO_PROJECT`) |
| `pr-open`, `pr-status` | Open PRs linked to work items and track in-flight PRs (review/CI/comments digest) |
| `orcamento` | Commercial proposal generator (Markdown/HTML/PDF) driven by a local `company.json` — see `company.example.json` |

### Agents (`agents/`)

35 specialized review agents organized as a 7 × 5 matrix:

| Stack | Architecture | Correctness | Performance | Security | Testing |
|---|---|---|---|---|---|
| Flutter | ✓ | ✓ | ✓ | ✓ | ✓ |
| Dart | ✓ | ✓ | ✓ | ✓ | ✓ |
| Android (Kotlin) | ✓ | ✓ | ✓ | ✓ | ✓ |
| iOS (Swift) | ✓ | ✓ | ✓ | ✓ | ✓ |
| React | ✓ | ✓ | ✓ | ✓ | ✓ |
| NestJS | ✓ | ✓ | ✓ | ✓ | ✓ |
| GCP / Terraform | ✓ | ✓ | ✓ | ✓ | ✓ |

These are invoked automatically by the `review` skill based on the stack of the changed files.

Plus one ops agent: `gcp-cloudsql-ops` — inspects and operates on GCP Cloud SQL (PostgreSQL) instances via `gcloud sql connect`.

Smart Flow agents: `dev-implementer` (implements one task; its model is set by the ladder), `spec-challenger` (attacks a spec before planning), `qa-flutter` (G2: acceptance criteria against tests and the running app).

### Workflows (`workflows/`) and stack profiles (`stacks/`)

- `smart-implement` — per-task ladder: dev → G0 → G1, retry/escalate/rollback, circuit breaker, ToT diagnosis when blocked
- `smart-verify` — cycle-wide G1 + G2 QA; failures re-enter `smart-implement` on the owning task
- `tot-plan` — Tree of Thoughts planning: 3 independent planners, 2 judges, synthesis
- `stacks/flutter.json` — how the Flutter stack is gated (format, codegen, analyze, tests, reviewers, QA device)

### Bin (`bin/`)

Helper scripts used by skills and hooks:

- `track-tokens.py` — usage telemetry (Stop hook)
- `archive-cycle.sh` — Smart Flow lifecycle archival (keeps `runs/` for routing stats)
- `wf-checkpoint.sh` — working-tree checkpoints as git tree objects (no commit, real index untouched)
- `gate_g0.py` — deterministic G0 gate driven by a stack profile
- `wf-event.py` — run event log and persistence of workflow results into `current.json`
- `adr-index.py` — ADR index, next id, and `affects` matching
- `routing-stats.py` — escalation stats per complexity × risk and tier0 overrides
- `capture-metrics.sh` — capture per-cycle metrics
- `pr-review.sh`, `pr-inspect.sh`, `pr-registry.sh` — `gh` PR helpers for Review Flow and `pr-status`
- `ado.sh` — Azure DevOps REST helper (requires `ADO_ORG` / `ADO_PROJECT` env vars)
- `current_json.py`, `get-project.sh`, `to-slug.sh` — small utilities

## Installation

This installer creates **symlinks** from `~/.claude/{skills,agents,bin}/` into this repo, so `git pull` updates your installed Claude Code config in place.

```bash
git clone https://github.com/GustavoAlecio/claude-setup.git
cd claude-setup

# Install everything
./install.sh

# Or pick specific bundles
./install.sh smart-flow clean-arch agents-flutter

# See what's available
./install.sh --list

# Preview without writing
./install.sh --dry-run all

# Remove all symlinks pointing into this repo
./install.sh --uninstall
```

Your previous `~/.claude/{skills,agents,bin}/` content is backed up to `~/.claude/backups/pre-claude-setup-<timestamp>/` before any change.

See [INSTALL.md](INSTALL.md) for prerequisites and troubleshooting.

## Bundles

Bundles are named subsets defined as plain text files under `bundles/`. Use them to install only what you need.

| Bundle | Contents |
|---|---|
| `smart-flow` | The pipeline skills, workflows, flow agents and the bin scripts they need |
| `smart-flow-flutter` | `smart-flow` + Flutter/Dart reviewers + `stacks/flutter.json` + `qa-flutter` |
| `review-flow` | review + self-review + approve + post |
| `design` | design + ui |
| `clean-arch` | dart-clean-arch + flutter-clean-arch |
| `agents-flutter` | Flutter + Dart agents (10) |
| `agents-android` | Android agents (5) |
| `agents-ios` | iOS agents (5) |
| `agents-mobile` | flutter + android + ios |
| `agents-react` | React agents (5) |
| `agents-backend` | NestJS + GCP agents (11, incl. `gcp-cloudsql-ops`) |
| `agents-all` | All 36 agents |
| `ado-flow` | Azure DevOps pipeline skills (kickoff, refine, ado-*, pr-open, pr-status) |
| `all` | Everything (default) |

Bundles can reference other bundles with `@<name>` lines. Bundle files are simple — feel free to edit or add your own.

## Smart Flow

```
/kickoff         → pull the card, triage, refine (ADO / Linear)
/specify         → business spec
/challenge-spec  → adversarial pass on the spec before planning
/plan            → technical plan (Tree of Thoughts workflow for risky changes)
/tasks           → atomic tasks with tier0 (S→haiku, M→sonnet, L→opus), tests and scope
/implement       → smart-implement workflow: model ladder + G0/G1 gates per task
/verify          → smart-verify workflow: cycle-wide G1 + G2 QA, re-entry on failure
/complete        → propose ADRs, record lessons, update routing stats, archive
```

A task that fails its gates is retried on the same model with the findings. If it fails again, or stops improving, the checkpoint is restored and the next model up starts fresh. If the same finding survives two different models, the run stops and three independent diagnoses decide whether to fix the spec, replan or fix the environment. Details in [docs/smart-flow.md](docs/smart-flow.md).

Use `/auto` to skip approval gates between stages (blockers still stop), `/status` to see where you are and which tier each task reached, and `/fix` for one-shot bug fixes.

## Review Flow

A staged code review for PRs:

```
/review         → multi-agent review of a PR (specialized agents per stack/concern), proposes inline comments
/approve-review → mark a draft as approved, ready to publish
/post-review    → publish the approved review to GitHub (approve / comment / request_changes)
```

The `review` skill spawns parallel agents based on the changed files' stack. `self-review` is the same flow targeting your local branch instead of an open PR.

## Repository structure

```
claude-setup/
├── README.md
├── INSTALL.md
├── install.sh                # symlink installer with bundle support
├── skills/                   # 28 skills (1:1 with ~/.claude/skills/<name>/)
├── agents/                   # 39 agents (1:1 with ~/.claude/agents/<name>.md)
├── bin/                      # helper scripts symlinked into ~/.claude/bin/
├── workflows/                # dynamic workflow scripts symlinked into ~/.claude/workflows/
├── stacks/                   # stack profiles for the Smart Flow gates
├── tests/                    # ./tests/run.sh — bin smoke tests + workflow ladder tests
├── bundles/                  # named subsets (plain .txt files)
├── settings/                 # example settings.json + hooks.example.json
└── docs/                     # smart-flow, review-flow, agents-matrix
```

## License

MIT — see [LICENSE](LICENSE).
