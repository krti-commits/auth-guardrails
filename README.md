# Auth Guardrails - Personal Tooling

Private workflow tooling for Auth guardrails covering the **full authentication + authorization surface**. Globally ignored, stays private.

## TL;DR

**Run:**
- Clean repo: `./.claude/local/run-auth-guardrails.sh develop`
- With Auth changes (zsh/macOS):
  ```zsh
  ALLOW_DIRTY=1 ./.claude/local/run-auth-guardrails.sh develop | tee /tmp/auth_run.log
  echo "exit=${pipestatus[1]}"
  ```
- With Auth changes (bash):
  ```bash
  ALLOW_DIRTY=1 ./.claude/local/run-auth-guardrails.sh develop | tee /tmp/auth_run.log
  echo "exit=${PIPESTATUS[0]}"
  ```
- With logging (recommended):
  ```bash
  ALLOW_DIRTY=1 LOG_RUNS=1 ./.claude/local/run-auth-guardrails.sh develop
  ```

> **Note:** This directory is globally ignored (`~/.config/git/ignore`). Do not commit.

**What it does:** preflight → shellcheck → baseline → lint/types/tests → writes `RESULT: PASS|FAIL`

**Evidence:** `/tmp/claude-baseline/{pre,post}/auth/<timestamp>/`

**Run log:** `~/auth-guardrails-runs.log` (when `LOG_RUNS=1`)

**Exit codes:** 0=PASS, 1=FAIL, 2=TOOLING_ERROR

**Promotion:** Copy to `.claude/shared/` and PR when ready (see `PROMOTE.md`)

---

## Scope: Full Auth Surface

This workflow covers **both authentication and authorization**:

### Source Paths
| Path | Purpose |
|------|---------|
| `kamiwaza/services/auth/` | Authentication (Keycloak, OIDC, SAML, CAC, JWT, sessions) |
| `kamiwaza/services/authz/` | Authorization (SpiceDB, decision engine, guards, tenants) |
| `kamiwaza/dependencies/auth.py` | Shared auth dependencies |

### Test Paths
| Path | Purpose |
|------|---------|
| `tests/unit/services/auth/` | Authentication unit tests |
| `tests/unit/services/authz/` | Authorization unit tests |
| `tests/integration/services/auth/` | Integration tests |

### Auth Modes Covered
| Mode | Status | Description |
|------|--------|-------------|
| **RBAC** | ✅ | File-based policy (`auth_gateway_policy.yaml`) |
| **ReBAC** | ✅ | Relationship-based (SpiceDB + PostgreSQL) |
| **Clearance** | ✅ | CAPCO classification hierarchy |
| **Auth Off** | ✅ | `AUTH_REBAC_ENABLED=false` |
| **ABAC** | 🔜 | Future (attribute-based) |

---

## What Runs

1. **Preflight check** - Refuses to run if repo has changes outside `.claude/local/` (skip with `ALLOW_DIRTY=1`)
2. **Shellcheck** - Validates hook scripts
3. **Pre-edit baseline** - Captures git state and runs tests
4. **Post-edit verification** - Runs lint/types/tests across all auth paths

## Quality Gates

- **Lint check**: `make check-python-lint-new-code`
- **Type check**: `make check-python-types-new-code`
- **Tests**: Runs across all auth-related test directories

## Evidence Artifacts

Artifacts are written to timestamped directories:

```
/tmp/claude-baseline/
├── pre/auth/{timestamp}/    # Baseline before changes
│   ├── diff.txt
│   ├── status.txt
│   ├── tests.txt
│   └── tests_result.txt
└── post/auth/{timestamp}/   # Verification after changes
    ├── lint.txt
    ├── types.txt
    ├── tests.txt
    └── result.txt           # PASS or FAIL
```

## STOP Conditions

The workflow will STOP and refuse to proceed if:

1. **Preflight fails** - Changes exist outside `.claude/local/`
2. **Shellcheck fails** - Hook scripts have issues
3. **Make targets missing** - Required Makefile targets don't exist
4. **Lint fails** - Ruff found errors in changed files
5. **Types fail** - Mypy found errors in changed files
6. **Tests fail** - Auth tests don't pass

## Files

```
.claude/local/
├── run-auth-guardrails.sh   # Main entrypoint
├── hooks/
│   ├── preflight.sh         # Scope guard
│   ├── pre-edit.sh          # Baseline capture
│   └── post-edit.sh         # Verification
├── templates/
│   └── skill-contract.md    # Reusable template
├── authz-guardrails/
│   └── SKILL.md             # Skill contract spec
├── README.md                # This file
└── PROMOTE.md               # Graduation checklist
```

## Privacy

This tooling is globally ignored via `~/.config/git/ignore`:
```
.claude/local/
```

It will NOT be committed unless you explicitly force-add it.

## Logging

When `LOG_RUNS=1`, each run appends to `~/auth-guardrails-runs.log`:

```
2026-01-23T03:00:00-0800  branch=feature/auth-fix  base=develop  domain=auth  exit=0  result=PASS  evidence=/tmp/...
```

Use this to track run history and evaluate false positive rates over time.
