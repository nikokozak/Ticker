# Release Runbook (Alpha Channel)

Step-by-step guide to release a new Ticker alpha build with Sparkle auto-updates.

If you want a “single entry point” that wraps the common dev/prod/release commands, use `./tickerctl.sh`.
`./run.sh` is intended for local dev convenience only (not signing/notarization/release automation).

## Mental model (what each thing “means”)

- **Dev build (Debug)**: unsigned, fast iteration. In Ticker, Debug loads the web UI from the Vite dev server (`http://localhost:5173`), and you typically run it from Terminal during development.
- **Prod build (Release, unsigned)**: Release configuration built locally, still **not** signed/notarized. Useful for quick “what will Release behave like?” checks (performance, bundling, no dev server), but not an end-user artifact.
- **Distribution build (Release, signed + notarized + stapled)**: what you can hand to users. This is the `.app` you copy into `/Applications`.
- **Sparkle update payload**: a zipped `.app` (`Ticker-<version>.zip`) that is signed with Sparkle (`sign_update`) and hosted publicly.
- **Appcast**: `appcast-alpha.xml` (on GitHub Pages) that tells Sparkle where to download the payload and how to verify it. It must include:
  - `sparkle:version` = released app’s `CFBundleVersion` (monotonic integer)
  - `sparkle:shortVersionString` = released app’s `CFBundleShortVersionString` (e.g. `2025.12.1`)
  - `enclosure url`, `sparkle:edSignature`, `length`
- **How to test updates**: you need an *older* build installed in `/Applications/Ticker.app` and a *newer* build published in the appcast. If you overwrite `/Applications/Ticker.app` with the new build first, there is nothing left to “update”.

## Prerequisites

- macOS with Xcode installed
- Apple Developer ID certificate (for code signing)
- Sparkle private key in Keychain (generated via `generate_keys`)
- `gh` CLI authenticated (`gh auth login`)
- Sparkle CLI tools (see below)

## Important: update hosting must be public

Sparkle must be able to download your update zip **without being logged in to GitHub**.

- If this repo is **private**, GitHub Release asset URLs will work in your browser (logged in) but Sparkle will get 404.
- Recommended setup: keep source repo private, but host updates in a separate **public** repo (e.g. `ticker-updates`) and point the appcast `<enclosure url="...">` at that repo’s Releases.

### Sparkle CLI Tools Setup (one-time)

SPM provides the Sparkle framework, but release tools (`sign_update`, `generate_appcast`) are separate binaries.

**Recommended (replicable): install from SwiftPM artifacts**

After you’ve run any build (so SwiftPM resolves packages), install the tools into the repo (gitignored):

```bash
./tickerctl.sh install-sparkle-tools
```

Tools will be at `tools/sparkle/Sparkle/bin/sign_update` and `tools/sparkle/Sparkle/bin/generate_appcast`.

**Fallback: download Sparkle release archive**

```bash
# Download Sparkle release (check for latest version)
mkdir -p .build/downloads
curl -L -o .build/downloads/Sparkle-2.6.4.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz

# Extract tools to project (gitignored)
mkdir -p tools/sparkle
tar -xf .build/downloads/Sparkle-2.6.4.tar.xz -C tools/sparkle
```

Add to `.gitignore`:
```
tools/sparkle/
```

Depending on the Sparkle archive layout, the tools may be under `tools/sparkle/Sparkle/bin/`.

### GitHub Pages Setup (one-time)

If not already done:

> Recommended: use a separate worktree for `gh-pages` so you never mix source + appcast:
> `git worktree add ../Ticker-gh-pages gh-pages`
>
> If you already have an older worktree name (e.g. `../Streams-gh-pages`), that’s fine — the key point is keeping `gh-pages` isolated.

```bash
# Create orphan gh-pages branch
git checkout --orphan gh-pages
git reset --hard
echo "# Ticker Updates" > README.md
cat > appcast-alpha.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Ticker Alpha</title>
  </channel>
</rss>
EOF
git add README.md appcast-alpha.xml
git commit -m "Initialize gh-pages for Sparkle appcast"
git push origin gh-pages
git checkout main
```

