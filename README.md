# AuthZ Guardrails - Personal Tooling

Private workflow tooling for D120 AuthZ guardrails. Globally ignored, stays private.

## TL;DR

**Run:**
- Clean repo: `./.claude/local/run-authz-guardrails.sh develop`
- With AuthZ changes (zsh/macOS):
  ```zsh
  ALLOW_DIRTY=1 ./.claude/local/run-authz-guardrails.sh develop | tee /tmp/authz_run.log
  echo "exit=${pipestatus[1]}"
  ```
- With AuthZ changes (bash):
  ```bash
  ALLOW_DIRTY=1 ./.claude/local/run-authz-guardrails.sh develop | tee /tmp/authz_run.log
  echo "exit=${PIPESTATUS[0]}"
  ```

> **Note:** This directory is globally ignored (`~/.config/git/ignore`). Do not commit.

**What it does:** preflight → shellcheck → baseline → lint/types/tests → writes `RESULT: PASS|FAIL`

**Evidence:** `/tmp/claude-baseline/{pre,post}/authz/<timestamp>/`

**Exit codes:** 0=PASS, 1=FAIL; evidence path printed at end

**Promotion:** Copy to `.claude/shared/` and PR when ready (see `PROMOTE.md`)

---

## What This Does

Enforces quality gates on AuthZ-critical code changes:
- **Lint check**: `make check-python-lint-new-code`
- **Type check**: `make check-python-types-new-code`
- **Tests**: `make test ARGS=tests/unit/services/authz/`

Captures evidence artifacts for audit trail.

## What Runs

1. **Preflight check** - Refuses to run if repo has changes outside `.claude/local/` (skip with `ALLOW_DIRTY=1`)
2. **Shellcheck** - Validates hook scripts
3. **Pre-edit baseline** - Captures git state before changes
4. **Post-edit verification** - Runs lint/types/tests

## Evidence Artifacts

Artifacts are written to timestamped directories:

```
/tmp/claude-baseline/
├── pre/authz/{timestamp}/   # Baseline before changes
│   ├── diff.txt
│   ├── status.txt
│   └── tests.txt
└── post/authz/{timestamp}/  # Verification after changes
    ├── lint.txt
    ├── types.txt
    ├── tests.txt
    └── result.txt           # PASS or FAIL
```

## STOP Conditions

The workflow will STOP and refuse to proceed if:

1. **Preflight fails** - Changes exist outside `.claude/local/`
2. **Shellcheck fails** - Hook scripts have issues
3. **Lint fails** - Ruff found errors in changed files
4. **Types fail** - Mypy found errors in changed files
5. **Tests fail** - AuthZ tests don't pass

## Files

```
.claude/local/
├── run-authz-guardrails.sh  # Main entrypoint
├── hooks/
│   ├── preflight.sh         # Scope guard
│   ├── pre-edit.sh          # Baseline capture
│   └── post-edit.sh         # Verification
├── templates/
│   └── skill-contract.md    # Reusable template
├── authz-guardrails/
│   └── SKILL.md             # D120 contract spec
├── README.md                # This file
└── PROMOTE.md               # Graduation checklist
```

## Privacy

This tooling is globally ignored via `~/.config/git/ignore`:
```
.claude/local/
```

It will NOT be committed unless you explicitly force-add it.
