#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./tickerctl.sh [command] [options]

Commands:
  help [command]       Show help/manual (more verbose than --help)
  menu                 Interactive menu (default)
  preflight-alpha      Run preflight checks (contracts + web typecheck + swift tests)
  contracts            Run bridge contract tests (if present in this checkout)
  web-typecheck        Run Web TypeScript typecheck
  swift-test           Run Swift tests (xcodebuild test, no code signing)
  clean-derived-data    Delete repo-local Xcode DerivedData (fixes stale SPM artifacts)
  install-sparkle-tools  Install Sparkle CLI tools into ./tools/sparkle (from SwiftPM artifacts)
  build-dev            Build Debug app (unsigned)
  run-dev              Build Debug + run (starts Vite dev server)
  build-prod           Build Release app (unsigned, bundles web UI)
  run-prod             Build Release + run (bundled web UI)
  release-alpha        Build+sign+notarize+zip+Sparkle-sign (+ optional publish/appcast)
  reset-onboarding     Clear onboarding completion flag (shows onboarding on next launch)
  reset-proxy-soft     Clear Device Key but keep device_id (edits Application Support file)
  reset-proxy-hard     Delete device.json (new device_id on next launch)
  reset-accessibility  Reset Accessibility permission (TCC) for Ticker
  reset-proxy-url      Clear proxy URL override (UserDefaults)
  reset-diagnostics    Clear diagnostics opt-out (UserDefaults; defaults to ON)
  reset-all            Convenience reset (onboarding + proxy-hard + proxy-url + diagnostics)
  versions             Print version + build number for HEAD

Common options:
  --derived-data PATH          DerivedData path for build outputs (default: ./.build/xcode)

release-alpha options:
  --version X.Y.Z             Required. Marketing version, e.g. 2025.12.1
  --derived-data PATH         Release DerivedData path (default: ./.build/xcode-release)
  --skip-build                Reuse existing artifact + signature from .build/releases/vX.Y.Z/release.env
  --publish                   Create a GitHub Release via `gh` and upload the zip
  --update-appcast            Update appcast in APPCAST_REPO_DIR (requires config)
  --commit-appcast            Commit the appcast change (requires config)
  --push-appcast              Push the gh-pages commit (requires config)
  --promote                   Equivalent to --publish --update-appcast --commit-appcast --push-appcast
  --allow-dirty               Allow releasing with uncommitted changes (not recommended)

Config (optional):
  Create `tickerctl.local.sh` (gitignored) to set defaults:
    SIGN_IDENTITY='Developer ID Application: Name (TEAMID)'
    NOTARY_PROFILE='AC_PASSWORD'
    SPARKLE_BIN='./tools/sparkle/Sparkle/bin'
    UPDATES_REPO_SLUG='owner/repo'         # where the update zip is hosted
    APPCAST_REPO_DIR='/path/to/gh-pages-worktree'   # recommended: separate worktree
    APPCAST_FILENAME='appcast-alpha.xml'
    APPCAST_MAX_ITEMS='3'
    MIN_MACOS='14.0'

Notes:
  - Dev/prod commands build unsigned (CODE_SIGNING_ALLOWED=NO).
  - Sparkle update testing requires an older build installed in /Applications
    and a newer build published in the appcast.
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$ROOT_DIR/tickerctl.local.sh"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

APP_BUNDLE_ID="${APP_BUNDLE_ID:-io.ticker.app}"
TICKER_APP_SUPPORT_DIR="${TICKER_APP_SUPPORT_DIR:-$HOME/Library/Application Support/Ticker}"
TICKER_DEVICE_JSON_PATH="${TICKER_DEVICE_JSON_PATH:-$TICKER_APP_SUPPORT_DIR/device.json}"

DERIVED_DATA_PATH_DEFAULT="$ROOT_DIR/.build/xcode"
RELEASE_DERIVED_DATA_PATH_DEFAULT="$ROOT_DIR/.build/xcode-release"
SPARKLE_TOOLS_ROOT_DEFAULT="$ROOT_DIR/tools/sparkle/Sparkle"
# Ignore a globally-exported DERIVED_DATA_PATH (stale after repo moves).
# Use --derived-data or TICKER_DERIVED_DATA_PATH instead.
DERIVED_DATA_PATH="${TICKER_DERIVED_DATA_PATH:-$DERIVED_DATA_PATH_DEFAULT}"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
SPARKLE_BIN="${SPARKLE_BIN:-$SPARKLE_TOOLS_ROOT_DEFAULT/bin}"
UPDATES_REPO_SLUG="${UPDATES_REPO_SLUG:-}"
UPDATES_RELEASE_TARGET="${UPDATES_RELEASE_TARGET:-}"
APPCAST_REPO_DIR="${APPCAST_REPO_DIR:-}"
APPCAST_FILENAME="${APPCAST_FILENAME:-appcast-alpha.xml}"
APPCAST_MAX_ITEMS="${APPCAST_MAX_ITEMS:-3}"
MIN_MACOS="${MIN_MACOS:-14.0}"

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || {
    echo "Missing required command: $name" >&2
    exit 1
  }
}

cmd_help() {
  local topic="${1:-}"

  if [[ -n "$topic" ]]; then
    case "$topic" in
    release-alpha)
      cat <<'EOF'
release-alpha

Builds a signed+notarized alpha artifact and prepares Sparkle update metadata.

Recommended flow (smoke test before publish):
  1) ./tickerctl.sh preflight-alpha
  2) ./tickerctl.sh release-alpha --version X.Y.Z
  3) Run manual smoke pass: docs/TEST_STRATEGY.md and docs/ALPHA_READINESS_CHECKLIST.md
  4) ./tickerctl.sh release-alpha --version X.Y.Z --skip-build --promote

Why split build vs promote?
- The build step produces an installable artifact you can test locally before publishing.
- The promote step reuses the exact zip + Sparkle signature from:
    ./.build/releases/vX.Y.Z/release.env
