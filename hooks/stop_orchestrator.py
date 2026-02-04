#!/usr/bin/env python3
"""
stop_orchestrator.py

PAI-style Stop hook orchestrator for Kamiwaza Auth Assurance.
- Runs at end of a Claude Code turn ("Stop" hook event).
- Determines what changed vs base branch.
- Selects relevant profiles from config/profiles.json.
- Optionally auto-runs guardrails for those profiles.
- (When autorun enabled) runs auth_assurance executor, which writes last_run.json for freshness.

Environment knobs:
- AUTH_ASSURANCE_AUTORUN=1   -> actually execute checks on Stop
- AUTH_ASSURANCE_BASE_BRANCH -> override base branch (e.g., origin/develop)
- AUTH_ASSURANCE_DEBOUNCE_S  -> skip re-run if same fingerprint within N seconds (default: 300)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path, PurePosixPath
from typing import Any, Dict, List, Optional, Tuple


def _now() -> int:
    return int(time.time())


def _repo_root() -> Path:
    return Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())).resolve()


def _posix(path: str) -> str:
    return path.replace("\\", "/")


def _load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text())


def _merge_dict(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(base)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = dict(out[k])  # type: ignore
            out[k].update(v)       # type: ignore
        else:
            out[k] = v
    return out


def _load_profiles_config(repo: Path) -> Optional[Dict[str, Any]]:
    cfg_dir = repo / ".claude" / "auth_assurance" / "config"
    p = cfg_dir / "profiles.json"
    if not p.exists():
        return None
    cfg = _load_json(p)

    # allow local overrides (PAI-style)
    override_candidates = [
        cfg_dir / "profiles.local.json",
        repo / ".claude" / "local" / "auth_assurance_overrides" / "profiles.json",
    ]
    for o in override_candidates:
        if o.exists():
            try:
                cfg = _merge_dict(cfg, _load_json(o))
            except Exception:
                pass
    return cfg


def _git_diff_files(repo: Path, base_branch: str) -> List[str]:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "diff", "--name-only", f"{base_branch}...HEAD"],
            text=True,
        )
        return sorted([l.strip() for l in out.splitlines() if l.strip()])
    except Exception:
        return []


def _fingerprint(files: List[str]) -> str:
    import hashlib
    h = hashlib.sha256()
    for f in files:
        h.update(f.encode("utf-8"))
        h.update(b"\n")
    return h.hexdigest()


def _match_any(file_path: str, patterns: List[str]) -> bool:
    p = PurePosixPath(_posix(file_path))
    for pat in patterns:
        try:
            if p.match(pat):
                return True
        except Exception:
            if file_path == pat:
                return True
    return False


def _select_profiles(cfg: Dict[str, Any], files: List[str]) -> List[str]:
    profs = cfg.get("profiles", {})
    selected: List[str] = []
    for name, p in profs.items():
        if name == "all":
            continue
        if isinstance(p, dict) and p.get("auto_select") is False:
            continue
        triggers = p.get("triggers", []) if isinstance(p, dict) else []
        if triggers and any(_match_any(f, triggers) for f in files):
            selected.append(name)
    return sorted(set(selected))



def _write_state(repo: Path, state: Dict[str, Any]) -> None:
    state_dir = repo / ".claude" / "auth_assurance" / ".state"
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "last_run.json").write_text(json.dumps(state, indent=2))


def _read_state(repo: Path) -> Optional[Dict[str, Any]]:
    p = repo / ".claude" / "auth_assurance" / ".state" / "last_run.json"
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except Exception:
        return None


def main() -> None:
    # Read stdin for stop hook metadata
    payload = json.loads(sys.stdin.read() or "{}")

    # Prevent infinite continuation loops
    if payload.get("stop_hook_active"):
        return

    # Global kill-switch: no-op in repos that don't opt in
    if os.environ.get("AUTH_ASSURANCE_ENABLED", "0") != "1":
        return

    repo = _repo_root()
    cfg = _load_profiles_config(repo)
    if not cfg:
        # Not installed; nothing to do.
        return

    base_branch = os.environ.get("AUTH_ASSURANCE_BASE_BRANCH") or cfg.get("base_branch", "origin/develop")
    files = _git_diff_files(repo, base_branch)
    if not files:
        return

    fp = _fingerprint(files)
    debounce_s = int(os.environ.get("AUTH_ASSURANCE_DEBOUNCE_S", "300"))

    prev = _read_state(repo)
    if prev and prev.get("diff_fingerprint") == fp:
        last_ts = int(prev.get("timestamp", 0))
        if (_now() - last_ts) < debounce_s:
            return

    profiles = _select_profiles(cfg, files)
    if not profiles:
        return

    # Only run automatically when explicitly enabled.
    autorun = os.environ.get("AUTH_ASSURANCE_AUTORUN", "0") == "1"
    if not autorun:
        return

    # Run the executor (it writes the canonical last_run.json state).
    cmd = [
        "python3",
        ".claude/auth_assurance/bin/auth_assurance.py",
        "run",
        "--profiles",
        ",".join(profiles),
        "--base",
        base_branch,
    ]
    _ = subprocess.call(cmd, cwd=str(repo))
    return

if __name__ == "__main__":
    main()
