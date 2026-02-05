# Data Storage & Migrations

Ticker is a note-taking app. Data integrity is a core product feature.

## Standard data location (macOS)

Use:
- `~/Library/Application Support/Ticker/`

Avoid:
- `~/.config/ticker/` (non-standard on macOS, surprises users and support)

## Migration policy (non-negotiable)

### Before any schema migration
- Copy the SQLite DB to a timestamped backup:
  - Create backups only when migrations are pending (avoid doing this on every launch)
  - Keep last N backups (alpha default: 5)
  - Store alongside the DB under Application Support

### Before any content migration
- Treat rewrites of `cells.content` as migrations (not “just a UI change”) and follow the same backup/rollback posture.
- Example: `v9_heading_in_content_titles` prepends an `<h2>` heading derived from legacy `cells.restatement` when the cell content has no existing heading.

### Before any location migration
- Copy the entire data directory to a timestamped backup.

### Failure handling

- If migration fails:
  - keep the original DB intact
  - surface a clear error to the user
  - provide a “copy support bundle” path (request IDs, versions, error message)

## Compatibility posture (alpha)

- Migrations should be forward-only, but releases must retain a downgrade path via appcast history.
- Avoid breaking schema changes unless the migration is thoroughly tested on real data snapshots.