EOF
      return 0
      ;;
    preflight-alpha)
      cat <<'EOF'
preflight-alpha

Runs cheap checks that catch “protocol breakage” before you ship:
- Bridge contract tests (if present in this checkout)
- Web TypeScript typecheck
- Swift tests (xcodebuild test, no code signing; builds Web assets first)

Run it:
  ./tickerctl.sh preflight-alpha
EOF
      return 0
      ;;
    swift-test)
      cat <<'EOF'
swift-test

Runs the Swift XCTest suite with code signing disabled.

Notes:
- Builds Web assets first (matches CI); the app target expects bundled Web output.
- Uses repo-local DerivedData by default: ./.build/xcode

Run it:
  ./tickerctl.sh swift-test
EOF
      return 0
      ;;
    *)
      echo "Unknown help topic: $topic" >&2
      usage
      return 2
      ;;
    esac
  fi

  usage

  cat <<'EOF'

Before sending a build to testers (recommended):

  1) Ensure all target PRs are merged and CI is green.

  2) Run automated preflight:
       ./tickerctl.sh preflight-alpha

  3) Build a signed+notarized tester artifact (no publish):
       ./tickerctl.sh release-alpha --version X.Y.Z

  4) Manual smoke pass (must be done on the built artifact):
     - docs/TEST_STRATEGY.md (stream CRUD, persistence restart, AI request flow)
     - docs/ALPHA_READINESS_CHECKLIST.md (release/proxy/support expectations)

  5) Promote the already-tested artifact (publish + update appcast):
       ./tickerctl.sh release-alpha --version X.Y.Z --skip-build --promote

If you come back after a break:
  - Start with: ./tickerctl.sh help
  - If builds fail due to stale SwiftPM artifacts: ./tickerctl.sh clean-derived-data -y
EOF
}

confirm_delete_dir() {
  local dir="$1"
  local prompt="${2:-}"

  if [[ -z "$prompt" ]]; then
    prompt="Delete directory '$dir'? [y/N] "
  fi

  echo -n "$prompt"
  local reply
  read -r reply
  case "$reply" in
  y | Y | yes | YES) return 0 ;;
  *) return 1 ;;
  esac
}

confirm_action() {
  local prompt="$1"
  echo -n "$prompt"
  local reply
  read -r reply
  case "$reply" in
  y | Y | yes | YES) return 0 ;;
  *) return 1 ;;
  esac
}

safe_delete_repo_dir() {
  local dir="$1"

  if [[ -z "$dir" ]]; then
    echo "Refusing to delete: empty path" >&2
    exit 1
  fi
  if [[ "$dir" == "/" || "$dir" == "$HOME" ]]; then
    echo "Refusing to delete unsafe path: $dir" >&2
    exit 1
  fi
  case "$dir" in
  "$ROOT_DIR" | "$ROOT_DIR/"*) ;;
  *)
    echo "Refusing to delete path outside repo root: $dir" >&2
    echo "If you intentionally used an external -derivedDataPath, delete it manually." >&2
    exit 1
    ;;
  esac

  if [[ -d "$dir" ]]; then
    rm -rf "$dir"
    echo "Deleted: $dir"
  else
    echo "No directory found at: $dir"
  fi
}

ensure_git_repo() {
  local repo_dir="$1"
  local purpose="${2:-repository}"

  if ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Invalid $purpose: not a usable git checkout at: $repo_dir" >&2
    echo "If this is meant to be a git worktree, it may be broken (e.g. moved repo path)." >&2
    echo "Fix by recreating the worktree from this repo:" >&2
    echo "  mv \"$repo_dir\" \"${repo_dir}.broken\"   # or delete it if safe" >&2
    echo "  git -C \"$ROOT_DIR\" worktree add -B gh-pages \"$repo_dir\" origin/gh-pages" >&2
    exit 1
  fi
}

sparkle_artifact_root_candidates() {
  local derived_data_path="${1:-}"

  if [[ -n "$derived_data_path" ]]; then
    echo "$derived_data_path/SourcePackages/artifacts/sparkle/Sparkle"
  fi
  echo "$ROOT_DIR/.build/xcode-release/SourcePackages/artifacts/sparkle/Sparkle"
  echo "$ROOT_DIR/.build/xcode/SourcePackages/artifacts/sparkle/Sparkle"
}

install_sparkle_tools_from_artifacts() {
  local preferred_derived_data_path="${1:-}"

  require_cmd ditto

  local source_root=""
  while IFS= read -r candidate; do
    if [[ -x "$candidate/bin/sign_update" ]]; then
      source_root="$candidate"
      break
    fi
  done < <(sparkle_artifact_root_candidates "$preferred_derived_data_path")

  if [[ -z "$source_root" ]]; then
    echo "Could not find Sparkle tools in SwiftPM artifacts." >&2
    echo "Expected one of:" >&2
    sparkle_artifact_root_candidates "$preferred_derived_data_path" | sed 's/^/  - /' >&2
    echo "Tip: run a build first so SwiftPM resolves packages, then re-run install-sparkle-tools." >&2
    return 1
  fi

  mkdir -p "$SPARKLE_TOOLS_ROOT_DEFAULT"
  ditto "$source_root" "$SPARKLE_TOOLS_ROOT_DEFAULT"
  find "$SPARKLE_TOOLS_ROOT_DEFAULT/bin" -maxdepth 1 -type f -exec chmod +x {} + 2>/dev/null || true

  echo "Installed Sparkle tools:"
  echo "  from: $source_root"
  echo "  to:   $SPARKLE_TOOLS_ROOT_DEFAULT"
}

build_number() {
  git rev-list --count HEAD 2>/dev/null || echo 1
}

git_is_clean() {
  git diff --quiet && git diff --quiet --staged
}

