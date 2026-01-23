# Auth Guardrails - Profile-Based Tooling

Private workflow tooling for Auth guardrails with **profile-based scoping**. Runs only what's relevant to your changes.

## TL;DR

```bash
# Authorization decision engine (SpiceDB, guards, tenants)
ALLOW_DIRTY=1 ./.claude/local/run-auth-guardrails.sh authz-core develop

# Authentication gateway (Keycloak, OIDC, SAML, JWT, policy files)
ALLOW_DIRTY=1 ./.claude/local/run-auth-guardrails.sh authn-gateway develop

# Guard enforcement callers (ingestion, retrieval, catalog, models)
ALLOW_DIRTY=1 ./.claude/local/run-auth-guardrails.sh enforce develop

# Full surface (noisy - avoid unless needed)
ALLOW_DIRTY=1 ./.claude/local/run-auth-guardrails.sh all develop
```

Add `LOG_RUNS=1` to build run history in `~/auth-guardrails-runs.log`.

---

## Profiles

| Profile | Scope | When to Use |
|---------|-------|-------------|
| **authz-core** | `kamiwaza/services/authz/` | Changing decision engine, guards, SpiceDB backend |
| **authn-gateway** | `kamiwaza/services/auth/` + policy files | Changing JWT, Keycloak, OIDC, SAML, RBAC policy |
| **enforce** | Ingestion, retrieval, catalog, models | Changing code that *calls* auth guards |
| **all** | Everything above | Full audit (noisy, use sparingly) |

### Profile Details

#### authz-core
- **Source**: `kamiwaza/services/authz/`
- **Tests**: `tests/unit/services/authz/`
- **Checks**: lint, types, tests

#### authn-gateway
- **Source**: `kamiwaza/services/auth/`
- **Tests**: `tests/unit/services/auth/`
- **Policy**: `config/auth_gateway_policy.yaml` (YAML validation)
- **Checks**: lint, types, policy syntax, tests

#### enforce
- **Source**: Services that import/call guard helpers
- **Tests**: `tests/unit/services/{ingestion,retrieval,catalog,models}/`
- **Checks**: lint, types, tests
- **Note**: Catches issues when guard enforcement changes but authz core doesn't

---

## Why Profiles?

From the `rebac_guard_audit.md` doc:

> "Auth isn't just `authz/`. There's a real authn/auth-gateway layer in `kamiwaza/services/auth/`, and ReBAC guard usage is spread across other services."

Running everything always is **noisy**. Profiles keep it:
- **Truthful**: Runs what's relevant to your changes
- **Fast**: Doesn't waste time on unrelated tests
- **Actionable**: Failures mean something

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | PASS |
| 1 | FAIL (lint/types/policy/tests) |
| 2 | TOOLING_ERROR (preflight, shellcheck, missing make targets) |

---

## Evidence

```
/tmp/claude-baseline/post/{profile}/{timestamp}/
├── lint.txt
├── types.txt
├── policy.txt    # authn-gateway only
├── tests.txt
└── result.txt
```

---

## Run Log

When `LOG_RUNS=1`, each run appends to `~/auth-guardrails-runs.log`:

```
2026-01-23T03:00:00-0800  profile=authz-core  branch=feature/x  base=develop  exit=0  result=PASS  evidence=/tmp/...
```

---

## Questions for Matt (CTO)

Per `rebac_guard_audit.md`, the valuable CTO-level questions are:

1. **What's the canonical "auth surface" list?** (paths + policy files)
2. **Do we want a router posture manifest + introspection test?** (per the audit plan doc)
3. **Should enforcement-callers be considered part of AuthZ guardrails, or owned by each service?**

---

## Files

```
.claude/local/
├── run-auth-guardrails.sh   # Profile-based entrypoint
├── hooks/
│   ├── preflight.sh
│   ├── pre-edit.sh
│   └── post-edit.sh
├── README.md                # This file
└── PROMOTE.md               # Graduation checklist
```

---

## Privacy

Globally ignored via `~/.config/git/ignore`. Will NOT be committed unless force-added.
