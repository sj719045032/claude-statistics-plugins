#!/bin/bash
set -euo pipefail

# Cut a v<version> release of every plugin in this catalog: xcodegen
# the project, xcodebuild every target, pack each `.csplugin` into a
# zip, refresh `index.json` with the new sha256s + downloadURLs, push
# both the catalog commit and the GitHub release.
#
# Usage:
#   bash scripts/release-plugins.sh <version>
#
# Example:
#   bash scripts/release-plugins.sh 1.0.0
#
# Prereqs:
# - `xcodegen` on PATH (brew install xcodegen).
# - `gh` CLI authenticated to `sj719045032` (the catalog repo owner).
# - The host repo's `Package.swift` `binaryTarget` URL points at a
#   reachable `sdk-v<x.y.z>` release on `claude-statistics` —
#   xcodebuild fetches the SDK xcframework via SwiftPM at resolve
#   time, so the SDK release must exist before this script runs.
# - `jq` on PATH (Apple ships it).

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <version>" >&2
    echo "Example: $0 1.0.0" >&2
    exit 2
fi

VERSION="$1"
if ! echo "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "==> Version must be pure dotted-numeric (got '${VERSION}')." >&2
    exit 2
fi

if ! command -v xcodegen >/dev/null; then
    echo "==> xcodegen not installed. brew install xcodegen" >&2
    exit 3
fi
if ! command -v gh >/dev/null; then
    echo "==> gh not installed. brew install gh" >&2
    exit 3
fi
if ! command -v jq >/dev/null; then
    echo "==> jq not installed (should ship with macOS)." >&2
    exit 3
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

CATALOG_REMOTE_URL="https://github.com/sj719045032/claude-statistics-plugins"
DOWNLOAD_URL_PREFIX="${CATALOG_REMOTE_URL}/releases/download/v${VERSION}"
BUILD_DIR="${REPO_ROOT}/build/release-build"
PRODUCTS_DIR="${BUILD_DIR}/Build/Products/Release"
MARKETPLACE_DIR="${REPO_ROOT}/build/marketplace"
INDEX_JSON="${REPO_ROOT}/index.json"

# Pre-flight: refuse to proceed if the catalog has uncommitted
# changes — the sha rewrite below would silently swallow them.
if [ -n "$(git status --porcelain index.json)" ]; then
    echo "==> index.json has uncommitted changes. Commit or stash first." >&2
    exit 4
fi

# Refuse if the GitHub release tag already exists — gh would error
# out anyway, but a pre-check fails fast and tells the operator
# what's wrong.
if gh release view "v${VERSION}" --repo "${CATALOG_REMOTE_URL}" >/dev/null 2>&1; then
    echo "==> Release v${VERSION} already exists on ${CATALOG_REMOTE_URL}." >&2
    exit 4
fi

# Pre-flight: every plugin's Swift `static let manifest.version`
# must agree with its sibling `Info.plist` `CSPluginManifest:version`.
# Drift between the two is invisible at build time but causes the
# host's Discover panel to display a permanent (un-resolvable)
# "Restart" badge — the dlopen'd Mach-O ships the Swift manifest, the
# host's stale-bundle check reads the plist, and a relaunch can't
# reconcile a version the source itself doesn't yet declare. Catch it
# here so a relased plugin never reaches users in that broken state.
echo "==> Validating manifest version parity (Swift static manifest ↔ Info.plist)..."
DRIFT_LIST=""
DRIFT_COUNT=0
for plist in "${REPO_ROOT}/Sources/"*/Info.plist; do
    plugin_dir="$(dirname "${plist}")"
    plugin_name="$(basename "${plugin_dir}")"
    swift_file="${plugin_dir}/${plugin_name}.swift"
    [ -f "${swift_file}" ] || continue

    plist_version="$(/usr/libexec/PlistBuddy -c "Print :CSPluginManifest:version" "${plist}" 2>/dev/null || true)"
    swift_version="$(grep -E "version: SemVer\(major: [0-9]+, minor: [0-9]+, patch: [0-9]+\)" "${swift_file}" \
        | head -1 \
        | sed -E 's/.*major: ([0-9]+), minor: ([0-9]+), patch: ([0-9]+).*/\1.\2.\3/')"

    if [ -z "${plist_version}" ] || [ -z "${swift_version}" ]; then
        continue
    fi
    if [ "${plist_version}" != "${swift_version}" ]; then
        DRIFT_LIST="${DRIFT_LIST}    ${plugin_name}: Info.plist=${plist_version}  Swift=${swift_version}\n"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    fi
done
if [ "${DRIFT_COUNT}" -gt 0 ]; then
    echo "==> ${DRIFT_COUNT} plugin(s) have manifest version drift:" >&2
    printf "${DRIFT_LIST}" >&2
    echo "    Sync the Swift source manifest and Info.plist, then re-run." >&2
    exit 4
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Releasing catalog plugins v${VERSION}"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Step 1: xcodegen + xcodebuild ─────────────────────────────────────────────

