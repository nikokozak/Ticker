#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./run.sh [--dev|-d] [--prod|-p] [-h]

  -d, --dev   (default) Build Debug + run Vite dev server (app loads http://localhost:5173)
  -p, --prod  Build Release + run bundled web UI (no dev server)
  -h          Show this help

Notes:
  - This script builds an unsigned app (`CODE_SIGNING_ALLOWED=NO`) but will optionally
    codesign the built .app if `SIGN_IDENTITY` is set (recommended so macOS permissions
    like Accessibility/Screen Recording stick across rebuilds).
  - Distribution builds should follow the signing/notarization runbook.
  - Override build output location with DERIVED_DATA_PATH (or TICKER_DERIVED_DATA_PATH), e.g.:
      DERIVED_DATA_PATH=/tmp/ticker-xcode-build ./run.sh --prod
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$ROOT_DIR/tickerctl.local.sh"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
DERIVED_DATA_PATH_DEFAULT="$ROOT_DIR/.build/xcode"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TICKER_DERIVED_DATA_PATH:-$DERIVED_DATA_PATH_DEFAULT}}"
APP="$DERIVED_DATA_PATH/Build/Products"

MODE="dev"
while [[ $# -gt 0 ]]; do
  case "$1" in
  -d | --dev)
    MODE="dev"
    shift
    ;;
  -p | --prod)
    MODE="prod"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    usage
    exit 2
    ;;
  esac
done

codesign_app_if_configured() {
  local app_path="$1"

  if [[ "${TICKER_DISABLE_CODESIGN:-}" == "1" ]]; then
    return 0
  fi

  local identity="${SIGN_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    return 0
  fi

  if ! command -v codesign >/dev/null 2>&1; then
    echo "Warning: SIGN_IDENTITY is set but codesign is not available; skipping codesign." >&2
    return 0
  fi

  if [[ ! -d "$app_path" ]]; then
    echo "Warning: expected app bundle not found at: $app_path (skipping codesign)" >&2
    return 0
  fi

  echo "Code signing Ticker for stable macOS permissions..."
  set +e
  codesign --deep --force --sign "$identity" "$app_path" >/dev/null 2>&1
  local status=$?
  set -e

  if (( status != 0 )); then
    echo "Warning: codesign failed (SIGN_IDENTITY='$identity'). Permissions may re-prompt." >&2
    return 0
  fi

  # Best-effort verification (non-fatal).
  codesign --verify --deep "$app_path" >/dev/null 2>&1 || true
}

resolve_package_dependencies_if_needed() {
  local workspace_state="$DERIVED_DATA_PATH/SourcePackages/workspace-state.json"
  local sparkle_xcframework="$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework"

  if [[ -f "$workspace_state" ]] && grep -Fq "Sparkle.xcframework" "$workspace_state" && ! grep -Fq "$sparkle_xcframework" "$workspace_state"; then
    echo "Detected stale SwiftPM artifact paths in DerivedData; clearing: $DERIVED_DATA_PATH" >&2
    case "$DERIVED_DATA_PATH" in
    "$ROOT_DIR"/*) rm -rf "$DERIVED_DATA_PATH" ;;
    *)
      echo "Refusing to delete DerivedData outside repo root: $DERIVED_DATA_PATH" >&2
      echo "Try: ./tickerctl.sh clean-derived-data -y --derived-data \"$DERIVED_DATA_PATH\"" >&2
      return 1
      ;;
    esac
  fi

  if [[ -d "$sparkle_xcframework" ]]; then
    return 0
  fi

  echo "Resolving Swift package dependencies (Sparkle)..."
  xcodebuild -resolvePackageDependencies \
    -project Ticker.xcodeproj \
    -scheme Ticker \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -quiet
}

build_app() {
  local configuration="$1"

  echo "Building Ticker ($configuration)..."
  cd "$ROOT_DIR"

  resolve_package_dependencies_if_needed

  local -a extra_build_settings=()
  if [[ "$configuration" == "Release" ]]; then
    local build_number
    build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
    extra_build_settings+=("CURRENT_PROJECT_VERSION=$build_number")
  fi

  local log_path
  log_path="$(mktemp -t ticker-xcodebuild.XXXXXX.log)"

  local -a cmd=(
    xcodebuild build
    -project Ticker.xcodeproj
    -scheme Ticker
    -configuration "$configuration"
    -destination 'platform=macOS'
    -derivedDataPath "$DERIVED_DATA_PATH"
    CODE_SIGNING_ALLOWED=NO
    -quiet
  )
  if [[ ${#extra_build_settings[@]} -gt 0 ]]; then
    cmd+=("${extra_build_settings[@]}")
  fi

  set +e
  "${cmd[@]}" 2>&1 | tee "$log_path"
  local status="${PIPESTATUS[0]}"
  set -e

  if (( status != 0 )); then
    if grep -Fq "There is no XCFramework found" "$log_path" && grep -Fq "Sparkle.xcframework" "$log_path"; then
      echo "Tip: missing Sparkle XCFramework usually means stale SwiftPM artifacts." >&2
      echo "Try: ./tickerctl.sh clean-derived-data -y" >&2
    fi
  fi

  rm -f "$log_path" 2>/dev/null || true
  return "$status"
}

run_dev() {
  local app_path="$APP/Debug/Ticker.app"
  local bin_path="$app_path/Contents/MacOS/Ticker"

  build_app "Debug"
  codesign_app_if_configured "$app_path"

  echo "Cleaning up port 5173..."
  lsof -ti:5173 | xargs kill -9 2>/dev/null || true

  echo "Starting Vite dev server..."
  (cd "$ROOT_DIR/Web" && npm run dev) &
  local vite_pid=$!
  trap "kill $vite_pid 2>/dev/null || true" EXIT

  sleep 2

  if [[ ! -x "$bin_path" ]]; then
    echo "Error: expected app executable not found at: $bin_path" >&2
    echo "Build output should be at: $app_path" >&2
    exit 1
  fi

  echo "Running Ticker (dev)..."
  "$bin_path"
}

run_prod() {
  local app_path="$APP/Release/Ticker.app"

  echo "Building bundled Web assets..."
  if [[ ! -d "$ROOT_DIR/Web/node_modules" ]]; then
    (cd "$ROOT_DIR/Web" && npm ci)
  fi
  (cd "$ROOT_DIR/Web" && npm run build)

  build_app "Release"
  codesign_app_if_configured "$app_path"

  if [[ ! -d "$app_path" ]]; then
    echo "Error: expected app bundle not found at: $app_path" >&2
    exit 1
  fi

  echo "Launching Ticker (prod)..."
  open "$app_path"
}

case "$MODE" in
dev) run_dev ;;
prod) run_prod ;;
*)
  echo "Invalid mode: $MODE" >&2
  exit 2
  ;;
esac
