---
name: verify
description: Build, launch, and drive Ticker-Next end-to-end on this Mac (GUI app + Vite dev lane) to verify changes at the user surface.
---

# Verifying Ticker-Next changes

## Build & launch
- Build gate: `./tickerctl.sh build-dev` (xcodebuild). Plain `swift build` is broken (mlx-swift-lm/sandbox) — don't fight it.
- Stale Sparkle artifact error → `./tickerctl.sh clean-derived-data -y` then rebuild.
- Run: `./tickerctl.sh run-dev` in background (starts Vite on :5173 + launches `~/Applications/Ticker Next.app`). Wait ~20s; check `curl localhost:5173` and `pgrep -fl "Ticker Next"`.
- **Check for stale instances first**: `pgrep -fl "Ticker Next"` — kill old PIDs (`kill -TERM`) or two processes share one SQLite DB and the old code confounds results.
- A Sparkle "Check for updates?" dialog may block on launch. Dismiss: `osascript -e 'tell application "System Events" to tell process "TickerNext" to click button "Don’t Check" of window 2'` (note curly apostrophe; process name is `TickerNext`, app name is `Ticker Next`).

## Data safety
- DB: `~/Library/Application Support/Ticker-Next/ticker.db` (real user data, lane-independent!). ALWAYS `cp` it to scratchpad before driving, restore/clean afterwards (quit app first so the editor doesn't re-save over your cleanup).
- Inspect: `sqlite3 ... "SELECT markdown FROM stream_documents WHERE ..."`.

## Driving the GUI
- Quick Panel: global hotkey ⌘L → `osascript`: activate "Ticker Next", `keystroke "l" using command down`, then `keystroke "<text>"`, `key code 36` (↵). ⌘↵ = `key code 36 using command down`; ⌥↵ = `using option down`.
- Web content (stream list, editor) has no usable AX tree — click by coordinates with CGEvent:
  `swift -e 'import CoreGraphics; let pt=CGPoint(x:X,y:Y); for t in [CGEventType.leftMouseDown, .leftMouseUp] { CGEvent(mouseEventSource:nil,mouseType:t,mouseCursorPosition:pt,mouseButton:.left)!.post(tap:.cghidEventTap); usleep(60000) }'`
  Coordinates are screen POINTS = screenshot-pixels ÷ 2 (Retina). Take `screencapture -x <path>` first, Read it, compute.
- Observe: `screencapture -x` (silent, full screen) + Read the PNG.

## Flows worth driving
- Capture → closed stream: ⌘L, type, ↵; check `stream_documents.markdown` in sqlite; open stream and confirm visible.
- Capture → open stream (live append): open stream first, ⌘L, type, ↵; text must appear in editor within ~1s without reload.
- Race: click into editor, type, immediately ⌘L-capture; both must persist after autosave (350ms debounce).
- Cleanup: quit app, restore the touched stream's markdown from the backup DB (ATTACH + UPDATE), kill the run-dev background task.
