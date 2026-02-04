# Promotion Checklist - Auth Guardrails v2

Criteria for moving from personal `.claude/auth_assurance/` to shared team tooling.

## Stability (must all be true)

- [x] Hook-loop fix: `stop_hook_active` guard prevents infinite Stop hook recursion
- [x] Kill-switch: `AUTH_ASSURANCE_ENABLED` prevents cross-repo interference
- [x] Hooks wired in `settings.local.json` (repo-scoped), NOT global `settings.json`
- [x] Per-profile exit code gating (authn-gateway gates policy files independently)
- [x] Defensive int() cast for profile exit codes
- [ ] Ran successfully on 10+ real auth changes without false positives
- [ ] No silent fallbacks — fails fast on error conditions
- [ ] Base branch resolution is deterministic (no HEAD~N fallbacks)
- [ ] Evidence artifacts are complete and parseable

## Documentation (must all exist)

- [x] Clear usage instructions (README.md)
- [x] Environment variable reference
- [x] Evidence artifact locations documented
- [ ] STOP conditions documented with remediation steps
- [ ] Integration point with `/git-push` documented

## Testing (must all pass)

- [ ] Python hooks work on macOS (verified manually)
- [ ] Python hooks work on Linux
- [ ] Works with both local and CI environments
- [ ] Handles edge cases: no auth changes, fresh clone, detached HEAD
- [ ] Unit tests for `_select_profiles`, `_fingerprint`, `_match_any`

## Integration (must be reviewed)

- [ ] `/git-push` integration tested with real workflow
- [ ] Non-skippable behavior confirmed
- [ ] Failure messaging is clear and actionable
- [ ] At least one team member has reviewed the approach

## Promotion Steps

When all boxes are checked:

1. Copy to shared location in target repo:
   ```bash
   cp -r .claude/auth_assurance/ <target>/.claude/auth_assurance/
   ```

2. Add hook wiring instructions to repo CLAUDE.md or onboarding docs

3. Open PR with skill contract, hooks, and updated `/git-push` integration

4. Socialize: demo in standup, document in runbook

## Rollback

1. Remove `.claude/auth_assurance/` from target repo
2. Remove hook entries from `settings.local.json`
3. Document what went wrong
