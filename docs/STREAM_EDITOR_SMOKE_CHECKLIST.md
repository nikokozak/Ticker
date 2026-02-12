# Stream Editor Smoke Checklist

Run this after every stream-editor slice.

## Setup

- Build app: `./tickerctl.sh build-dev`
- Open app and select an existing stream.

## Checklist

1. Open stream
- Open a stream from the default stream list.
- Confirm stream title/header and app-level navigation are unchanged.

2. Basic editing
- Type in an existing text cell.
- Create a new cell via keyboard flow used in current editor.
- Delete content and verify expected cell behavior.

3. Boundary keys
- Press Enter at end of a cell.
- Press Backspace at start of an empty/near-empty cell.
- Use Arrow Up/Down around cell boundaries.

4. Cross-cell selection + clipboard
- Select text spanning multiple cells.
- Copy, then paste into same stream.
- Reload stream and confirm pasted content persists without collisions.

5. Drag reorder
- Reorder at least two cells.
- Confirm visual order matches persisted order after reload.

6. AI actions
- Trigger `Send` on a selection.
- Trigger `Send with Prompt` and provide custom instruction.
- Trigger `Proofread` and `Summarize` on selections.
- Verify one undo returns selection to pre-AI state.

7. Persistence/reload
- Reload the stream view (or relaunch app).
- Confirm latest edits/reorder/AI results persisted correctly.

## Pass Criteria

All checks above pass with no app-shell behavior regressions.