echo "==> [1/5] Generating Xcode project..."
xcodegen generate 2>&1 | tail -1

echo "==> Building all plugin targets (Release configuration)..."
rm -rf "${BUILD_DIR}"
xcodebuild -project ClaudeStatisticsPlugins.xcodeproj \
    -alltargets \
    -configuration Release \
    SYMROOT="${BUILD_DIR}/Build/Products" \
    OBJROOT="${BUILD_DIR}/Build/Intermediates" \
    build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5

if [ ! -d "${PRODUCTS_DIR}" ]; then
    echo "==> ${PRODUCTS_DIR} not produced. xcodebuild failed?" >&2
    exit 5
fi

# ── Step 2: Pack every produced .csplugin into a zip ─────────────────────────

echo ""
echo "==> [2/5] Packing .csplugin bundles..."
rm -rf "${MARKETPLACE_DIR}"
mkdir -p "${MARKETPLACE_DIR}"
PACKED_COUNT=0
for csplugin in "${PRODUCTS_DIR}"/*.csplugin; do
    [ -d "${csplugin}" ] || continue
    name="$(basename "${csplugin}" .csplugin)"
    bash "${SCRIPT_DIR}/pack-csplugin.sh" "${name}" "${PRODUCTS_DIR}" >/dev/null
    PACKED_COUNT=$((PACKED_COUNT + 1))
done
echo "    Packed ${PACKED_COUNT} bundles → ${MARKETPLACE_DIR}/"

if [ "${PACKED_COUNT}" -eq 0 ]; then
    echo "==> No .csplugin bundles produced. project.yml empty or build broken?" >&2
    exit 5
fi

# ── Step 3: Update index.json ─────────────────────────────────────────────────

echo ""
echo "==> [3/5] Updating index.json..."
TMPFILE="$(mktemp)"
cp "${INDEX_JSON}" "${TMPFILE}"
TOUCHED=0
for sidecar in "${MARKETPLACE_DIR}"/*.sha256; do
    [ -f "${sidecar}" ] || continue
    NAME="$(basename "${sidecar}" .sha256)"
    SHA="$(awk '{print $1}' "${sidecar}")"
    FRAG="${NAME}.csplugin.zip"
    URL="${DOWNLOAD_URL_PREFIX}/${FRAG}"

    BEFORE="$(jq -r --arg f "${FRAG}" \
        '[.entries[] | select(.downloadURL | endswith($f)) | .sha256] | .[0] // ""' \
        "${TMPFILE}")"

    jq --arg f "${FRAG}" --arg s "${SHA}" --arg v "${VERSION}" --arg u "${URL}" \
        '.entries |= map(if (.downloadURL | endswith($f)) then
            .sha256 = $s | .version = $v | .downloadURL = $u
        else . end)' \
        "${TMPFILE}" > "${TMPFILE}.new"
    mv "${TMPFILE}.new" "${TMPFILE}"

    AFTER="$(jq -r --arg f "${FRAG}" \
        '[.entries[] | select(.downloadURL | endswith($f)) | .sha256] | .[0] // ""' \
        "${TMPFILE}")"

    if [ -z "${BEFORE}" ]; then
        echo "    ! ${NAME}: no matching entry in index.json (skipped — orphan plugin?)"
    elif [ "${BEFORE}" != "${AFTER}" ]; then
        TOUCHED=$((TOUCHED + 1))
    fi
done

UPDATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
jq --arg t "${UPDATED_AT}" '.updatedAt = $t' "${TMPFILE}" > "${INDEX_JSON}"
rm -f "${TMPFILE}"
echo "    Updated ${TOUCHED} entries (updatedAt → ${UPDATED_AT})"

# ── Step 4: Commit + push ─────────────────────────────────────────────────────

echo ""
echo "==> [4/5] Committing index.json + pushing..."
if git diff --quiet index.json; then
    echo "    No changes (every sha already matched). Skipping commit."
else
    git add index.json
    git commit -m "chore: sync index.json with v${VERSION} release shas"
    git push
    echo "    Pushed."
fi

# ── Step 5: GitHub release ────────────────────────────────────────────────────

echo ""
echo "==> [5/5] Creating GitHub release v${VERSION}..."
RELEASE_URL=$(gh release create "v${VERSION}" \
    "${MARKETPLACE_DIR}"/*.csplugin.zip \
    --repo "${CATALOG_REMOTE_URL}" \
    --title "Plugin bundles v${VERSION}" \
    --notes "Plugin bundles built against the host repo's current sdk-v<x.y.z> SDK xcframework. See README for the catalog → host SDK linkage.")

echo "    Release: ${RELEASE_URL}"
echo ""
echo "✓ Catalog v${VERSION} complete!"
echo ""
echo "  - ${PACKED_COUNT} plugin bundles uploaded as release assets"
echo "  - ${TOUCHED} index.json entries refreshed + pushed to main"
echo "  - raw.githubusercontent.com takes ≤ 5 min to propagate"
