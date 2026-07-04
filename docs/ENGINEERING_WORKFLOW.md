# Engineering Workflow

This is the required workflow for sustainable development and onboarding new contributors.

## Core policy

- **No direct pushes to `main`.** Use PRs only.
- **All work begins as a GitHub Issue** with acceptance criteria.
- **CI must pass** before merge.
- **At least one human review** is required for merge (even if the PR was AI-assisted).

## Issue templates (minimum fields)

### Bug
- Problem statement
- Steps to reproduce
- Expected vs actual
- Screenshots/recording if UI-related
- Impact/severity (P0/P1/P2)
- Acceptance criteria

### Feature
- User problem + goal
- Non-goals
- UX acceptance criteria
- Analytics/telemetry impact (if any)
- Rollout notes (feature flag / safe default if needed)

## Branch naming

- `feature/<short-slug>`
- `fix/<issue-123>-<short-slug>`
- `chore/<short-slug>`

## PR requirements

Every PR includes:
- Linked Issue
- Summary of changes
- Test plan (what was run, how to verify)
- Compatibility notes (data migration? bridge/proxy schema changes?)
- Rollback plan (or “revert PR is safe”)
- `CHANGELOG.md` entry if user-facing

## Definition of Done (DoD)

- Acceptance criteria met
- CI green
- No schema break without versioning + compatibility plan
- Migration includes backup and failure handling
- User-facing changes documented in `CHANGELOG.md`

## CI baseline (must exist)

- Preferred single entry point: `./tickerctl.sh preflight-alpha`
- Swift: `./tickerctl.sh swift-test` (runs `xcodebuild test`, no code signing)
- Web: `./tickerctl.sh web-typecheck`
- Web unit tests: `cd Web && npm test`
- Bridge contract: `./tickerctl.sh contracts`

## Review checklist (fast but strict)

- Does this change affect persistence or identifiers? (UUID invariants, migrations)
- Does this change affect bridge messages? (run contract tests; update `docs/contracts/bridge.v1.json`)
- Does this change affect the proxy contract? (versioned request/response changes)
- Are errors user-readable and actionable?
- Are we collecting any new diagnostics? (update `docs/PRIVACY_DIAGNOSTICS.md`)
