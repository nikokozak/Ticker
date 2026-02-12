# Stream Editor Baseline (Phase E0)

Date: 2026-02-12

This file captures the starting baseline before active UX slices.

## Current Editor Paths

- Canonical editor path: `Web/src/components/StreamEditor.tsx`
- Outline/sources are surfaced from the stream editor via an overlay drawer (not a persistent split pane).

## Core Constraints Already Present

- Document schema uses `cellBlock` nodes with UUID-backed identity (`Web/src/extensions/CellBlock.ts`).
- Paste path rewrites pasted cell UUIDs to avoid persistence collisions (`Web/src/extensions/CellClipboard.ts`).
- Boundary key handling logic is centralized in `Web/src/extensions/CellKeymap.ts`.
- Drag reorder behavior is implemented in the stream editor block wrappers and persisted through bridge save/reorder flows.

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
