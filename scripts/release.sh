#!/usr/bin/env bash
#
# release.sh — archive GSD, export a distribution .ipa, and upload it to TestFlight.
#
# Composes with scripts/bump-version.sh. By default it bumps the BUILD number (every
# App Store Connect upload needs a unique CFBundleVersion), archives for a generic iOS
# device, exports an App Store .ipa via ExportOptions.plist, then uploads to TestFlight.
#
# Usage:
#   scripts/release.sh                  # bump build, archive, export, upload
#   scripts/release.sh patch            # marketing patch (+build), then release  (1.6 -> 1.6.1)
#   scripts/release.sh minor            # marketing minor (+build), then release  (1.6 -> 1.7)
#   scripts/release.sh major            # marketing major (+build), then release  (1.6 -> 2.0)
#   scripts/release.sh set 1.7 12       # explicit version + build, then release
#   scripts/release.sh --no-bump        # release the current project.yml version unchanged
#   scripts/release.sh --build-only     # archive + export the .ipa, but DO NOT upload
#   scripts/release.sh patch --build-only   # combine a bump with build-only
#
# Authentication (pick ONE; auto-detected from the environment — nothing secret lives in the repo):
#
#   App Store Connect API key  [recommended — also lets Xcode create distribution signing automatically]
#     export ASC_KEY_ID=XXXXXXXXXX
#     export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#     # Put the key at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
#     #   (or point ASC_KEY_PATH at it: export ASC_KEY_PATH=/abs/AuthKey_XXXX.p8)
#     # Create one: App Store Connect -> Users and Access -> Integrations ->
#     #   App Store Connect API -> generate a key with "App Manager" access. Download the .p8 ONCE.
#
#   Apple ID app-specific password  [upload only; assumes a distribution cert/profile already exist]
#     export ASC_USERNAME=you@example.com
#     export ASC_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx   # appleid.apple.com -> Sign-In and Security -> App-Specific Passwords
#
# The script never stores or prints your credentials. It does not commit or tag the version
# bump — review the project.yml diff and commit/tag when the upload succeeds.

set -euo pipefail

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

usage() { awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

# --- repo + tool checks -------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$REPO_ROOT"
command -v xcodegen  >/dev/null 2>&1 || die "xcodegen not found — brew install xcodegen"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found — install Xcode"

PROJECT="GSD.xcodeproj"
SCHEME="GSD"
EXPORT_OPTIONS="$REPO_ROOT/ExportOptions.plist"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/GSD.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

# --- parse args: an optional bump command + optional flags --------------------
BUMP="build"          # default: increment the build number so the upload is always valid
UPLOAD=1
PLATFORM="ios"
for arg in "$@"; do
  case "$arg" in
    -h|--help|help) usage; exit 0 ;;
    --no-bump)    BUMP="" ;;
    --build-only) UPLOAD=0 ;;
    --mac)        PLATFORM="mac" ;;
    build|patch|minor|major) BUMP="$arg" ;;
    set) BUMP="set" ;;
    *) ;;  # trailing operands (e.g. the version+build for `set`) are forwarded below
  esac
done

# --- resolve authentication (only matters when uploading) ---------------------
AUTH_MODE="none"
KEY_PATH="${ASC_KEY_PATH:-${HOME}/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-}.p8}"
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  AUTH_MODE="apikey"
  [[ -f "$KEY_PATH" ]] || die "API key not found at $KEY_PATH (set ASC_KEY_PATH or place AuthKey_${ASC_KEY_ID}.p8 in ~/.appstoreconnect/private_keys/)"
elif [[ -n "${ASC_USERNAME:-}" && -n "${ASC_APP_PASSWORD:-}" ]]; then
  AUTH_MODE="password"
fi

if [[ "$UPLOAD" -eq 1 && "$AUTH_MODE" == "none" ]]; then
  die "no credentials in the environment — set ASC_KEY_ID/ASC_ISSUER_ID (recommended) or ASC_USERNAME/ASC_APP_PASSWORD, or pass --build-only. See --help."
fi

# Auth flags for xcodebuild archive/export (API key enables automatic distribution signing).
AUTH_FLAGS=()
if [[ "$AUTH_MODE" == "apikey" ]]; then
  AUTH_FLAGS=(-authenticationKeyPath "$KEY_PATH"
              -authenticationKeyID "$ASC_KEY_ID"
              -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

# --- platform-specific knobs (iOS default; --mac switches to Catalyst) --------
if [[ "$PLATFORM" == "mac" ]]; then
  ARCHIVE_DEST='generic/platform=macOS,variant=Mac Catalyst'
  EXPORT_OPTIONS="$REPO_ROOT/ExportOptions-Mac.plist"
  ALTOOL_TYPE="macos"
  ARTIFACT_GLOB='*.pkg'
else
  ARCHIVE_DEST='generic/platform=iOS'
  ALTOOL_TYPE="ios"
  ARTIFACT_GLOB='*.ipa'
fi
[[ -f "$EXPORT_OPTIONS" ]] || die "export options not found at $EXPORT_OPTIONS"

# --- version bump (or just regenerate the project) ----------------------------
if [[ -n "$BUMP" ]]; then
  note "Bumping version ($BUMP)"
  if [[ "$BUMP" == "set" ]]; then
    "$REPO_ROOT/scripts/bump-version.sh" set "${2:-}" "${3:-}"
  else
    "$REPO_ROOT/scripts/bump-version.sh" "$BUMP"
  fi
else
  note "Regenerating Xcode project (no version bump)"
  xcodegen generate
fi

VERSION="$(scripts/bump-version.sh)"   # prints "GSD <marketing> (<build>)"
note "Releasing: $VERSION"

# --- clean previous artifacts -------------------------------------------------
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$BUILD_DIR"

# --- archive ------------------------------------------------------------------
note "Archiving (Release, $ARCHIVE_DEST)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$ARCHIVE_DEST" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  "${AUTH_FLAGS[@]+"${AUTH_FLAGS[@]}"}" \
  archive

# --- export the .ipa ----------------------------------------------------------
note "Exporting .ipa"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  "${AUTH_FLAGS[@]+"${AUTH_FLAGS[@]}"}"

IPA="$(/usr/bin/find "$EXPORT_PATH" -maxdepth 1 -name "$ARTIFACT_GLOB" | head -1)"
[[ -n "$IPA" ]] || die "no $ARTIFACT_GLOB produced in $EXPORT_PATH"
note "Exported: $IPA"

# --- upload to TestFlight -----------------------------------------------------
if [[ "$UPLOAD" -eq 0 ]]; then
  note "Build-only: skipping upload. Upload manually with Transporter, or re-run without --build-only."
  printf '\nDone. .ipa ready at:\n  %s\n' "$IPA"
  exit 0
fi

note "Uploading to App Store Connect / TestFlight ($AUTH_MODE)"
if [[ "$AUTH_MODE" == "apikey" ]]; then
  xcrun altool --upload-app -f "$IPA" --type "$ALTOOL_TYPE" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
else
  xcrun altool --upload-app -f "$IPA" --type "$ALTOOL_TYPE" \
    --username "$ASC_USERNAME" --password "@env:ASC_APP_PASSWORD"
fi

cat <<EOF

==> Uploaded $VERSION to App Store Connect.
    • Processing takes ~5-15 min; the build then appears in TestFlight.
    • Set the export-compliance answer and assign testers in App Store Connect.
    • Remember to commit + tag the version bump, e.g.:
        git commit -am "chore(release): $VERSION"
        git tag "v$(scripts/bump-version.sh | sed -E 's/GSD ([^ ]+).*/\1/')"
EOF
