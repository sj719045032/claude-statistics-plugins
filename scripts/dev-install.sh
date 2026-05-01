#!/bin/bash
set -euo pipefail

# Build a single plugin and copy the resulting `.csplugin` straight
# into the host's user plugin directory so the next launch picks up
# changes without going through the marketplace pipeline.
#
# Usage:
#   bash scripts/dev-install.sh <PluginName> [--keep-build]
#
# Example:
#   bash scripts/dev-install.sh GLMSubscriptionPlugin
#
# What this skips vs `release-plugins.sh`:
# - No xcframework symlink rewrites, no zip, no checksum recomputation,
#   no GitHub release, no index.json update, no git push. Pure
#   "build + cp + remind to relaunch."
#
# Quit and relaunch the host yourself afterwards — macOS can't truly
# unload a dlopen'd Mach-O bundle, so the running process keeps the
# old code in memory.

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <PluginName> [--keep-build]" >&2
    echo "Example: $0 GLMSubscriptionPlugin" >&2
    exit 2
fi

PLUGIN_NAME="$1"
KEEP_BUILD=0
if [ "${2:-}" = "--keep-build" ]; then
    KEEP_BUILD=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

if ! command -v xcodegen >/dev/null; then
    echo "==> xcodegen not installed. brew install xcodegen" >&2
    exit 3
fi

USER_PLUGIN_DIR="${HOME}/Library/Application Support/Claude Statistics/Plugins"
BUILD_DIR="/tmp/${PLUGIN_NAME}-dev-build"
PRODUCT="${BUILD_DIR}/Build/Products/Release/${PLUGIN_NAME}.csplugin"

echo "==> Regenerating xcodeproj..."
xcodegen --quiet

echo "==> Building ${PLUGIN_NAME}..."
rm -rf "${BUILD_DIR}"
xcodebuild \
    -project ClaudeStatisticsPlugins.xcodeproj \
    -scheme "${PLUGIN_NAME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    -quiet \
    > /dev/null

if [ ! -d "${PRODUCT}" ]; then
    echo "==> Build did not produce ${PRODUCT}" >&2
    exit 4
fi

mkdir -p "${USER_PLUGIN_DIR}"
DEST="${USER_PLUGIN_DIR}/${PLUGIN_NAME}.csplugin"

echo "==> Replacing ${DEST}..."
rm -rf "${DEST}"
cp -R "${PRODUCT}" "${DEST}"

if [ "${KEEP_BUILD}" -eq 0 ]; then
    rm -rf "${BUILD_DIR}"
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CSPluginManifest:version" "${DEST}/Contents/Info.plist" 2>/dev/null || echo '?')"

cat <<EOF

==> Done. ${PLUGIN_NAME} v${VERSION} installed to:
    ${DEST}

NOTE: macOS keeps dlopen'd plugins in memory until process exit.
      Quit and relaunch Claude Statistics to load the new build.
EOF
