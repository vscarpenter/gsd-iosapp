#!/usr/bin/env bash
#
# bump-version.sh — bump the GSD app's marketing version and/or build number.
#
# Version is project-wide: project.yml lines `MARKETING_VERSION` (the user-facing
# CFBundleShortVersionString) and `CURRENT_PROJECT_VERSION` (the CFBundleVersion
# build number) are the single source of truth — every target inherits them via
# $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION). This script rewrites only those
# two assignment lines, then regenerates the Xcode project so the change takes effect.
#
# Usage:
#   scripts/bump-version.sh                 # print the current version, change nothing
#   scripts/bump-version.sh build           # build +1            (0.5 (2)  -> 0.5 (3))
#   scripts/bump-version.sh patch           # marketing patch +1  (0.5 (2)  -> 0.5.1 (3))
#   scripts/bump-version.sh minor           # marketing minor +1  (0.5 (2)  -> 0.6 (3))
#   scripts/bump-version.sh major           # marketing major +1  (0.5 (2)  -> 1.0 (3))
#   scripts/bump-version.sh set 1.0 5       # set explicit version + build
#
# A major/minor/patch bump also auto-increments the build number, so every release
# is a valid App Store upload (App Store Connect rejects a build whose CFBundleVersion
# did not increase). The script does NOT commit or tag — it leaves the edit staged in
# your working tree for review.

set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  # Print the leading comment block (skipping the shebang), stripping "# ".
  # Stops at the first non-comment line so it never leaks code, regardless of
  # how the header grows.
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# --- locate the repo and project.yml (works from any subdirectory) ------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a git repository"
PROJECT_YML="$REPO_ROOT/project.yml"
[[ -f "$PROJECT_YML" ]] || die "project.yml not found at $PROJECT_YML"

# --- read a settings-level assignment (not a \$(...) reference) ---------------
# Matches a line like `    MARKETING_VERSION: "0.5"`; ignores reference lines such
# as `CFBundleShortVersionString: "\$(MARKETING_VERSION)"` (different key).
read_value() {
  local key="$1"
  sed -n -E "s/^[[:space:]]*${key}:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*\$/\1/p" \
    "$PROJECT_YML" | head -1
}

# --- rewrite a settings-level assignment line in place ------------------------
# Group 1 preserves the original indentation + `KEY: `; the value is replaced.
write_value() {
  local key="$1" value="$2"
  sed -i '' -E "s|^([[:space:]]*${key}:[[:space:]]*).*|\1\"${value}\"|" "$PROJECT_YML"
}

# --- semver math: bump major|minor|patch, preserving component count ----------
# 2-component versions stay 2-component for major/minor (0.5 -> 0.6); a patch bump
# adds the third component (0.5 -> 0.5.1). 3-component versions zero the lower parts.
bump_marketing() {
  local part="$1" current="$2" major minor patch has_patch=0
  IFS='.' read -r major minor patch <<< "$current"
  major=${major:-0}; minor=${minor:-0}
  [[ -n "${patch:-}" ]] && has_patch=1
  case "$part" in
    major) major=$((major + 1)); minor=0; [[ $has_patch -eq 1 ]] && patch=0 ;;
    minor) minor=$((minor + 1));          [[ $has_patch -eq 1 ]] && patch=0 ;;
    patch) patch=$(( ${patch:-0} + 1 )); has_patch=1 ;;
  esac
  if [[ $has_patch -eq 1 ]]; then
    printf '%s.%s.%s\n' "$major" "$minor" "$patch"
  else
    printf '%s.%s\n' "$major" "$minor"
  fi
}

# --- current values -----------------------------------------------------------
cur_mv="$(read_value MARKETING_VERSION)"
cur_cv="$(read_value CURRENT_PROJECT_VERSION)"
[[ -n "$cur_mv" ]] || die "could not read MARKETING_VERSION from project.yml"
[[ -n "$cur_cv" ]] || die "could not read CURRENT_PROJECT_VERSION from project.yml"

cmd="${1:-}"

# --- no argument: report current version and exit -----------------------------
if [[ -z "$cmd" ]]; then
  printf 'GSD %s (%s)\n' "$cur_mv" "$cur_cv"
  exit 0
fi

case "$cmd" in
  -h|--help|help) usage; exit 0 ;;
  build)
    new_mv="$cur_mv"
    new_cv=$((cur_cv + 1))
    ;;
  major|minor|patch)
    new_mv="$(bump_marketing "$cmd" "$cur_mv")"
    new_cv=$((cur_cv + 1))
    ;;
  set)
    new_mv="${2:-}"; new_cv="${3:-}"
    [[ "$new_mv" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
      || die "invalid version '$new_mv' (expected N, N.N, or N.N.N)"
    [[ "$new_cv" =~ ^[0-9]+$ ]] \
      || die "invalid build '$new_cv' (expected a positive integer)"
    if (( new_cv <= cur_cv )); then
      printf 'warning: build %s is not greater than current %s — App Store Connect requires an increase\n' \
        "$new_cv" "$cur_cv" >&2
    fi
    ;;
  *)
    die "unknown command '$cmd' (try: build, patch, minor, major, set, or no arg — see --help)"
    ;;
esac

# --- xcodegen must be available before we touch anything ----------------------
command -v xcodegen >/dev/null 2>&1 \
  || die "xcodegen not found — install with 'brew install xcodegen', then re-run"

# --- apply, regenerate, report ------------------------------------------------
write_value MARKETING_VERSION "$new_mv"
write_value CURRENT_PROJECT_VERSION "$new_cv"

printf 'Bumped: %s (%s)  ->  %s (%s)\n\n' "$cur_mv" "$cur_cv" "$new_mv" "$new_cv"

printf 'Regenerating Xcode project...\n'
( cd "$REPO_ROOT" && xcodegen generate )

printf '\n--- project.yml ---\n'
git -C "$REPO_ROOT" --no-pager diff -- project.yml

printf '\n--- regenerated files (summary) ---\n'
git -C "$REPO_ROOT" --no-pager diff --stat -- App/Info.plist GSD.xcodeproj/project.pbxproj

printf '\nReview the diff, then commit when ready, e.g.:\n'
printf '  git commit -am "chore: bump version to %s (%s)"\n' "$new_mv" "$new_cv"