local_repo_slug_from_origin() {
  local origin
  origin="$(git remote get-url origin 2>/dev/null || true)"
  case "$origin" in
  git@github.com:*.git)
    echo "$origin" | sed -E 's#^git@github.com:##; s#\\.git$##'
    ;;
  https://github.com/*.git)
    echo "$origin" | sed -E 's#^https://github.com/##; s#\\.git$##'
    ;;
  https://github.com/*)
    echo "$origin" | sed -E 's#^https://github.com/##'
    ;;
  *)
    echo ""
    ;;
  esac
}

build_app() {
  local configuration="$1"
  local marketing_version="${2:-}"

  require_cmd xcodebuild
  cd "$ROOT_DIR"

  local build_num
  build_num="$(build_number)"

  local -a extra=(
    "CODE_SIGNING_ALLOWED=NO"
    "CURRENT_PROJECT_VERSION=$build_num"
  )
  if [[ -n "$marketing_version" ]]; then
    extra+=("MARKETING_VERSION=$marketing_version")
  fi

  xcodebuild build \
    -project Ticker.xcodeproj \
    -scheme Ticker \
    -configuration "$configuration" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    "${extra[@]}" \
    -quiet
}

build_web_assets() {
  require_cmd npm
  (cd "$ROOT_DIR/Web" && {
    if [[ ! -d node_modules ]]; then
      npm ci
    fi
    npm run build
  })
}

web_typecheck() {
  require_cmd npm
  (cd "$ROOT_DIR/Web" && {
    if [[ ! -d node_modules ]]; then
      npm ci
    fi
    npm run typecheck
  })
}

cmd_web_typecheck() {
  echo "Web typecheck…"
  web_typecheck
}

cmd_contracts() {
  local script="$ROOT_DIR/tools/contracts/check_bridge_contract.mjs"
  local tools_dir="$ROOT_DIR/tools/contracts"
  if [[ ! -f "$script" ]]; then
    echo "Bridge contract tests not found at: $script"
    echo "Tip: update to a commit that includes the contract tests, or skip this step."
    return 0
  fi
  require_cmd node
  require_cmd npm
  (cd "$tools_dir" && {
    if [[ ! -d node_modules ]]; then
      npm ci
    fi
  })
  echo "Bridge contract tests…"
  node "$script"
}

swift_test() {
  require_cmd git
  require_cmd xcodebuild

  cd "$ROOT_DIR"

  echo "Building web assets…"
  build_web_assets

  local build_num
  build_num="$(build_number)"

  xcodebuild test \
    -project Ticker.xcodeproj \
    -scheme Ticker \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CURRENT_PROJECT_VERSION="$build_num" \
    -quiet
}

cmd_swift_test() {
  echo "Swift tests…"
  swift_test
}

cmd_preflight_alpha() {
  local -a remaining=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      cmd_help preflight-alpha
      return 0
      ;;
    *)
      remaining+=("$1")
      shift
      ;;
    esac
  done
  if (( ${#remaining[@]} > 0 )); then
    echo "Unknown arguments: ${remaining[*]}" >&2
    exit 2
  fi

  cmd_contracts
  cmd_web_typecheck
  cmd_swift_test
}

cmd_build_dev() {
  echo "Building Debug (unsigned)…"
  build_app Debug
  echo "Built: $DERIVED_DATA_PATH/Build/Products/Debug/Ticker.app"
}

cmd_run_dev() {
  TICKER_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" "$ROOT_DIR/run.sh" --dev
}

cmd_build_prod() {
  echo "Building web assets…"
  build_web_assets
  echo "Building Release (unsigned)…"
  build_app Release
  echo "Built: $DERIVED_DATA_PATH/Build/Products/Release/Ticker.app"
}

repair_release_swiftpm_artifacts_if_needed() {
  local release_dd="$1"

  # Sparkle is a SwiftPM binary target (XCFramework). If the artifact cache gets
  # corrupted/stale, Xcode can fail with:
  #   "There is no XCFramework found at .../Sparkle.xcframework"
  #
  # This commonly happens under the release DerivedData path, so we detect the
  # specific "Sparkle artifact dir exists but xcframework is missing" condition
  # and delete only the Sparkle artifact subtree. A subsequent build will re-fetch it.
  local sparkle_root="$release_dd/SourcePackages/artifacts/sparkle"
  local sparkle_xcframework="$sparkle_root/Sparkle/Sparkle.xcframework"

  if [[ -d "$sparkle_root" && ! -d "$sparkle_xcframework" ]]; then
    echo "Detected missing Sparkle.xcframework under release DerivedData:"
    echo "  Expected: $sparkle_xcframework"
    echo "Cleaning stale Sparkle SwiftPM artifacts…"
    safe_delete_repo_dir "$sparkle_root"
  fi
}

cmd_run_prod() {
  TICKER_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" "$ROOT_DIR/run.sh" --prod
}

cmd_clean_derived_data() {
  local mode="dev"
  local yes="false"
  local derived_data_override=""
  local -a remaining=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --derived-data)
      derived_data_override="$2"
      shift 2
      ;;
    --release)
      mode="release"
      shift
      ;;
    --all)
      mode="all"
      shift
      ;;
    -y | --yes)
      yes="true"
      shift
      ;;
    -h | --help)
      cat <<'EOF'
Usage: ./tickerctl.sh clean-derived-data [options]

Options:
  --derived-data PATH   Path to delete (defaults depend on --release/--all)
  --release             Delete release DerivedData (default: ./.build/xcode-release)
  --all                 Delete both dev/prod + release DerivedData
  -y, --yes             Do not prompt for confirmation
