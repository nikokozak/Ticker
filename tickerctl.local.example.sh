#!/bin/bash

# Copy to `tickerctl.local.sh` (gitignored) and edit.

# Developer ID identity for codesign (see: security find-identity -p codesigning -v)
SIGN_IDENTITY='Developer ID Application: Nikolai Kozak (Z5DX2YK8FA)'

# Optional: bundle/id defaults for dual-lane local runs (stable + QA).
# Stable lane (default commands: run-dev / run-prod)
# APP_BUNDLE_ID='io.ticker.next'
# APP_NAME='Ticker Next'
# APP_PRODUCT_NAME='TickerNext'
# STABLE_APP_DISPLAY_NAME='Ticker Next'
# STABLE_APP_PRODUCT_NAME='TickerNext'
# STABLE_APP_INSTALL_PATH="$HOME/Applications/Ticker Next.app"
#
# QA lane (commands: run-dev-qa / run-prod-qa)
# QA_APP_BUNDLE_ID='io.ticker.next.qa'
# QA_APP_DISPLAY_NAME='Ticker Next QA'
# QA_APP_INSTALL_PATH="$HOME/Applications/Ticker Next QA.app"

# App data directory overrides
# APP_SUPPORT_DIR="$HOME/Library/Application Support/Ticker-Next"
# DEVICE_JSON_PATH="$APP_SUPPORT_DIR/device.json"

# notarytool Keychain profile name created via:
#   xcrun notarytool store-credentials AC_PASSWORD --apple-id ... --team-id ... --password <APP_SPECIFIC_PASSWORD>
NOTARY_PROFILE='AC_PASSWORD'

# Sparkle CLI tools extracted under tools/sparkle/
# Depending on the Sparkle archive layout, this may be:
#   ./tools/sparkle/bin
# or:
#   ./tools/sparkle/Sparkle/bin
SPARKLE_BIN='./tools/sparkle/Sparkle/bin'

# Repo that hosts public update zips (Sparkle must be able to download without GitHub login)
# If your source repo is private, use a separate public repo here.
UPDATES_REPO_SLUG='nikokozak/Streams'

# Optional: commit/branch/tag in UPDATES_REPO_SLUG that the release tag should point to.
# If omitted and UPDATES_REPO_SLUG matches your local `origin`, tickerctl uses `HEAD`.
# If UPDATES_REPO_SLUG is a separate updates-only repo, set this to its default branch:
# UPDATES_RELEASE_TARGET='main'

# Path to your gh-pages worktree (recommended: separate from your source checkout)
# Example:
#   git worktree add ../Streams-gh-pages gh-pages
APPCAST_REPO_DIR="$HOME/Developer/Streams-gh-pages"
APPCAST_FILENAME='appcast-alpha.xml'
APPCAST_MAX_ITEMS='3'

MIN_MACOS='14.0'
