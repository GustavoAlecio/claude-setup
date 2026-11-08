#!/usr/bin/env python3
"""
Pausa, retoma ou arquiva o ciclo ativo de um projeto (usado pelo app via engine).

  wf-cycle.py pause   <projeto>   current.json ganha paused + paused_at
  wf-cycle.py resume  <projeto>   tira paused e paused_at
  wf-cycle.py archive <projeto>   archive-cycle.sh abandoned: vai para o historico como abandonado

Workflow em $CLAUDE_HOME/workflow (padrao ~/.claude). Sai com 1 e a mensagem no stderr quando nao ha ciclo.
"""

import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from current_json import update_current_json  # noqa: E402

PROJECT = re.compile(r"^[A-Za-z0-9._-]+$")


def workflow_dir(project: str) -> Path:
    home = Path(os.environ.get("CLAUDE_HOME") or Path.home() / ".claude")
    return home / "workflow" / project


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("pause", "resume", "archive") or not PROJECT.match(argv[2]):
        print("uso: wf-cycle.py pause|resume|archive <projeto>", file=sys.stderr)
        return 2
    action, project = argv[1], argv[2]
    wf = workflow_dir(project)
    if not (wf / "current.json").is_file():
        print(f"sem ciclo ativo em {project}", file=sys.stderr)
        return 1

    if action == "archive":
        # archive-cycle.sh le $HOME/.claude; com CLAUDE_HOME o HOME e o pai dele.
        env = dict(os.environ)
        if os.environ.get("CLAUDE_HOME"):
            env["HOME"] = str(Path(os.environ["CLAUDE_HOME"]).parent)
        script = Path(__file__).resolve().parent / "archive-cycle.sh"
        return subprocess.run(["bash", str(script), "abandoned", project], env=env).returncode

    def modify(data: dict) -> dict:
        if action == "pause":
            data["paused"] = True
            data["paused_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        else:
            data.pop("paused", None)
            data.pop("paused_at", None)
        return data

    update_current_json(str(wf), modify)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