Then in GitHub repo **Settings > Pages**:
- Source: **Deploy from a branch**
- Branch: **gh-pages** / **/ (root)**
- Save

Verify: `https://nikokozak.github.io/Ticker/appcast-alpha.xml` should return the XML.

---

## Release Steps

### 0. Pre-release data safety check (recommended)

Before shipping a build that includes schema changes, confirm that a pending migration creates a timestamped backup DB in:
- `~/Library/Application Support/Ticker/backups/`

Restore instructions live in `docs/ALPHA_SUPPORT.md` (keep that document accurate; it’s the thing you’ll reach for during triage).

### 1. Update version numbers

Edit `Ticker.xcodeproj/project.pbxproj`:
- `MARKETING_VERSION` → `YYYY.MM.patch` (e.g., `2025.12.1`)

The build number (`CURRENT_PROJECT_VERSION`) is set automatically from git commit count:
- `git rev-list --count HEAD`

### 2. Build Release configuration (unsigned)

```bash
# Get build number from git
BUILD_NUMBER=$(git rev-list --count HEAD)

# Build Release without code signing (sign separately)
xcodebuild build \
  -project Ticker.xcodeproj \
  -scheme Ticker \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode-release \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

APP_PATH=".build/xcode-release/Build/Products/Release/Ticker.app"
VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
RELEASE_OUT_DIR=".build/releases/v${VERSION}"
mkdir -p "$RELEASE_OUT_DIR"
```

#### Quick sanity check: bundled Web UI exists

If the app launches but the UI is blank in Release, check the bundled HTML is using **relative** asset paths:

```bash
grep -n \"assets/\" \"$APP_PATH/Contents/Resources/Resources/index.html\"
```

You want `./assets/...` (not `/assets/...`). This is controlled by `Web/vite.config.ts` (`base: './'` for build).

#### Quick sanity check: native drag & drop works

Launch the Release build and drag files from Finder into the window:

```bash
open "$APP_PATH"
```

- Drag a PNG/JPG → image appears in the current stream editor.
- Drag a PDF → source appears in the Sources panel.

### 3. Code sign with Developer ID

```bash
codesign --deep --force --verify --verbose \
  --sign "Developer ID Application: Nikolai Kozak (Z5DX2YK8FA)" \
  --options runtime \
  --timestamp \
  "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
```

### 4. Notarize and staple

```bash
# Create zip for notarization (sequester resource forks)
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$RELEASE_OUT_DIR/Ticker-notarize.zip"

# Store credentials in Keychain (one-time per machine).
# Use an app-specific password from https://appleid.apple.com (label it "notarytool").
xcrun notarytool store-credentials AC_PASSWORD \
  --apple-id "your@email.com" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"

# Submit for notarization
xcrun notarytool submit "$RELEASE_OUT_DIR/Ticker-notarize.zip" \
  --keychain-profile AC_PASSWORD \
  --wait

# Staple the notarization ticket
xcrun stapler staple "$APP_PATH"

# Verify signing and notarization
spctl -a -vv "$APP_PATH"
```

The `spctl` command should output: `accepted` and `source=Notarized Developer ID`.

### 5. Create distribution zip

```bash
VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
ZIP_NAME="Ticker-${VERSION}.zip"

cd .build/xcode-release/Build/Products/Release
ditto -c -k --sequesterRsrc --keepParent Ticker.app "$RELEASE_OUT_DIR/$ZIP_NAME"

# Get file size for appcast
FILE_SIZE=$(stat -f%z "$RELEASE_OUT_DIR/$ZIP_NAME")
echo "File size: $FILE_SIZE bytes"
```

### 6. Sign the zip with Sparkle

```bash
# Sign and get signature for appcast
./tools/sparkle/bin/sign_update "$RELEASE_OUT_DIR/$ZIP_NAME"
```

This outputs:
```
sparkle:edSignature="BASE64_SIGNATURE" length="12345678"
```

