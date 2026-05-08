"""
Atomic read-modify-write for current.json with file locking.

Usage:
    from current_json import update_current_json

    def modifier(data: dict) -> dict:
        data["status"] = "implementing"
        return data

    update_current_json("/path/to/workflow/project", modifier)
"""

import fcntl
import json
import os
from pathlib import Path


def update_current_json(workflow_dir: str, modifier_fn, default: dict = None):
    current_path = Path(workflow_dir) / "current.json"
    lock_path = Path(workflow_dir) / ".current.json.lock"

    current_path.parent.mkdir(parents=True, exist_ok=True)

    with open(lock_path, "w") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            if current_path.exists():
                with open(current_path) as f:
                    data = json.load(f)
            else:
                data = default or {}

            data = modifier_fn(data)

            tmp_path = current_path.with_suffix(".tmp")
            with open(tmp_path, "w") as f:
                json.dump(data, f, indent=2)
            os.replace(str(tmp_path), str(current_path))

            return data
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def read_current_json(workflow_dir: str) -> dict:
    current_path = Path(workflow_dir) / "current.json"
    lock_path = Path(workflow_dir) / ".current.json.lock"

    if not current_path.exists():
        return {}

    current_path.parent.mkdir(parents=True, exist_ok=True)

    with open(lock_path, "w") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_SH)
        try:
            with open(current_path) as f:
                return json.load(f)
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
