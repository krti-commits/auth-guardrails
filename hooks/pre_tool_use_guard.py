#!/usr/bin/env python3
"""
pre_tool_use_guard.py

PAI-style PreToolUse security gate for Claude Code.
- Reads hook JSON from stdin: {session_id, tool_name, tool_input}
- Outputs JSON to stdout (exit code 0):
    allow -> default (no permission override)
    ask  -> hookSpecificOutput.permissionDecision="ask"
    deny -> hookSpecificOutput.permissionDecision="deny"

Design goals (Kamiwaza security lead posture):
- Fail-closed for secrets and high-risk auth policy files.
- Require confirmation (ask) for auth/authz code edits when evidence is missing/stale.
- Log every decision to /tmp/auth-assurance/security/YYYYMMDD/<event_id>.json
"""

from __future__ import annotations

import fnmatch
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Dict, List, Optional, Tuple


def _now_ts() -> int:
    return int(time.time())


def _iso(ts: Optional[int] = None) -> str:
    if ts is None:
        ts = _now_ts()
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(ts))


def _read_stdin_json() -> Dict[str, Any]:
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    return json.loads(raw)


def _write_stdout(obj: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj))
    sys.stdout.flush()


def allow() -> None:
    # Explicitly allow the tool call (don't rely on default behavior).
    _write_stdout({
        "suppressOutput": True,
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
        },
    })
    raise SystemExit(0)


def ask(reason: str) -> None:
    # Ask user to confirm the tool call.
    _write_stdout({
        "suppressOutput": True,
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": reason,
        },
    })
    raise SystemExit(0)


def deny(reason: str) -> None:
    # Deny the tool call with a reason shown to Claude.
    _write_stdout({
        "suppressOutput": True,
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        },
    })
    raise SystemExit(0)

def _repo_root() -> Path:
    # Prefer Claude project dir if present; fallback to cwd.
    return Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())).resolve()


def _load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text())


def _merge_dict(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    # Shallow-ish merge for our small configs
    out = dict(base)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = dict(out[k])  # type: ignore
            out[k].update(v)       # type: ignore
        else:
            out[k] = v
    return out


def _load_config(repo: Path) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    cfg_dir = repo / ".claude" / "auth_assurance" / "config"
    profiles_path = cfg_dir / "profiles.json"
    policy_path = cfg_dir / "security_policy.json"

    if not profiles_path.exists() or not policy_path.exists():
        # If the hook pack isn't installed, be permissive to avoid breaking dev.
        # (Security-lead installs this intentionally; missing config shouldn't brick Claude Code.)
        return {}, {}

    profiles = _load_json(profiles_path)
    policy = _load_json(policy_path)

    # Local override support (PAI-style USER/SYSTEM split)
    # Allow either:
    #   .claude/auth_assurance/config/security_policy.local.json
    #   .claude/local/auth_assurance_overrides/security_policy.json
    override_candidates = [
        cfg_dir / "security_policy.local.json",
        repo / ".claude" / "local" / "auth_assurance_overrides" / "security_policy.json",
    ]
    for p in override_candidates:
        if p.exists():
            try:
                policy = _merge_dict(policy, _load_json(p))
            except Exception:
                # If override is broken, fail closed for auth-sensitive writes (handled later).
                pass

    return profiles, policy


def _posix(path: str) -> str:
    return path.replace("\\", "/")


def _match_any(path: str, patterns: List[str]) -> bool:
    p = PurePosixPath(_posix(path))
    for pat in patterns:
        try:
            if p.match(pat):
                return True
        except Exception:
            # Fallback to fnmatch
            if fnmatch.fnmatchcase(_posix(path), pat):
                return True
    return False


def _git_diff_files(repo: Path, base_branch: str) -> List[str]:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "diff", "--name-only", f"{base_branch}...HEAD"],
            text=True,
        )
        files = [l.strip() for l in out.splitlines() if l.strip()]
        return sorted(files)
    except Exception:
        return []