**Save these values** — you'll need them for the appcast entry.

### 7. Create GitHub Release

```bash
gh release create "v${VERSION}" \
  --title "Ticker ${VERSION}" \
  --notes "Release notes here" \
  "$RELEASE_OUT_DIR/$ZIP_NAME"
```

**Important**: The uploaded asset filename (`Ticker-YYYY.MM.patch.zip`) must exactly match what you put in the appcast URL.

### 8. Update appcast-alpha.xml

**Option A: Use generate_appcast (recommended)**

```bash
# Point generate_appcast at a folder containing your signed zip
APPCAST_SOURCE_DIR="$RELEASE_OUT_DIR/appcast-source"
mkdir -p "$APPCAST_SOURCE_DIR"
cp "$RELEASE_OUT_DIR/$ZIP_NAME" "$APPCAST_SOURCE_DIR/"

./tools/sparkle/bin/generate_appcast "$APPCAST_SOURCE_DIR"

# This creates/updates appcast.xml in that folder
# Copy the <item> entry to your gh-pages appcast-alpha.xml
```

**Option B: Manual edit**

Switch to `gh-pages` branch and edit `appcast-alpha.xml`:

```bash
git checkout gh-pages
```

Add a new `<item>` entry at the top of the channel (keep previous 2-3 entries for rollback):

> `sparkle:version` must match the released app’s `CFBundleVersion` (monotonic integer).
> Get it from the built app:
> `defaults read "$APP_PATH/Contents/Info.plist" CFBundleVersion`

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Ticker Alpha</title>

    <item>
      <title>Version YYYY.MM.patch</title>
      <pubDate>Sat, 21 Dec 2025 12:00:00 +0000</pubDate>
      <sparkle:version>BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>YYYY.MM.patch</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/nikokozak/Ticker/releases/download/vYYYY.MM.patch/Ticker-YYYY.MM.patch.zip"
        type="application/octet-stream"
        sparkle:edSignature="BASE64_SIGNATURE_FROM_STEP_6"
        length="FILE_SIZE_FROM_STEP_5"
      />
    </item>

    <!-- Keep previous 2-3 releases for rollback -->
  </channel>
</rss>
```

Commit and push:

```bash
git add appcast-alpha.xml
git commit -m "Release vYYYY.MM.patch"
git push origin gh-pages
git checkout main  # or your working branch
```

---

## Verification

1. Copy the notarized app to `/Applications/Ticker.app` and launch it from there (Sparkle updates the installed app bundle).
2. Click **Ticker > Check for Updates...**
3. Sparkle should find and offer the update.
4. If macOS prompts **Privacy & Security → App Management** for `AutoUpdate`, click **Allow** (first update on a machine).
5. Install and verify the new version launches correctly.

If download fails, verify the enclosure URL is publicly accessible:
```bash
curl -I "https://github.com/.../releases/download/.../Ticker-....zip"
curl -L -I "https://github.com/.../releases/download/.../Ticker-....zip"
```

---

## Rollback

- **Keep last 2-3 `<item>` entries** in appcast-alpha.xml
- **Do not delete older release assets** from GitHub Releases
- Users can manually download previous versions from: https://github.com/nikokozak/Ticker/releases

---

## Private Key Location

The Sparkle EdDSA private key is stored in the macOS Keychain. To locate it:

1. Open **Keychain Access**
2. Search for "Sparkle"
3. The private key is stored as an application password

> **WARNING**: Never paste, export, or commit the private key to git, PRs, or any text that could be shared. The private key must remain on the release machine (or as a CI secret).

To export for CI (store as `SPARKLE_PRIVATE_KEY` secret):
```bash
# Find the key in Keychain Access first to confirm the account/service names
security find-generic-password -a "ed25519" -w
```

For CI signing, pipe the secret to sign_update:
```bash
echo "$SPARKLE_PRIVATE_KEY" | ./tools/sparkle/bin/sign_update --ed-key-file - "$RELEASE_OUT_DIR/$ZIP_NAME"
```
