# Auth Guardrails v2 - Python-Based Profile Tooling

Profile-based auth guardrails for Claude Code, implemented as Python hooks with deterministic evidence tracking.

## Architecture

```
.claude/auth_assurance/
├── bin/
│   └── auth_assurance.py       # CLI executor: select, run, validate-policy
├── hooks/
│   ├── pre_tool_use_guard.py   # PreToolUse hook: gates file edits + bash commands
│   └── stop_orchestrator.py    # Stop hook: auto-runs profiles on turn end
├── config/
│   ├── profiles.json           # Profile definitions + trigger patterns
│   └── security_policy.json    # File access policy + bash blocklist
└── .state/
    └── last_run.json           # Evidence state (written by runner, read by guard)
```

## Quick Start

### Manual run (recommended first)

```bash
# See which profiles are triggered by your current diff
python3 .claude/auth_assurance/bin/auth_assurance.py select --base origin/develop

# Run triggered profiles
python3 .claude/auth_assurance/bin/auth_assurance.py run --profiles auto --base origin/develop

# Run a specific profile
python3 .claude/auth_assurance/bin/auth_assurance.py run --profiles authz-core --base origin/develop
```

### Claude Code hook integration

Add to `.claude/settings.local.json` (repo-local, gitignored):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Edit|Write|Read",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/auth_assurance/hooks/pre_tool_use_guard.py\""
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/auth_assurance/hooks/stop_orchestrator.py\""
          }
        ]
      }
    ]
  },
  "env": {
    "AUTH_ASSURANCE_ENABLED": "1",
    "AUTH_ASSURANCE_AUTORUN": "0",
    "AUTH_ASSURANCE_BASE_BRANCH": "origin/develop",
    "AUTH_ASSURANCE_DEBOUNCE_S": "300"
  }
}
```

**Important:** Hooks go in `settings.local.json` (repo-scoped), NOT `~/.claude/settings.json` (global). Global hook wiring breaks in any repo that doesn't have `.claude/auth_assurance/`.

## Profiles

| Profile | Scope | When Triggered |
|---------|-------|----------------|
| **authz-core** | `kamiwaza/services/authz/`, SpiceDB, guard tests | Changing decision engine, guards, tenants |
| **authn-gateway** | `kamiwaza/services/auth/`, policy YAML, auth deps | Changing JWT, OIDC, SAML, RBAC policy |
| **enforce** | ingestion, retrieval, models, catalog, connectors | Changing code that *calls* auth guards |
| **posture** | `**/api/**`, `**/routes.py` | Route posture audit (manual only, `auto_select: false`) |
| **all** | Everything | Full audit (noisy, use sparingly) |

## How It Works

### Evidence lifecycle

1. **`auth_assurance.py run`** executes the configured runner for each profile
2. Results are written to `/tmp/auth-assurance/runs/<run_id>/run.json`
3. A state summary is persisted to `.state/last_run.json` (diff fingerprint, exit codes, timestamp)

### PreToolUse guard (`pre_tool_use_guard.py`)

Reads `.state/last_run.json` and the current diff fingerprint to make gating decisions:

| File category | Without evidence | With stale/failing evidence | With fresh PASS |
|---------------|------------------|-----------------------------|-----------------|
| Secrets (`.env`, SSH keys) | **DENY** | **DENY** | **DENY** |
| Policy files (`auth_gateway_policy*.yaml`) | **DENY** | **DENY** (requires authn-gateway PASS) | Allow |
| Auth surfaces (`services/auth/`, `services/authz/`) | **ASK** | **ASK** | Allow |
| Everything else | Allow | Allow | Allow |

### Stop orchestrator (`stop_orchestrator.py`)

- Reads stdin for `stop_hook_active` (prevents infinite loops)
- Checks `AUTH_ASSURANCE_ENABLED` kill-switch
- When `AUTH_ASSURANCE_AUTORUN=1`: auto-runs triggered profiles at end of each Claude turn
- Debounces by diff fingerprint (default 300s)

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `AUTH_ASSURANCE_ENABLED` | `0` | Kill-switch. Must be `1` for hooks to enforce |
| `AUTH_ASSURANCE_AUTORUN` | `0` | Enable auto-run on Stop hook |
| `AUTH_ASSURANCE_BASE_BRANCH` | `origin/develop` | Branch to diff against |
| `AUTH_ASSURANCE_DEBOUNCE_S` | `300` | Skip re-run if same fingerprint within N seconds |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | PASS |
| 1 | FAIL (lint/types/policy/tests) |
| 2 | TOOLING_ERROR (missing runner/config) |

## Evidence

```
/tmp/auth-assurance/runs/<run_id>/
├── run.json                    # Run metadata + per-profile results
└── profiles/
    ├── <profile>.log           # Full stdout/stderr
    └── <profile>.meta.json     # Structured result

/tmp/auth-assurance/security/<YYYYMMDD>/
└── <event_id>.json             # PreToolUse decision audit log
```

## Local Overrides

For per-developer customization without modifying tracked files:

- `config/profiles.local.json` — merge-override profile triggers
- `config/security_policy.local.json` — merge-override security policy

## Evolution from v1

v1 was shell-based (`run-auth-guardrails.sh` + bash hooks). v2 rewrites everything in Python for:
- Claude Code hook protocol compatibility (JSON stdin/stdout)
- Per-profile exit code gating (authn-gateway can gate policy files independently)
- Deterministic evidence fingerprinting (SHA-256 of diff file list)
- `stop_hook_active` guard against infinite loops
- `AUTH_ASSURANCE_ENABLED` kill-switch for cross-repo safety

## Files

| File | Purpose |
|------|---------|
| `bin/auth_assurance.py` | CLI executor (select, run, validate-policy) |
| `hooks/pre_tool_use_guard.py` | PreToolUse hook (file/bash gating) |
| `hooks/stop_orchestrator.py` | Stop hook (auto-run orchestration) |
| `config/profiles.json` | Profile definitions + trigger globs |
| `config/security_policy.json` | Access policy + bash blocklist |
