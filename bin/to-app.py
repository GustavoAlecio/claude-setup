#!/usr/bin/env python3
"""
Leva a sessao do Claude Code deste terminal para o app (claude_flow) e a abre la.

  to-app.py        a sessao de $CLAUDE_CODE_SESSION_ID, no cwd em que ela roda

Abre o app se ele estiver fechado, espera ele se ligar ao engine e pede para ele importar a sessao com as regras
dele (projeto, modo de permissao, conta). Quem decide entre continuar o transcript e abrir um ramo novo e o engine,
no Retomar: com este terminal ainda aberto, o app segue num ramo novo.

Sai com 0 e uma linha de status; com 1 e o motivo no stderr.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BUNDLE_ID = "dev.claudesetup.claudeFlow"
APP_BINARY = "claude_flow.app/Contents/MacOS/claude_flow"
WAIT_S = 30

CLAUDE_HOME = Path(os.environ.get("CLAUDE_HOME") or Path.home() / ".claude")
ENDPOINT_FILE = CLAUDE_HOME / "workflow" / ".dashboard" / "engine-sessions" / "engine.json"


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 1


def session_cwd(session_id: str) -> str:
    """O cwd que o CLI registrou para a sessao; o do shell pode ter mudado com um `cd`."""
    pid = os.environ.get("CLAUDE_PID")
    try:
        info = json.loads((CLAUDE_HOME / "sessions" / f"{pid}.json").read_text())
        if info.get("sessionId") == session_id and isinstance(info.get("cwd"), str):
            return info["cwd"]
    except (OSError, ValueError):
        pass
    return os.getcwd()


def request(port: int, method: str, path: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method)
    if data is not None:
        req.add_header("content-type", "application/json")
    with urllib.request.urlopen(req, timeout=5) as res:
        return json.loads(res.read() or b"null")


def connected_port() -> int | None:
    """Porta do engine quando ha um app ouvindo o stream global; `None` se nao ha engine ou app."""
    try:
        endpoint = json.loads(ENDPOINT_FILE.read_text())
        port = int(endpoint["port"])
        return port if request(port, "GET", "/api/ui").get("clients", 0) > 0 else None
    except (OSError, ValueError, KeyError, TypeError, urllib.error.URLError):
        return None


def running_app() -> str | None:
    """O `.app` da instancia aberta; `open -b` lancaria a copia preferida do LaunchServices como segunda instancia."""
    pids = subprocess.run(["pgrep", "-f", APP_BINARY], capture_output=True, text=True).stdout.split()
    for pid in pids:
        command = subprocess.run(["ps", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        if APP_BINARY in command:
            return command[: command.index(APP_BINARY) + len("claude_flow.app")]
    return None


def open_app() -> bool:
    target = running_app()
    command = ["open", target] if target else ["open", "-b", BUNDLE_ID]
    return subprocess.run(command, capture_output=True).returncode == 0


def main() -> int:
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not session_id:
        return fail("sem CLAUDE_CODE_SESSION_ID: rode dentro de uma sessao do Claude Code")
    cwd = session_cwd(session_id)

    port = connected_port()
    if port is None:
        if not open_app():
            return fail(f"nao consegui abrir o app ({BUNDLE_ID}); ele precisa ter sido aberto ao menos uma vez")
        deadline = time.monotonic() + WAIT_S
        while port is None and time.monotonic() < deadline:
            time.sleep(0.5)
            port = connected_port()
        if port is None:
            return fail(f"o app nao se ligou ao engine em {WAIT_S}s")

    try:
        request(port, "POST", "/api/ui/open-terminal", {"sdkSessionId": session_id, "cwd": cwd})
    except urllib.error.HTTPError as err:
        return fail(f"o engine recusou: {json.loads(err.read() or b'{}').get('error', err)}")
    except urllib.error.URLError as err:
        return fail(f"engine fora do ar: {err.reason}")
    open_app()
    print(f"sessao {session_id[:8]} enviada para o app ({cwd})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
