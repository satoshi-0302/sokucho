#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SokuchoNative"
DIST_DIR="${ROOT_DIR}/dist"
APP_PATH="${DIST_DIR}/${APP_NAME}.app"
BUILD_SCRIPT="${ROOT_DIR}/scripts/build_app_bundle.sh"

BUILD_MODE="${1:-debug}"
case "${BUILD_MODE}" in
  debug|release) ;;
  *)
    echo "Usage: $0 [debug|release]"
    exit 1
    ;;
esac

bash "${BUILD_SCRIPT}" "${BUILD_MODE}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "App bundle not found: ${APP_PATH}"
  exit 1
fi

STAGE_DIR="${DIST_DIR}/.dmg-stage"
if [[ -d "${STAGE_DIR}" ]]; then
  mv "${STAGE_DIR}" "${STAGE_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "${STAGE_DIR}"

cp -R "${APP_PATH}" "${STAGE_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGE_DIR}/Applications"

DMG_PATH="${DIST_DIR}/${APP_NAME}-${BUILD_MODE}.dmg"
if [[ -f "${DMG_PATH}" ]]; then
  mv "${DMG_PATH}" "${DMG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
fi

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}" >/dev/null

echo "Created DMG: ${DMG_PATH}"
