#!/bin/bash
set -euo pipefail

# Package a built `.csplugin` directory into a `.csplugin.zip`
# payload the host's `PluginInstaller` can consume. Outputs the zip
# + a sidecar `<name>.sha256` to `build/marketplace/`.
#
# Usage:
#   bash scripts/pack-csplugin.sh <PluginName> [build-products-dir]
#
# Without `build-products-dir`, looks under
#   build/Debug/<Name>.csplugin
#   build/Release/<Name>.csplugin
# (where `xcodebuild -derivedDataPath build` writes by default).
# Pass an explicit path when calling from another script that built
# elsewhere — `release-plugins.sh` does this.

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <PluginName> [build-products-dir]" >&2
    exit 2
fi

PLUGIN_NAME="$1"
SOURCE_OVERRIDE="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/build/marketplace"
mkdir -p "${OUTPUT_DIR}"

SOURCE_BUNDLE=""
if [ -n "${SOURCE_OVERRIDE}" ]; then
    candidate="${SOURCE_OVERRIDE}/${PLUGIN_NAME}.csplugin"
    if [ -d "${candidate}" ]; then
        SOURCE_BUNDLE="${candidate}"
    else
        echo "==> ${PLUGIN_NAME}.csplugin not found at ${candidate}" >&2
        exit 3
    fi
else
    for config in Debug Release; do
        candidate="${REPO_ROOT}/build/${config}/${PLUGIN_NAME}.csplugin"
        if [ -d "${candidate}" ]; then
            SOURCE_BUNDLE="${candidate}"
            break
        fi
    done

    if [ -z "${SOURCE_BUNDLE}" ]; then
        echo "==> ${PLUGIN_NAME}.csplugin not found under build/{Debug,Release}/" >&2
        echo "    Run \`bash scripts/release-plugins.sh <version>\` (or invoke" >&2
        echo "    xcodegen + xcodebuild manually) first to produce the bundle." >&2
        exit 3
    fi
fi

ZIP_PATH="${OUTPUT_DIR}/${PLUGIN_NAME}.csplugin.zip"
SHA_PATH="${OUTPUT_DIR}/${PLUGIN_NAME}.sha256"

PARENT="$(dirname "${SOURCE_BUNDLE}")"
BASENAME="$(basename "${SOURCE_BUNDLE}")"

echo "==> Packing ${SOURCE_BUNDLE}"
rm -f "${ZIP_PATH}"
( cd "${PARENT}" && zip -qrX "${ZIP_PATH}" "${BASENAME}" )

if [ ! -f "${ZIP_PATH}" ]; then
    echo "==> Failed to produce ${ZIP_PATH}" >&2
    exit 4
fi

SHA="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
echo "${SHA}  $(basename "${ZIP_PATH}")" > "${SHA_PATH}"

SIZE="$(stat -f%z "${ZIP_PATH}")"
echo "==> Done"
echo "    zip:    ${ZIP_PATH}  (${SIZE} bytes)"
echo "    sha256: ${SHA}"
