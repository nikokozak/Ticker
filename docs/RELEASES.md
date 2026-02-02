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
- Signed + notarized build produced (see `docs/MAC_DISTRIBUTION.md`)
- Sparkle appcast updated and published
- Rollback available: last 2–3 releases remain in appcast
- Manual QA: drag a PNG into a stream → image appears; drag a PDF → source appears

## Rollback policy

If a release is broken:
- Prefer to ship a fast follow-up patch (`YYYY.MM.(patch+1)`)
- Ensure appcast still lists the last known good release
- Document manual downgrade steps for testers (link in `/alpha` page)
