# Releases (Alpha)

Ticker releases must be **repeatable**, **tagged**, and have a **rollback path**.

## Version scheme

Use `YYYY.MM.patch` (alpha), e.g. `2026.01.3`.

## Release artifacts

Recommended hosting layout:
- **GitHub Releases**: binaries (`.dmg`/`.zip`) + Sparkle signatures
- **GitHub Pages** (or Fly static): a stable URL for the Sparkle appcast feed (`appcast-alpha.xml`)

Rationale: GitHub asset URLs typically redirect; Sparkle update checks are more reliable with a stable appcast URL.

## Minimum release checklist

- `CHANGELOG.md` updated for the release
- Tag created: `vYYYY.MM.patch`
- Preflight checks pass:
  - `./tickerctl.sh preflight-alpha`
- Signed + notarized build produced (see `docs/MAC_DISTRIBUTION.md`)
- Sparkle appcast updated and published
- Rollback available: last 2–3 releases remain in appcast
- Manual QA: generate an AI response containing `![x](https://example.com/x.png)` → no image loads (and no external network request is triggered)

## Recommended flow (smoke test before publish)

1) Build a tester artifact (no publish):
   - `./tickerctl.sh release-alpha --version YYYY.MM.patch`

2) Run the manual smoke pass on the built artifact:
   - `docs/TEST_STRATEGY.md`
   - `docs/ALPHA_READINESS_CHECKLIST.md`

3) Promote the already-tested artifact (no rebuild):
   - `./tickerctl.sh release-alpha --version YYYY.MM.patch --skip-build --promote`

## Rollback policy

If a release is broken:
- Prefer to ship a fast follow-up patch (`YYYY.MM.(patch+1)`)
- Ensure appcast still lists the last known good release
- Document manual downgrade steps for testers (link in `/alpha` page)