EOF
      exit 0
      ;;
    *)
      remaining+=("$1")
      shift
      ;;
    esac
  done

  if (( ${#remaining[@]} > 0 )); then
    echo "Unknown arguments: ${remaining[*]}" >&2
    exit 2
  fi

  local dev_derived_data="$DERIVED_DATA_PATH"
  local release_derived_data="$RELEASE_DERIVED_DATA_PATH_DEFAULT"
  if [[ -n "$derived_data_override" ]]; then
    if [[ "$mode" == "release" ]]; then
      release_derived_data="$derived_data_override"
    else
      dev_derived_data="$derived_data_override"
    fi
  fi

  local -a dirs=()
  case "$mode" in
  dev) dirs+=("$dev_derived_data") ;;
  release) dirs+=("$release_derived_data") ;;
  all)
    dirs+=("$dev_derived_data" "$release_derived_data")
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    exit 2
    ;;
  esac

  echo "Will delete:"
  printf '  - %s\n' "${dirs[@]}"

  if [[ "$yes" != "true" ]]; then
    if ! confirm_delete_dir "${dirs[*]}" "Proceed? [y/N] "; then
      echo "Canceled."
      exit 0
    fi
  fi

  for d in "${dirs[@]}"; do
    safe_delete_repo_dir "$d"
  done
}

cmd_install_sparkle_tools() {
  local preferred_derived_data_path=""
  local -a remaining=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --derived-data)
      preferred_derived_data_path="$2"
      shift 2
      ;;
    -h | --help)
      cat <<'EOF'
Usage: ./tickerctl.sh install-sparkle-tools [options]

Installs Sparkle CLI tools (sign_update, generate_appcast, etc.) into:
  ./tools/sparkle/Sparkle/bin

The tools are copied from SwiftPM artifact bundles under a DerivedData path.

Options:
  --derived-data PATH   Prefer artifacts under this DerivedData path
