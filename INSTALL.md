# Installation

## Prerequisites

- [Claude Code](https://claude.com/claude-code) installed and run at least once (so `~/.claude/` exists).
- `bash` 3.2+ (default on macOS) or `bash` 4+ on Linux.
- `git`.

## Install

```bash
git clone https://github.com/GustavoAlecio/claude-setup.git
cd claude-setup
./install.sh                  # everything
./install.sh smart-flow       # only the smart-flow bundle
./install.sh smart-flow clean-arch agents-flutter   # combine
```

## What it does

1. **Backs up** your existing `~/.claude/skills/`, `~/.claude/agents/`, `~/.claude/bin/` to `~/.claude/backups/pre-claude-setup-<timestamp>/`.
2. **Resolves bundle dependencies** (entries starting with `@` reference other bundles).
3. **Symlinks** each item from this repo into `~/.claude/`. Existing symlinks are replaced; existing real files in `~/.claude/skills/<name>/` are NOT touched (only the symlink at the top level is overwritten).

Symlinks are item-by-item (not directory-level), so any custom skills or agents you have in `~/.claude/` that aren't in this repo are preserved.

## Update

```bash
cd claude-setup
git pull
```

That's it — symlinks point to the repo, so updates apply immediately. Re-run `./install.sh` only if new bundles or new entries were added.

## Uninstall

```bash
./install.sh --uninstall
```

This removes only the symlinks that point into this repo. Your custom files and any other symlinks are untouched. Backups remain in `~/.claude/backups/`.

## Customizing without losing work on `git pull`

Two options:

### Option 1 — Override locally

If you want to tweak a skill, edit it directly in this repo. The symlink in `~/.claude/skills/<name>/` resolves to your edit. Commit when ready, or keep it on a local branch.

### Option 2 — Replace with your own version

To override an installed skill with a custom version that should NOT be overwritten by `git pull`:

```bash
# Remove the symlink and put your custom version in its place
rm ~/.claude/skills/specify
mkdir ~/.claude/skills/specify
# write your custom SKILL.md there
```

`install.sh` won't overwrite a real directory at `~/.claude/skills/<name>/`. It only overwrites symlinks.

## Troubleshooting

**"Bundle 'foo' not found"** — bundle name must match a file in `bundles/<foo>.txt`. Run `./install.sh --list`.

**Symlinks not appearing** — check that `~/.claude/skills/`, `~/.claude/agents/`, `~/.claude/bin/` exist and you have write permission. Run with `--dry-run` to see what would be linked.

**"declare: -A: invalid option"** — your bash is too old. The installer is written for bash 3.2+ (default on macOS). If you see this, please open an issue.

**Hooks reference scripts that aren't installed** — your `settings.json` may reference scripts in `bin/` that aren't symlinked. Either install the `all` bundle, or update your `settings.json` to remove the hook.

## Settings (optional)

`settings/settings.example.json` and `settings/hooks.example.json` are provided as references. They are NOT symlinked — you copy and adapt them manually:

```bash
cp settings/settings.example.json ~/.claude/settings.json
```

Review the file before applying — it includes hook references that depend on `bin/` being installed.
