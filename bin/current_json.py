"""
Atomic read-modify-write for current.json with file locking.

Usage:
    from current_json import update_current_json, update_json

    def modifier(data: dict) -> dict:
        data["status"] = "implementing"
        return data

    update_current_json("/path/to/workflow/project", modifier)
"""

import copy
import fcntl
import json
import os
from pathlib import Path


def update_json(path, lock_path, fn, default: dict = None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    with open(lock_path, "w") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            if path.exists():
                with open(path, encoding="utf-8") as f:
                    data = json.load(f)
            else:
                data = copy.deepcopy(default) if default is not None else {}

            data = fn(data)

            tmp_path = path.with_name(path.name + ".tmp")
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
            os.replace(str(tmp_path), str(path))

            return data
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def update_current_json(workflow_dir: str, modifier_fn, default: dict = None):
    return update_json(
        Path(workflow_dir) / "current.json",
        Path(workflow_dir) / ".current.json.lock",
        modifier_fn,
        default,
    )


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
