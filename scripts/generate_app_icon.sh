#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_NAME="AppIcon"
ASSET_DIR="${ROOT_DIR}/assets"
SRC_PNG="${ASSET_DIR}/${ICON_NAME}-1024.png"
OUT_ICNS="${ASSET_DIR}/${ICON_NAME}.icns"
ICONSET_DIR="${ROOT_DIR}/.build/${ICON_NAME}-$(date +%Y%m%d-%H%M%S).iconset"

mkdir -p "${ASSET_DIR}" "${ROOT_DIR}/.build"

if [[ -f "${SRC_PNG}" ]]; then
  mkdir -p "${ICONSET_DIR}"

  make_icon() {
    local px="$1"
    local name="$2"
    sips -z "${px}" "${px}" "${SRC_PNG}" --out "${ICONSET_DIR}/${name}" >/dev/null
  }

  make_icon 16 icon_16x16.png
  make_icon 32 icon_16x16@2x.png
  make_icon 32 icon_32x32.png
  make_icon 64 icon_32x32@2x.png
  make_icon 128 icon_128x128.png
  make_icon 256 icon_128x128@2x.png
  make_icon 256 icon_256x256.png
  make_icon 512 icon_256x256@2x.png
  make_icon 512 icon_512x512.png
  make_icon 1024 icon_512x512@2x.png

  iconutil -c icns "${ICONSET_DIR}" -o "${OUT_ICNS}"
  echo "Generated app icon from PNG: ${OUT_ICNS}"
  exit 0
fi

if [[ -f "${OUT_ICNS}" ]]; then
  echo "Using existing icon: ${OUT_ICNS}"
  exit 0
fi

for fallback in \
  "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns" \
  "/System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.icns" \
  "/System/Applications/App Store.app/Contents/Resources/AppIcon.icns"
do
  if [[ -f "${fallback}" ]]; then
    cp "${fallback}" "${OUT_ICNS}"
    echo "No custom icon PNG found. Copied fallback icon: ${fallback}"
    echo "Output: ${OUT_ICNS}"
    exit 0
  fi
done

echo "Failed to prepare icon. Add ${SRC_PNG} (1024x1024 PNG) and retry."
exit 1