def _fingerprint(files: List[str]) -> str:
    # stable string fingerprint
    import hashlib
    h = hashlib.sha256()
    for f in files:
        h.update(f.encode("utf-8"))
        h.update(b"\n")
    return h.hexdigest()


def _read_state(repo: Path, rel_path: str) -> Optional[Dict[str, Any]]:
    p = repo / rel_path
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except Exception:
        return None


def _log_security_event(repo: Path, event: Dict[str, Any]) -> None:
    day = time.strftime("%Y%m%d", time.localtime(_now_ts()))
    out_dir = Path("/tmp/auth-assurance/security") / day
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
        # small unique-ish id
        eid = f"{_now_ts()}_{os.getpid()}"
        (out_dir / f"{eid}.json").write_text(json.dumps(event, indent=2))
    except Exception:
        # Never break the hook due to logging failure
        pass


def _policy_lists(policy: Dict[str, Any], *keys: str) -> List[Any]:
    cur: Any = policy
    for k in keys:
        if not isinstance(cur, dict):
            return []
        cur = cur.get(k, {})
    if isinstance(cur, list):
        return cur
    return []


def _bash_patterns(policy: Dict[str, Any], bucket: str) -> List[Dict[str, str]]:
    b = policy.get("bash", {}) if isinstance(policy.get("bash"), dict) else {}
    pats = b.get(bucket, [])
    return pats if isinstance(pats, list) else []


def _match_bash(cmd: str, patterns: List[Dict[str, str]]) -> Optional[str]:
    for p in patterns:
        pat = p.get("pattern", "")
        if pat and fnmatch.fnmatchcase(cmd, pat):
            return p.get("reason", "matched security policy")
    return None


