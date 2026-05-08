#!/usr/bin/env bash
# claude-setup installer — symlinks skills, agents and bin scripts into ~/.claude/
# Usage:
#   ./install.sh                    # installs the "all" bundle (everything)
#   ./install.sh smart-flow         # installs only the smart-flow bundle
#   ./install.sh smart-flow review-flow agents-flutter   # combine bundles
#   ./install.sh --list             # list available bundles
#   ./install.sh --dry-run all      # show what would be installed
#   ./install.sh --uninstall        # remove all symlinks pointing into this repo

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
BUNDLES_DIR="$REPO_DIR/bundles"
DRY_RUN=0
UNINSTALL=0

# ---- arg parsing ---------------------------------------------------------

if [ $# -eq 0 ]; then
  set -- "all"
fi

BUNDLES=()
for arg in "$@"; do
  case "$arg" in
    --list)
      echo "Available bundles:"
      for f in "$BUNDLES_DIR"/*.txt; do
        name=$(basename "$f" .txt)
        desc=$(head -n 1 "$f" | sed 's/^# *//')
        printf "  %-20s %s\n" "$name" "$desc"
      done
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --uninstall)
      UNINSTALL=1
      ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      BUNDLES+=("$arg")
      ;;
  esac
done

# ---- uninstall path ------------------------------------------------------

if [ "$UNINSTALL" -eq 1 ]; then
  echo "Removing symlinks pointing into $REPO_DIR..."
  for d in skills agents bin; do
    [ -d "$CLAUDE_DIR/$d" ] || continue
    find "$CLAUDE_DIR/$d" -maxdepth 1 -type l | while read -r link; do
      target=$(readlink "$link")
      case "$target" in
        "$REPO_DIR"/*) rm "$link"; echo "  removed $link" ;;
      esac
    done
  done
  echo "Done."
  exit 0
fi

# ---- bundle resolution ---------------------------------------------------

RESOLVED_ENTRIES=()
SEEN_BUNDLES=""

resolve_bundle() {
  local name="$1"
  case " $SEEN_BUNDLES " in
    *" $name "*) return ;;
  esac
  SEEN_BUNDLES="$SEEN_BUNDLES $name"

  local file="$BUNDLES_DIR/$name.txt"
  if [ ! -f "$file" ]; then
    echo "Error: bundle '$name' not found at $file" >&2
    exit 1
  fi

  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -z "$line" ] && continue

    if [[ "$line" == @* ]]; then
      resolve_bundle "${line#@}"
    else
      RESOLVED_ENTRIES+=("$line")
    fi
  done < "$file"
}

for b in "${BUNDLES[@]}"; do
  resolve_bundle "$b"
done

# ---- backup --------------------------------------------------------------

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$CLAUDE_DIR/backups/pre-claude-setup-$TIMESTAMP"

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$BACKUP_DIR"
  for d in skills agents bin; do
    if [ -e "$CLAUDE_DIR/$d" ]; then
      cp -R "$CLAUDE_DIR/$d" "$BACKUP_DIR/" 2>/dev/null || true
    fi
  done
  echo "Backup: $BACKUP_DIR"
fi

# ---- linking -------------------------------------------------------------

mkdir -p "$CLAUDE_DIR/skills" "$CLAUDE_DIR/agents" "$CLAUDE_DIR/bin"

link_one() {
  local src="$1"
  local dest="$2"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] $dest -> $src"
    return
  fi

  ln -sfn "$src" "$dest"
  echo "  linked $dest"
}

for entry in "${RESOLVED_ENTRIES[@]}"; do
  src_path="$REPO_DIR/$entry"

  if [ ! -e "$src_path" ]; then
    echo "Warning: $entry not found in repo, skipping" >&2
    continue
  fi

  case "$entry" in
    skills/*)
      name=$(basename "$entry")
      link_one "$src_path" "$CLAUDE_DIR/skills/$name"
      ;;
    agents/*)
      name=$(basename "$entry")
      link_one "$src_path" "$CLAUDE_DIR/agents/$name"
      ;;
    bin/)
      for f in "$src_path"*; do
        [ -e "$f" ] || continue
        link_one "$f" "$CLAUDE_DIR/bin/$(basename "$f")"
      done
      ;;
    bin/*)
      name=$(basename "$entry")
      link_one "$src_path" "$CLAUDE_DIR/bin/$name"
      ;;
    *)
      echo "Warning: unknown entry type '$entry', skipping" >&2
      ;;
  esac
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "Dry run complete. Re-run without --dry-run to apply."
else
  echo
  echo "Done. Bundles installed: ${BUNDLES[*]}"
  echo "Backup saved to: $BACKUP_DIR"
fi
