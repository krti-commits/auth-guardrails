#!/usr/bin/env python3
"""
auth_assurance.py

A small, deterministic executor for Auth Assurance.
It is intentionally boring: select profiles, run configured commands, write artifacts.

This version is designed to *wrap* your existing profile runner:
  ./.claude/local/run-auth-guardrails.sh <profile> <base_branch>

That preserves your current evidence discipline under /tmp/claude-baseline/post/<profile>/<timestamp>/...

Outputs:
  /tmp/auth-assurance/runs/<run_id>/
    run.json
    profiles/<profile>.log
    profiles/<profile>.meta.json

Exit codes:
  0 PASS
  1 FAIL (one or more profiles failed)
  2 TOOLING_ERROR (missing runner/config)
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path, PurePosixPath
from typing import Any, Dict, List, Optional, Tuple


def _now() -> int:
    return int(time.time())


def _iso(ts: Optional[int] = None) -> str:
    if ts is None:
        ts = _now()
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(ts))


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


def _load_profiles_config(repo: Path) -> Dict[str, Any]:
    cfg_dir = repo / ".claude" / "auth_assurance" / "config"
    p = cfg_dir / "profiles.json"
    if not p.exists():
        raise FileNotFoundError(f"missing profiles config: {p}")
    cfg = _load_json(p)

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
    out = subprocess.check_output(
        ["git", "-C", str(repo), "diff", "--name-only", f"{base_branch}...HEAD"],
        text=True,
    )
    return sorted([l.strip() for l in out.splitlines() if l.strip()])


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



def _ensure_dir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)


def _run_cmd_capture(cmd: str, cwd: Path, env: Dict[str, str], log_path: Path) -> int:
    # Run with shell for command templates; capture stdout+stderr into file.
    with log_path.open("w", encoding="utf-8") as f:
        p = subprocess.Popen(
            cmd,
            cwd=str(cwd),
            shell=True,
            stdout=f,
            stderr=subprocess.STDOUT,
            env=env,
            text=True,
        )
        return int(p.wait())


def _parse_evidence_dir(log_text: str) -> Optional[str]:
    # Try a few common banner formats, e.g.:
    #   Evidence: /tmp/claude-baseline/post/<profile>/<timestamp>
    #   Evidence directory: /tmp/...
    import re
    for line in log_text.splitlines():
        m = re.match(r"^\s*Evidence(?: directory)?:\s*(\S+)\s*$", line)
        if m:
            return m.group(1)
    return None



def cmd_select(args: argparse.Namespace) -> int:
    repo = _repo_root()
    cfg = _load_profiles_config(repo)
    base = args.base or cfg.get("base_branch", "origin/develop")
    files = _git_diff_files(repo, base)
    profs = _select_profiles(cfg, files)
    if args.json:
        sys.stdout.write(json.dumps({"base": base, "profiles": profs, "files": files}, indent=2))
    else:
        sys.stdout.write(",".join(profs) + "\n")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    repo = _repo_root()
    cfg = _load_profiles_config(repo)

    base = args.base or cfg.get("base_branch", "origin/develop")

    profiles_arg = args.profiles
    profiles: List[str]
    if profiles_arg == "auto":
        files = _git_diff_files(repo, base)
        profiles = _select_profiles(cfg, files)
    else:
        profiles = [p.strip() for p in profiles_arg.split(",") if p.strip()]

    if not profiles:
        print("No profiles selected; nothing to run.")
        return 0

    runner_tpl = cfg.get("runner", {}).get("command_template", "")
    if not runner_tpl:
        print("TOOLING_ERROR: runner.command_template not configured", file=sys.stderr)
        return 2

    # Ensure runner exists (best-effort)
    runner_first = runner_tpl.split()[0]
    runner_path = (repo / runner_first).resolve()
    if not runner_path.exists():
        # We allow PATH-based commands, but for this repo we expect a file.
        print(f"TOOLING_ERROR: runner not found: {runner_path}", file=sys.stderr)
        return 2

    run_id = time.strftime("%Y%m%d_%H%M%S", time.localtime(_now()))
    out_dir = Path("/tmp/auth-assurance/runs") / run_id
    prof_dir = out_dir / "profiles"
    _ensure_dir(prof_dir)

    # Run metadata
    diff_files = _git_diff_files(repo, base)
    run_meta: Dict[str, Any] = {
        "run_id": run_id,
        "timestamp": _iso(),
        "repo_root": str(repo),
        "base_branch": base,
        "profiles": profiles,
        "diff_fingerprint": _fingerprint(diff_files),
        "changed_files_count": len(diff_files),
        "results": {},
    }

    overall_rc = 0
    env = os.environ.copy()
    # Merge env vars from runner config
    runner_env = cfg.get("runner", {}).get("env", {})
    if isinstance(runner_env, dict):
        env.update({k: str(v) for k, v in runner_env.items()})

    for profile in profiles:
        cmd = runner_tpl.format(profile=profile, base_branch=base, repo_root=str(repo))
        log_path = prof_dir / f"{profile}.log"

        rc = _run_cmd_capture(cmd, repo, env, log_path)
        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        evidence_dir = _parse_evidence_dir(log_text)

        run_meta["results"][profile] = {
            "exit_code": rc,
            "command": cmd,
            "evidence_dir": evidence_dir,
            "log_file": str(log_path),
        }

        if rc == 2:
            overall_rc = 2
            break
        if rc != 0:
            overall_rc = 1

    (out_dir / "run.json").write_text(json.dumps(run_meta, indent=2), encoding="utf-8")

    # Slack-friendly banner
    status = "PASS" if overall_rc == 0 else ("TOOLING_ERROR" if overall_rc == 2 else "FAIL")

    # Persist a small state record so PreToolUse can enforce "freshness".
    try:
        state_dir = repo / ".claude" / "auth_assurance" / ".state"
        state_dir.mkdir(parents=True, exist_ok=True)
        # Extract per-profile exit codes for fine-grained gating
        profile_exit_codes = {
            p: r.get("exit_code", 999)
            for p, r in run_meta.get("results", {}).items()
        }
        state = {
            "timestamp": _now(),
            "base_branch": base,
            "diff_fingerprint": run_meta.get("diff_fingerprint"),
            "profiles": profiles,
            "exit_code": overall_rc,
            "profile_exit_codes": profile_exit_codes,
            "status": status,
            "run_id": run_id,
            "run_json": str(out_dir / "run.json"),
        }
        (state_dir / "last_run.json").write_text(json.dumps(state, indent=2), encoding="utf-8")
    except Exception:
        pass

    print("--------------------------------------------")
    print(f"Auth Assurance {status} | run={run_id} | profiles={','.join(profiles)}")
    print(f"Evidence summary: {out_dir}/run.json")
    print("--------------------------------------------")

    return overall_rc


def cmd_validate_policy(args: argparse.Namespace) -> int:
    # Minimal YAML syntax + structure check for auth_gateway_policy.yaml
    p = Path(args.path)
    if not p.exists():
        print(f"TOOLING_ERROR: policy file not found: {p}", file=sys.stderr)
        return 2
    try:
        import yaml  # type: ignore
    except Exception:
        print("TOOLING_ERROR: PyYAML not installed (pip install pyyaml)", file=sys.stderr)
        return 2

    try:
        policy = yaml.safe_load(p.read_text())
    except Exception as e:
        print(f"FAIL: YAML parse error: {e}", file=sys.stderr)
        return 1

    if not isinstance(policy, dict):
        print("FAIL: policy must be a YAML mapping/dict", file=sys.stderr)
        return 1

    # Extremely light structure check; you can harden later.
    if not any(k in policy for k in ("version", "roles", "rules")):
        print("FAIL: policy missing expected keys (version/roles/rules)", file=sys.stderr)
        return 1

    print("PASS: policy YAML loads and has expected top-level keys")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="auth_assurance")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_sel = sub.add_parser("select", help="select profiles triggered by current diff")
    p_sel.add_argument("--base", default=None)
    p_sel.add_argument("--json", action="store_true")
    p_sel.set_defaults(func=cmd_select)

    p_run = sub.add_parser("run", help="run one or more profiles")
    p_run.add_argument("--profiles", default="auto", help="comma list or 'auto'")
    p_run.add_argument("--base", default=None)
    p_run.set_defaults(func=cmd_run)

    p_val = sub.add_parser("validate-policy", help="validate gateway policy YAML (syntax + minimal structure)")
    p_val.add_argument("path")
    p_val.set_defaults(func=cmd_validate_policy)

    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
