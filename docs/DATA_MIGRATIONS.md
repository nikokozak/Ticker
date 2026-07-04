# Data Storage & Migrations

Ticker is a note-taking app. Data integrity is a core product feature.

## Standard data location (macOS)

Use:
- `~/Library/Application Support/Ticker-Next/`

This fork-isolated directory is intentional. Ticker-Next must not read from or write to the legacy Ticker app's Application Support directory unless a future migration explicitly asks the user to import that data.

Avoid:
- `~/.config/ticker/` (non-standard on macOS, surprises users and support)
- `~/Library/Application Support/Ticker/` for Ticker-Next runtime writes (belongs to the legacy app)

Key files:
- `ticker.db` — SQLite database for streams, stream documents, sources, legacy migration history, and device metadata references.
- `assets/` — local asset files addressed from markdown as `ticker-asset://...`.
- `backups/` — timestamped SQLite backups created before pending schema/content migrations.

## Current document-model migrations

- `v10_stream_documents` creates `stream_documents` as the canonical stream markdown table.
- `v11_recover_orphaned_quickpanel_cells` folds captures that were stranded in legacy `cells` rows into existing documents.
- `v12_seed_documents_from_legacy_cells` seeds document rows for legacy streams that only had cells.
- `v13_stream_document_revision` adds document revisions for conflict-aware saves.

The `cells` table is frozen legacy history. It remains available to migrations/recovery, but active editor and capture writes target `stream_documents`.

## Migration policy (non-negotiable)

### Before any schema migration
- Copy the SQLite DB to a timestamped backup:
  - Create backups only when migrations are pending (avoid doing this on every launch)
  - Keep last N backups (alpha default: 5)
  - Store alongside the DB under `~/Library/Application Support/Ticker-Next/backups/`

### Before any content migration
- Treat rewrites of stream document content as migrations (not “just a UI change”) and follow the same backup/rollback posture.
- Current direction: migration from legacy cell-oriented content to a single stream-document model is a first-class migration event.
- Migration planning should explicitly define:
  - source shape (legacy cell rows, metadata)
  - target shape (stream document + anchor metadata)
  - idempotency behavior
  - rollback strategy using backup snapshots

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
