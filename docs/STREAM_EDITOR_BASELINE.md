# Stream Editor Baseline (Phase E0)

Date: 2026-02-12

This file captures the starting baseline before active UX slices.

## Current Editor Paths

- Primary editor path: `Web/src/components/UnifiedStreamEditor.tsx`
- Legacy/fallback path: `Web/src/components/StreamEditor.tsx`
- Unified editor feature flag: `Web/src/utils/featureFlags.ts` (`unified` URL override supported)

## Core Constraints Already Present

- Document schema uses `cellBlock` nodes with UUID-backed identity (`Web/src/extensions/CellBlock.ts`).
- Paste path rewrites pasted cell UUIDs to avoid persistence collisions (`Web/src/extensions/CellClipboard.ts`).
- Boundary key handling logic is centralized in `Web/src/extensions/CellKeymap.ts`.
- Drag reorder behavior has dedicated logic and persistence sync in unified editor.

## Known Risk Zones (Regression-Sensitive)

1. Cross-cell selection and structural deletes.
2. Cell creation/deletion at boundary keystrokes.
3. Reorder operations and persistence sync timing.
4. Bridge message sequencing under streaming AI updates.

## Guardrail for Upcoming Slices

Unless explicitly requested by user:
- do not modify app-level navigation/window flow
- do not change settings/help access behavior
- do not migrate away from WKWebView/React/TipTap

## Baseline Validation Gate

Use `docs/STREAM_EDITOR_SMOKE_CHECKLIST.md` after each slice.