def main() -> None:
    # Global kill-switch: only enforce in repos that opt-in via env var.
    # This prevents accidental gating in unrelated projects when hooks are
    # wired globally in ~/.claude/settings.json.
    if os.environ.get("AUTH_ASSURANCE_ENABLED", "0") != "1":
        allow()

    repo = _repo_root()
    profiles_cfg, policy = _load_config(repo)

    payload = _read_stdin_json()
    session_id = payload.get("session_id")
    tool_name = payload.get("tool_name", "")
    tool_input = payload.get("tool_input", {})

    # If pack isn't installed, allow everything (don't brick dev)
    if not profiles_cfg or not policy:
        allow()

    base_branch = profiles_cfg.get("base_branch", "origin/develop")
    state_rel = policy.get("evidence", {}).get("state_file", ".claude/auth_assurance/.state/last_run.json")
    max_age = int(policy.get("evidence", {}).get("max_age_seconds", 3600))

    # Gather evidence freshness
    diff_files = _git_diff_files(repo, base_branch)
    fp = _fingerprint(diff_files)
    state = _read_state(repo, state_rel)

    # Evidence state:
    # - evidence_pass: last run for this diff was PASS and fresh (overall)
    # - ran_fresh_for_diff: a run happened for this diff recently (PASS or FAIL), but not tooling error
    # - authn_gateway_pass: authn-gateway profile specifically passed (for policy file gating)
    evidence_pass = False
    ran_fresh_for_diff = False
    authn_gateway_pass = False
    profile_exit_codes: Dict[str, int] = {}
    if state:
        ts = int(state.get("timestamp", 0))
        exit_code_raw = state.get("exit_code", 999)
        try:
            exit_code = int(exit_code_raw)  # may be None/str
        except Exception:
            exit_code = 999
        ok_fp = state.get("diff_fingerprint") == fp
        fresh = (_now_ts() - ts) <= max_age
        evidence_pass = bool(ok_fp and fresh and exit_code == 0)
        ran_fresh_for_diff = bool(ok_fp and fresh and exit_code in (0, 1))
        # Per-profile exit codes for fine-grained policy gating
        profile_exit_codes = state.get("profile_exit_codes", {})
        if isinstance(profile_exit_codes, dict):
            try:
                authn_gateway_rc = int(profile_exit_codes.get("authn-gateway", 999))
            except (ValueError, TypeError):
                authn_gateway_rc = 999
            authn_gateway_pass = bool(ok_fp and fresh and authn_gateway_rc == 0)

    # ---- Handle tool types ----
    if tool_name == "Bash":
        cmd = ""
        if isinstance(tool_input, str):
            cmd = tool_input
        elif isinstance(tool_input, dict):
            cmd = str(tool_input.get("command", ""))
        cmd = cmd.strip()

        # Blocked
        reason = _match_bash(cmd, _bash_patterns(policy, "blocked"))
        if reason:
            _log_security_event(repo, {
                "ts": _iso(), "session_id": session_id, "tool": "Bash",
                "decision": "block", "reason": reason, "command": cmd,
            })
            deny(f"Blocked command ({reason}): {cmd}")

        # Confirm
        reason = _match_bash(cmd, _bash_patterns(policy, "confirm"))
        if reason:
            _log_security_event(repo, {
                "ts": _iso(), "session_id": session_id, "tool": "Bash",
                "decision": "ask", "reason": reason, "command": cmd,
            })
            ask(f"High-risk command ({reason}). Confirm?")

        # Allow
        _log_security_event(repo, {
            "ts": _iso(), "session_id": session_id, "tool": "Bash",
            "decision": "allow", "command": cmd,
        })
        allow()

    if tool_name in ("Edit", "Write", "Read"):
        file_path = ""
        if isinstance(tool_input, dict):
            file_path = str(tool_input.get("file_path", tool_input.get("path", "")))
        file_path = _posix(file_path)

        # Absolute deny for secrets
        if _match_any(file_path, _policy_lists(policy, "paths", "zeroAccess")):
            _log_security_event(repo, {
                "ts": _iso(), "session_id": session_id, "tool": tool_name,
                "decision": "block", "reason": "zeroAccess", "path": file_path,
            })
            deny(f"Blocked access to sensitive path: {file_path}")

        # Require evidence (strict) for policy files - use per-profile gating
        # Policy files (auth_gateway_policy*.yaml) only require authn-gateway to pass,
        # not the entire multi-profile run. This prevents unrelated type errors from
        # blocking policy edits.
        if _match_any(file_path, _policy_lists(policy, "evidence", "require_success_for_paths")):
            if not authn_gateway_pass:
                _log_security_event(repo, {
                    "ts": _iso(), "session_id": session_id, "tool": tool_name,
                    "decision": "block", "reason": "authn_gateway_not_pass", "path": file_path,
                    "base_branch": base_branch, "fingerprint": fp,
                    "profile_exit_codes": profile_exit_codes,
                })
                deny(
                    "Auth policy edit requires authn-gateway profile to PASS "
                    f"for current diff vs {base_branch}. Run auth_assurance."
                )

        # Confirm for auth surfaces without evidence
        if _match_any(file_path, _policy_lists(policy, "evidence", "require_confirm_without_evidence_for_paths")):
            if not ran_fresh_for_diff:
                _log_security_event(repo, {
                    "ts": _iso(), "session_id": session_id, "tool": tool_name,
                    "decision": "ask", "reason": "no_fresh_evidence", "path": file_path,
                    "base_branch": base_branch, "fingerprint": fp,
                })
                ask(
                    "Auth surface change detected. No fresh Auth Assurance evidence "
                    f"for current diff vs {base_branch}. Run auth_assurance (recommended) and confirm."
                )

        # Confirm writes for broad auth surfaces
        if tool_name in ("Edit", "Write") and _match_any(file_path, _policy_lists(policy, "paths", "confirmWrite")) and not ran_fresh_for_diff:
            _log_security_event(repo, {
                "ts": _iso(), "session_id": session_id, "tool": tool_name,
                "decision": "ask", "reason": "confirmWrite", "path": file_path,
            })
            ask(f"Editing sensitive path: {file_path}. Confirm?")

        _log_security_event(repo, {
            "ts": _iso(), "session_id": session_id, "tool": tool_name,
            "decision": "allow", "path": file_path,
        })
        allow()

    # Default allow
    allow()


if __name__ == "__main__":
    main()
