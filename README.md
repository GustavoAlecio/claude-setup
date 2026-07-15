# claude-setup

My personal [Claude Code](https://claude.com/claude-code) configuration — skills, agents, and helper scripts I use across projects.

> Opinionated, shared as-is. Borrow what's useful, ignore what isn't.

## What's inside

### Skills (`skills/`)

| Skill | Purpose |
|---|---|
| **Smart Flow** (`specify`, `plan`, `tasks`, `implement`, `verify`) | A 5-step pipeline for non-trivial work — from spec → tasks → implementation → verification |
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

### Bin (`bin/`)

Helper scripts used by skills and hooks:

- `track-tokens.py` — usage telemetry (Stop hook)
- `archive-cycle.sh` — Smart Flow lifecycle archival
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
| `smart-flow` | The 5-step pipeline + auto/status/fix |
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

A staged workflow for medium-to-large tasks:

```
/specify    → produce a business spec from the user's request
/plan       → produce a technical plan from the approved spec
/tasks      → split the plan into ordered atomic tasks
/implement  → execute the tasks in order
/verify     → validate the implementation against the spec's acceptance criteria
```

Use `/auto` to skip approval gates between stages, `/status` to see where you are, and `/fix` for one-shot bug fixes that don't need the full pipeline.

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
├── skills/                   # 25 skills (1:1 with ~/.claude/skills/<name>/)
├── agents/                   # 36 agents (1:1 with ~/.claude/agents/<name>.md)
├── bin/                      # helper scripts symlinked into ~/.claude/bin/
├── bundles/                  # named subsets (plain .txt files)
├── settings/                 # example settings.json + hooks.example.json
└── docs/                     # smart-flow, review-flow, agents-matrix
```

## License

MIT — see [LICENSE](LICENSE).
