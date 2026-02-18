#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SokuchoNative"
BUNDLE_ID="com.saitosatoshi.sokuchonative"
MIN_MACOS="13.0"
APP_VERSION="1.0.0"
APP_BUILD="100"
ICON_NAME="AppIcon"
ICON_SOURCE_PATH="${ROOT_DIR}/assets/${ICON_NAME}.icns"
ICON_GENERATOR="${ROOT_DIR}/scripts/generate_app_icon.sh"

BUILD_MODE="${1:-debug}"
case "${BUILD_MODE}" in
  debug|release) ;;
  *)
    echo "Usage: $0 [debug|release]"
    exit 1
    ;;
esac

if [[ ! -f "${ICON_SOURCE_PATH}" && -f "${ICON_GENERATOR}" ]]; then
  bash "${ICON_GENERATOR}"
fi

BIN_DIR="${ROOT_DIR}/.build/arm64-apple-macosx/${BUILD_MODE}"
BIN_PATH="${BIN_DIR}/${APP_NAME}"
DIRECT_BIN_PATH=""

cd "${ROOT_DIR}"
build_with_retry() {
  local mode="$1"
  local db_err_re='accessing build database .*build\.db.*disk I/O error'

  for attempt in 1 2 3; do
    local log_file
    log_file="$(mktemp)"

    set +e
    if [[ "${mode}" == "release" ]]; then
      swift build -c release 2>&1 | tee "${log_file}"
    else
      swift build 2>&1 | tee "${log_file}"
    fi
    local status=$?
    set -e

    if [[ ${status} -eq 0 ]]; then
      return 0
    fi

    if grep -E -q "${db_err_re}" "${log_file}"; then
      echo "Build DB I/O error detected (attempt ${attempt}/3). Recreating build DB..."
      local ts
      ts="$(date +%Y%m%d-%H%M%S)-${attempt}"
      if [[ -f .build/build.db ]]; then
        mv .build/build.db ".build/build.db.bak.${ts}"
      fi
      if [[ -f .build/build.db-journal ]]; then
        mv .build/build.db-journal ".build/build.db-journal.bak.${ts}"
      fi
      continue
    fi

    return ${status}
  done

  return 2
}

compile_direct_binary() {
  local mode="$1"
  local sdk_path
  sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
  local out_path="/tmp/${APP_NAME}.direct.$(date +%Y%m%d-%H%M%S)"
  local c_flags=("-Onone" "-g")
  if [[ "${mode}" == "release" ]]; then
    c_flags=("-O")
  fi
  /Library/Developer/CommandLineTools/usr/bin/swiftc \
    -target arm64-apple-macosx13.0 \
    -sdk "${sdk_path}" \
    "${c_flags[@]}" \
    "${ROOT_DIR}/Sources/SokuchoNative/AppStore.swift" \
    "${ROOT_DIR}/Sources/SokuchoNative/MainView.swift" \
    "${ROOT_DIR}/Sources/SokuchoNative/MeasurementCanvasView.swift" \
    "${ROOT_DIR}/Sources/SokuchoNative/Models.swift" \
    "${ROOT_DIR}/Sources/SokuchoNative/SokuchoNativeApp.swift" \
    -o "${out_path}"
  DIRECT_BIN_PATH="${out_path}"
}

if ! build_with_retry "${BUILD_MODE}"; then
  echo "Build step could not complete cleanly. Trying direct compile fallback..."
  compile_direct_binary "${BUILD_MODE}"
  BIN_PATH="${DIRECT_BIN_PATH}"
fi

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "Build output not found: ${BIN_PATH}"
  exit 1
fi

DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PLIST_PATH="${CONTENTS_DIR}/Info.plist"

mkdir -p "${DIST_DIR}"
if [[ -d "${APP_DIR}" ]]; then
  BACKUP="${APP_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
  mv "${APP_DIR}" "${BACKUP}"
  echo "Previous app bundle moved to: ${BACKUP}"
fi

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod 755 "${MACOS_DIR}/${APP_NAME}"

ICON_KEY_BLOCK=""
if [[ -f "${ICON_SOURCE_PATH}" ]]; then
  cp "${ICON_SOURCE_PATH}" "${RESOURCES_DIR}/${ICON_NAME}.icns"
  ICON_KEY_BLOCK=$'  <key>CFBundleIconFile</key>\n  <string>'"${ICON_NAME}"$'</string>'
fi

cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ja</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
${ICON_KEY_BLOCK}
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_MACOS}</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - --timestamp=none "${APP_DIR}" >/dev/null 2>&1 || true
fi

echo "Created app bundle: ${APP_DIR}"