EOF
      exit 0
      ;;
    *)
      remaining+=("$1")
      shift
      ;;
    esac
  done

  if (( ${#remaining[@]} > 0 )); then
    echo "Unknown arguments: ${remaining[*]}" >&2
    exit 2
  fi

  install_sparkle_tools_from_artifacts "$preferred_derived_data_path"
}

ensure_sparkle_bin() {
  if [[ -x "$SPARKLE_BIN/sign_update" ]]; then
    return 0
  fi

  local -a candidates=(
    "$SPARKLE_TOOLS_ROOT_DEFAULT/bin"
    "$ROOT_DIR/tools/sparkle/bin"
  )
  for c in "${candidates[@]}"; do
    if [[ -x "$c/sign_update" ]]; then
      SPARKLE_BIN="$c"
      return 0
    fi
  done

  echo "Sparkle sign_update not found; installing Sparkle CLI tools into repo…" >&2
  cmd_install_sparkle_tools --derived-data "$DERIVED_DATA_PATH"

  SPARKLE_BIN="$SPARKLE_TOOLS_ROOT_DEFAULT/bin"
  if [[ -x "$SPARKLE_BIN/sign_update" ]]; then
    return 0
  fi

  echo "Sparkle sign_update still not found after install." >&2
  echo "Tried:" >&2
  printf '  - %s\n' "${candidates[@]/%//sign_update}" >&2
  exit 1
}

extract_sign_update_fields() {
  local output="$1"
  local signature length

  signature="$(echo "$output" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | tail -n 1)"
  length="$(echo "$output" | sed -n 's/.*length="\([0-9]*\)".*/\1/p' | tail -n 1)"

  if [[ -z "$signature" || -z "$length" ]]; then
    echo "Failed to parse sign_update output:" >&2
    echo "$output" >&2
    exit 1
  fi

  echo "$signature" "$length"
}

write_appcast_item() {
  local version="$1"
  local build_num="$2"
  local signature="$3"
  local length="$4"
  local asset_name="$5"
  local pub_date

  pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

  cat <<EOF
    <item>
      <title>Version ${version}</title>
      <pubDate>${pub_date}</pubDate>
      <sparkle:version>${build_num}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_MACOS}</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/${UPDATES_REPO_SLUG}/releases/download/v${version}/${asset_name}"
        type="application/octet-stream"
        sparkle:edSignature="${signature}"
        length="${length}"
      />
    </item>
EOF
}

cmd_release_alpha() {
  local version=""
  local publish="false"
  local update_appcast="false"
  local commit_appcast="false"
  local push_appcast="false"
  local promote="false"
  local allow_dirty="false"
  local skip_build="false"
  local release_derived_data="$RELEASE_DERIVED_DATA_PATH_DEFAULT"
  local -a remaining=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --version)
      version="$2"
      shift 2
      ;;
    --publish)
      publish="true"
      shift
      ;;
    --update-appcast)
      update_appcast="true"
      shift
      ;;
    --commit-appcast)
      commit_appcast="true"
      shift
      ;;
    --push-appcast)
      push_appcast="true"
      shift
      ;;
    --promote)
      promote="true"
      shift
      ;;
    --allow-dirty)
      allow_dirty="true"
      shift
      ;;
    --skip-build)
      skip_build="true"
      shift
      ;;
    --derived-data)
      release_derived_data="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      remaining+=("$1")
      shift
      ;;
    esac
  done

  if (( ${#remaining[@]} > 0 )); then
    echo "Unknown arguments: ${remaining[*]}" >&2
    exit 2
  fi

  if [[ -z "$version" ]]; then
    echo "release-alpha requires --version (e.g. 2025.12.1)" >&2
    exit 2
  fi

  require_cmd git
  cd "$ROOT_DIR"

  local release_out_dir="$ROOT_DIR/.build/releases/v${version}"
  mkdir -p "$release_out_dir"
  local meta_path="$release_out_dir/release.env"

  if [[ "$skip_build" == "true" ]]; then
    if [[ ! -f "$meta_path" ]]; then
      echo "Release metadata not found: $meta_path" >&2
      echo "Run a build first:" >&2
      echo "  ./tickerctl.sh release-alpha --version ${version}" >&2
      exit 1
    fi

    # shellcheck disable=SC1090
    source "$meta_path"

    local head_commit
    head_commit="$(git rev-parse HEAD)"
    if [[ "${RELEASE_COMMIT:-}" != "$head_commit" ]]; then
      echo "Release metadata commit mismatch:" >&2
      echo "  metadata: ${RELEASE_COMMIT:-<missing>}" >&2
      echo "  HEAD:     $head_commit" >&2
      echo "Checkout the release commit or rebuild without --skip-build." >&2
      exit 1
    fi

    if [[ -z "${RELEASE_ZIP_PATH:-}" || -z "${RELEASE_ZIP_NAME:-}" || -z "${RELEASE_SIGNATURE:-}" || -z "${RELEASE_LENGTH:-}" || -z "${RELEASE_BUILD_NUM:-}" ]]; then
      echo "Release metadata missing required fields: $meta_path" >&2
      exit 1
    fi

    if [[ ! -f "$RELEASE_ZIP_PATH" ]]; then
      echo "Release zip not found: $RELEASE_ZIP_PATH" >&2
      exit 1
    fi

    # Carry forward metadata into local vars used by promote steps.
    local zip_name="$RELEASE_ZIP_NAME"
    local zip_path="$RELEASE_ZIP_PATH"
    local signature="$RELEASE_SIGNATURE"
    local length="$RELEASE_LENGTH"
    local bundle_build_num="$RELEASE_BUILD_NUM"

    # Prefer metadata updates repo slug if config is empty.
    if [[ -z "$UPDATES_REPO_SLUG" && -n "${RELEASE_UPDATES_REPO_SLUG:-}" ]]; then
      UPDATES_REPO_SLUG="$RELEASE_UPDATES_REPO_SLUG"
    fi

    if [[ -z "$UPDATES_REPO_SLUG" ]]; then
      echo "Missing UPDATES_REPO_SLUG (owner/repo) where the zip is hosted." >&2
      echo "Set it in tickerctl.local.sh, or ensure release.env includes RELEASE_UPDATES_REPO_SLUG." >&2
      exit 1
    fi

    if [[ -n "${RELEASE_UPDATES_REPO_SLUG:-}" && "$UPDATES_REPO_SLUG" != "$RELEASE_UPDATES_REPO_SLUG" ]]; then
      echo "UPDATES_REPO_SLUG mismatch:" >&2
      echo "  metadata: $RELEASE_UPDATES_REPO_SLUG" >&2
      echo "  config:   $UPDATES_REPO_SLUG" >&2
      exit 1
    fi

    if [[ "$promote" == "true" ]]; then
      publish="true"
      update_appcast="true"
      commit_appcast="true"
      push_appcast="true"
    fi

    if [[ "$publish" == "true" ]]; then
      require_cmd gh
    fi

    if [[ "$update_appcast" == "true" ]]; then
      require_cmd python3
    fi

    local item
    item="$(write_appcast_item "$version" "$bundle_build_num" "$signature" "$length" "$zip_name")"

    echo
    echo "=== Appcast item (paste into appcast-alpha.xml) ==="
    echo "$item"
    echo "=================================================="
    echo

    if [[ "$publish" != "true" && "$update_appcast" != "true" ]]; then
      echo "Nothing else to do (no --publish/--update-appcast/--promote flags)."
      echo "Zip: $zip_path"
      exit 0
    fi

    # Promote from existing artifact + signature.
    if [[ "$publish" == "true" ]]; then
      echo "Publishing GitHub Release v${version}…"
      local -a gh_cmd=(gh release create "v${version}" --repo "$UPDATES_REPO_SLUG")
      if [[ -n "$UPDATES_RELEASE_TARGET" ]]; then
        gh_cmd+=(--target "$UPDATES_RELEASE_TARGET")
      else
        local local_slug
        local_slug="$(local_repo_slug_from_origin)"
        if [[ -n "$local_slug" && "$local_slug" == "$UPDATES_REPO_SLUG" ]]; then
          gh_cmd+=(--target "$(git rev-parse HEAD)")
        fi
      fi

      gh_cmd+=(--title "Ticker ${version}" --notes "Alpha release ${version}" "$zip_path")
      "${gh_cmd[@]}"
    fi

    if [[ "$update_appcast" == "true" ]]; then
      if [[ -z "$APPCAST_REPO_DIR" ]]; then
        echo "Missing APPCAST_REPO_DIR (path to gh-pages worktree). Set it in tickerctl.local.sh." >&2
        exit 1
      fi
      if [[ ! -d "$APPCAST_REPO_DIR" ]]; then
        echo "APPCAST_REPO_DIR not found: $APPCAST_REPO_DIR" >&2
        exit 1
      fi
      ensure_git_repo "$APPCAST_REPO_DIR" "APPCAST_REPO_DIR (gh-pages worktree)"
      local appcast_path="$APPCAST_REPO_DIR/$APPCAST_FILENAME"
      if [[ ! -f "$appcast_path" ]]; then
        echo "Appcast file not found: $appcast_path" >&2
        exit 1
      fi

      echo "Updating appcast file: $appcast_path"
      python3 - <<PY
import xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime, timezone

path = Path(r\"\"\"$appcast_path\"\"\")
xml = path.read_text(encoding=\"utf-8\")

SPARKLE_NS = \"http://www.andymatuschak.org/xml-namespaces/sparkle\"
ET.register_namespace(\"sparkle\", SPARKLE_NS)

tree = ET.ElementTree(ET.fromstring(xml))
root = tree.getroot()
channel = root.find(\"channel\")
if channel is None:
    raise SystemExit(\"appcast missing <channel>\")

def sparkle(tag: str) -> str:
    return f\"{{{SPARKLE_NS}}}{tag}\"

item = ET.Element(\"item\")
ET.SubElement(item, \"title\").text = f\"Version {r'''$version'''}\"
ET.SubElement(item, \"pubDate\").text = datetime.now(timezone.utc).strftime(\"%a, %d %b %Y %H:%M:%S +0000\")
ET.SubElement(item, sparkle(\"version\")).text = r'''$bundle_build_num'''
ET.SubElement(item, sparkle(\"shortVersionString\")).text = r'''$version'''
ET.SubElement(item, sparkle(\"minimumSystemVersion\")).text = r'''$MIN_MACOS'''

enclosure = ET.SubElement(item, \"enclosure\")
enclosure.set(\"url\", f\"https://github.com/{r'''$UPDATES_REPO_SLUG'''}/releases/download/v{r'''$version'''}/{r'''$zip_name'''}\")
enclosure.set(\"type\", \"application/octet-stream\")
enclosure.set(sparkle(\"edSignature\"), r'''$signature''')
enclosure.set(\"length\", r'''$length''')

channel.insert(1 if len(channel) > 0 and channel[0].tag == \"title\" else 0, item)

max_items = int(r'''$APPCAST_MAX_ITEMS''')
items = [child for child in list(channel) if child.tag == \"item\"]
for extra in items[max_items:]:
    channel.remove(extra)

path.write_text(ET.tostring(root, encoding=\"unicode\", xml_declaration=True), encoding=\"utf-8\")
PY

      echo "Appcast updated."

      if [[ "$commit_appcast" == "true" || "$push_appcast" == "true" ]]; then
        local current_branch
        current_branch="$(git -C "$APPCAST_REPO_DIR" branch --show-current)"
        if [[ "$current_branch" != "gh-pages" ]]; then
          echo "Refusing to commit/push appcast: $APPCAST_REPO_DIR is on branch '$current_branch' (expected gh-pages)." >&2
          exit 1
        fi
        git -C "$APPCAST_REPO_DIR" add "$APPCAST_FILENAME"
        if [[ "$commit_appcast" == "true" ]]; then
          git -C "$APPCAST_REPO_DIR" commit -m "Release v${version}" || true
        fi
        if [[ "$push_appcast" == "true" ]]; then
          git -C "$APPCAST_REPO_DIR" push
        fi
      fi
    fi

    echo "Release artifact: $zip_path"
    exit 0
  fi

  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "Missing SIGN_IDENTITY. Set it in tickerctl.local.sh." >&2
    exit 1
  fi

  require_cmd ditto
  require_cmd codesign
  require_cmd xcrun
  require_cmd spctl

  if [[ "$promote" == "true" ]]; then
    publish="true"
    update_appcast="true"
    commit_appcast="true"
    push_appcast="true"
  fi

  if [[ "$publish" == "true" ]]; then
    require_cmd gh
  fi

  if [[ "$allow_dirty" != "true" ]]; then
    if ! git_is_clean; then
      echo "Refusing to release: working tree has uncommitted changes." >&2
      echo "Commit/stash, or re-run with --allow-dirty." >&2
      exit 1
    fi
  fi

  if [[ -z "$UPDATES_REPO_SLUG" ]]; then
    UPDATES_REPO_SLUG="$(local_repo_slug_from_origin)"
  fi
  if [[ -z "$UPDATES_REPO_SLUG" ]]; then
    echo "Missing UPDATES_REPO_SLUG (owner/repo) where the zip is hosted." >&2
    echo "Set it in tickerctl.local.sh." >&2
    exit 1
  fi

  echo "Running preflight checks…"
  cmd_preflight_alpha

  DERIVED_DATA_PATH="$release_derived_data"
  local release_dd="$DERIVED_DATA_PATH"

  echo "Release DerivedData: $release_dd"
  repair_release_swiftpm_artifacts_if_needed "$release_dd"

  echo "Building web assets (Release)…"
  build_web_assets

  local build_num
  build_num="$(build_number)"

  echo "Building Release (unsigned)…"
  if ! build_app Release "$version"; then
    local sparkle_xcframework="$release_dd/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework"
    if [[ ! -d "$sparkle_xcframework" ]]; then
      echo "Release build failed and Sparkle.xcframework is missing."
      echo "Auto-repair: cleaning release DerivedData and retrying once…"
      cmd_clean_derived_data --release --derived-data "$release_dd" -y
      build_app Release "$version"
    else
      exit 1
    fi
  fi

  local app_path="$release_dd/Build/Products/Release/Ticker.app"
  if [[ ! -d "$app_path" ]]; then
    echo "Expected app bundle not found: $app_path" >&2
    exit 1
  fi

  require_cmd defaults
  local bundle_build_num
  bundle_build_num="$(defaults read "$app_path/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "$build_num")"

  echo "Signing app…"
  codesign --deep --force --verify --verbose \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    "$app_path"
  codesign --verify --deep --strict --verbose=2 "$app_path"

  echo "Notarizing…"
  local notarize_zip="$release_out_dir/Ticker-notarize.zip"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notarize_zip"
  xcrun notarytool submit "$notarize_zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app_path"
  spctl -a -vv "$app_path"

  echo "Creating distribution zip…"
  local zip_name="Ticker-${version}.zip"
  local zip_path="$release_out_dir/$zip_name"
  (cd "$release_dd/Build/Products/Release" && ditto -c -k --sequesterRsrc --keepParent "Ticker.app" "$zip_path")

  ensure_sparkle_bin

  echo "Signing update zip with Sparkle…"
  local sign_output
  sign_output="$("$SPARKLE_BIN/sign_update" "$zip_path")"
  read -r signature length < <(extract_sign_update_fields "$sign_output")

  echo "Preparing appcast <item>…"
  local item
  item="$(write_appcast_item "$version" "$bundle_build_num" "$signature" "$length" "$zip_name")"

  echo "Writing release metadata: $meta_path"
  {
    echo "# Generated by tickerctl.sh release-alpha"
    printf 'RELEASE_VERSION=%q\n' "$version"
    printf 'RELEASE_BUILD_NUM=%q\n' "$bundle_build_num"
    printf 'RELEASE_ZIP_NAME=%q\n' "$zip_name"
    printf 'RELEASE_ZIP_PATH=%q\n' "$zip_path"
    printf 'RELEASE_SIGNATURE=%q\n' "$signature"
    printf 'RELEASE_LENGTH=%q\n' "$length"
    printf 'RELEASE_APP_PATH=%q\n' "$app_path"
    printf 'RELEASE_UPDATES_REPO_SLUG=%q\n' "$UPDATES_REPO_SLUG"
    printf 'RELEASE_COMMIT=%q\n' "$(git rev-parse HEAD)"
    printf 'RELEASE_CREATED_AT_UTC=%q\n' "$(LC_ALL=C date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } >"$meta_path"

  echo
  echo "=== Appcast item (paste into appcast-alpha.xml) ==="
  echo "$item"
  echo "=================================================="
  echo

  if [[ "$publish" == "true" ]]; then
    echo "Publishing GitHub Release v${version}…"
    local -a gh_cmd=(gh release create "v${version}" --repo "$UPDATES_REPO_SLUG")
    if [[ -n "$UPDATES_RELEASE_TARGET" ]]; then
      gh_cmd+=(--target "$UPDATES_RELEASE_TARGET")
    else
      local local_slug
      local_slug="$(local_repo_slug_from_origin)"
      if [[ -n "$local_slug" && "$local_slug" == "$UPDATES_REPO_SLUG" ]]; then
        gh_cmd+=(--target "$(git rev-parse HEAD)")
      fi
    fi

    gh_cmd+=(--title "Ticker ${version}" --notes "Alpha release ${version}" "$zip_path")
    "${gh_cmd[@]}"
  fi

  if [[ "$update_appcast" == "true" ]]; then
    require_cmd python3
    if [[ -z "$APPCAST_REPO_DIR" ]]; then
      echo "Missing APPCAST_REPO_DIR (path to gh-pages worktree). Set it in tickerctl.local.sh." >&2
      exit 1
    fi
      if [[ ! -d "$APPCAST_REPO_DIR" ]]; then
        echo "APPCAST_REPO_DIR not found: $APPCAST_REPO_DIR" >&2
        exit 1
      fi
      ensure_git_repo "$APPCAST_REPO_DIR" "APPCAST_REPO_DIR (gh-pages worktree)"
      local appcast_path="$APPCAST_REPO_DIR/$APPCAST_FILENAME"
      if [[ ! -f "$appcast_path" ]]; then
        echo "Appcast file not found: $appcast_path" >&2
        exit 1
      fi

    echo "Updating appcast file: $appcast_path"
    python3 - <<PY
import xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime, timezone

path = Path(r"""$appcast_path""")
xml = path.read_text(encoding="utf-8")

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

tree = ET.ElementTree(ET.fromstring(xml))
root = tree.getroot()
channel = root.find("channel")
if channel is None:
    raise SystemExit("appcast missing <channel>")

def sparkle(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Version {r'''$version'''}"
ET.SubElement(item, "pubDate").text = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
ET.SubElement(item, sparkle("version")).text = r'''$bundle_build_num'''
ET.SubElement(item, sparkle("shortVersionString")).text = r'''$version'''
ET.SubElement(item, sparkle("minimumSystemVersion")).text = r'''$MIN_MACOS'''

enclosure = ET.SubElement(item, "enclosure")
enclosure.set("url", f"https://github.com/{r'''$UPDATES_REPO_SLUG'''}/releases/download/v{r'''$version'''}/{r'''$zip_name'''}")
enclosure.set("type", "application/octet-stream")
enclosure.set(sparkle("edSignature"), r'''$signature''')
enclosure.set("length", r'''$length''')

channel.insert(1 if len(channel) > 0 and channel[0].tag == "title" else 0, item)

max_items = int(r'''$APPCAST_MAX_ITEMS''')
items = [child for child in list(channel) if child.tag == "item"]
for extra in items[max_items:]:
    channel.remove(extra)

path.write_text(ET.tostring(root, encoding="unicode", xml_declaration=True), encoding="utf-8")
PY

    echo "Appcast updated."

    if [[ "$commit_appcast" == "true" || "$push_appcast" == "true" ]]; then
      require_cmd git
      local current_branch
      current_branch="$(git -C "$APPCAST_REPO_DIR" branch --show-current)"
      if [[ "$current_branch" != "gh-pages" ]]; then
        echo "Refusing to commit/push appcast: $APPCAST_REPO_DIR is on branch '$current_branch' (expected gh-pages)." >&2
        exit 1
      fi
      git -C "$APPCAST_REPO_DIR" add "$APPCAST_FILENAME"
      if [[ "$commit_appcast" == "true" ]]; then
        git -C "$APPCAST_REPO_DIR" commit -m "Release v${version}" || true
      fi
      if [[ "$push_appcast" == "true" ]]; then
        git -C "$APPCAST_REPO_DIR" push
      fi
    fi
  fi

  echo "Release artifact: $zip_path"
  echo "Signed/notarized app: $app_path"
}

cmd_reset_onboarding() {
  require_cmd defaults
  echo "Resetting onboarding for $APP_BUNDLE_ID..."
  defaults delete "$APP_BUNDLE_ID" has_completed_onboarding >/dev/null 2>&1 || true
  echo "Done. Relaunch Ticker to see onboarding."
}

cmd_reset_proxy_soft() {
  require_cmd python3
  echo "Soft reset proxy registration (keep device_id):"
  echo "  File: $TICKER_DEVICE_JSON_PATH"

  python3 - "$TICKER_DEVICE_JSON_PATH" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1]).expanduser()
if not path.exists():
    print("No device.json found; nothing to reset.")
    raise SystemExit(0)

data = json.loads(path.read_text(encoding="utf-8"))
for key in ("device_key", "support_id", "validated_at"):
    if key in data:
        data[key] = None

tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
tmp.replace(path)
print("Cleared device_key/support_id/validated_at (kept device_id).")
PY
}

cmd_reset_proxy_hard() {
  echo "Hard reset proxy registration (regenerates device_id on next launch):"
  echo "  File: $TICKER_DEVICE_JSON_PATH"
  if ! confirm_action "Delete this file? [y/N] "; then
    echo "Canceled."
    return 0
  fi
  rm -f "$TICKER_DEVICE_JSON_PATH"
  echo "Deleted. Relaunch Ticker to re-register."
}

cmd_reset_accessibility() {
  require_cmd tccutil
  echo "Reset Accessibility permission for $APP_BUNDLE_ID."
  if ! confirm_action "Run: tccutil reset Accessibility $APP_BUNDLE_ID ? [y/N] "; then
    echo "Canceled."
    return 0
  fi
  tccutil reset Accessibility "$APP_BUNDLE_ID"
  echo "Done. Relaunch Ticker and re-grant Accessibility when prompted."
}

cmd_reset_proxy_url() {
  require_cmd defaults
  echo "Clearing proxy URL override (UserDefaults key: TickerProxyURL) for $APP_BUNDLE_ID..."
  defaults delete "$APP_BUNDLE_ID" TickerProxyURL >/dev/null 2>&1 || true
  echo "Done."
}

cmd_reset_diagnostics() {
  require_cmd defaults
  echo "Clearing diagnostics opt-out (UserDefaults key: diagnostics_enabled) for $APP_BUNDLE_ID..."
  defaults delete "$APP_BUNDLE_ID" diagnostics_enabled >/dev/null 2>&1 || true
  echo "Done. Diagnostics defaults to ON when unset."
}

cmd_reset_all() {
  echo "Reset bundle: onboarding + proxy-hard + proxy-url + diagnostics"
  echo "  Bundle ID: $APP_BUNDLE_ID"
  echo "  device.json: $TICKER_DEVICE_JSON_PATH"
  if ! confirm_action "Proceed? [y/N] "; then
    echo "Canceled."
    return 0
  fi
  cmd_reset_onboarding
  cmd_reset_proxy_hard
  cmd_reset_proxy_url
  cmd_reset_diagnostics
  echo "Done."
  echo "Optional: reset Accessibility via: ./tickerctl.sh reset-accessibility"
}

cmd_versions() {
  local build_num
  build_num="$(build_number)"
  echo "HEAD build number (CFBundleVersion): $build_num"
}

cmd_menu() {
  PS3="Select an action: "
  select choice in \
    "Build Debug (dev)" \
    "Build + Run Debug (dev)" \
    "Build Release (prod, unsigned)" \
    "Build + Run Release (prod, unsigned)" \
    "Preflight (alpha): contracts + web typecheck + swift tests" \
    "Clean DerivedData (dev/prod + release)" \
    "Release (alpha): build+sign+notarize+zip+Sparkle-sign" \
    "Release (alpha) + promote: publish + update appcast" \
    "Promote existing alpha (skip build): publish + update appcast" \
    "Versions (build number)" \
    "Reset: onboarding" \
    "Reset: proxy (soft)" \
    "Reset: proxy (hard)" \
    "Reset: Accessibility permission" \
    "Reset: proxy URL override" \
    "Reset: diagnostics toggle" \
    "Reset: all (onboarding + proxy-hard + proxy-url + diagnostics)" \
    "Quit"; do
    case "$REPLY" in
    1)
      cmd_build_dev
      break
      ;;
    2)
      cmd_run_dev
      break
      ;;
    3)
      cmd_build_prod
      break
      ;;
    4)
      cmd_run_prod
      break
      ;;
    5)
      cmd_preflight_alpha
      break
      ;;
    6)
      echo "Clean which DerivedData?"
      select dd in \
        "Dev/Prod only (./.build/xcode)" \
        "Release only (./.build/xcode-release)" \
        "Both (recommended)"; do
        case "$REPLY" in
        1)
          cmd_clean_derived_data
          break
          ;;
        2)
          cmd_clean_derived_data --release
          break
          ;;
        3)
          cmd_clean_derived_data --all
          break
          ;;
        *)
          echo "Invalid choice."
          ;;
        esac
      done
      break
      ;;
    7)
      echo "Enter marketing version (e.g. 2025.12.1):"
      read -r v
      cmd_release_alpha --version "$v"
      break
      ;;
    8)
      echo "Enter marketing version (e.g. 2025.12.1):"
      read -r v
      cmd_release_alpha --version "$v" --promote
      break
      ;;
    9)
      echo "Enter marketing version (e.g. 2025.12.1):"
      read -r v
      cmd_release_alpha --version "$v" --skip-build --promote
      break
      ;;
    10)
      cmd_versions
      break
      ;;
    11)
      cmd_reset_onboarding
      break
      ;;
    12)
      cmd_reset_proxy_soft
      break
      ;;
    13)
      cmd_reset_proxy_hard
      break
      ;;
    14)
      cmd_reset_accessibility
      break
      ;;
    15)
      cmd_reset_proxy_url
      break
      ;;
    16)
      cmd_reset_diagnostics
      break
      ;;
    17)
      cmd_reset_all
      break
      ;;
    18) break ;;
    *) echo "Invalid selection" ;;
    esac
  done
}

main() {
  local cmd="${1:-menu}"
  shift || true

  case "$cmd" in
  help) cmd_help "$@" ;;
  menu) cmd_menu ;;
  preflight-alpha) cmd_preflight_alpha "$@" ;;
  contracts) cmd_contracts ;;
  web-typecheck) cmd_web_typecheck ;;
  swift-test) cmd_swift_test ;;
  clean-derived-data) cmd_clean_derived_data "$@" ;;
  install-sparkle-tools) cmd_install_sparkle_tools "$@" ;;
  build-dev) cmd_build_dev ;;
  run-dev) cmd_run_dev ;;
  build-prod) cmd_build_prod ;;
  run-prod) cmd_run_prod ;;
  release-alpha) cmd_release_alpha "$@" ;;
  reset-onboarding) cmd_reset_onboarding ;;
  reset-proxy-soft) cmd_reset_proxy_soft ;;
  reset-proxy-hard) cmd_reset_proxy_hard ;;
  reset-accessibility) cmd_reset_accessibility ;;
  reset-proxy-url) cmd_reset_proxy_url ;;
  reset-diagnostics) cmd_reset_diagnostics ;;
  reset-all) cmd_reset_all ;;
  versions) cmd_versions ;;
  -h | --help) usage ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage
    exit 2
    ;;
  esac
}

main "$@"
