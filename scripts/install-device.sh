#!/usr/bin/env bash
# Mac: 연결된 iPhone에 Debug 빌드 설치. UDID는 scripts/device.local 에 한 줄로 저장 (gitignore).
# UDID 확인: xcrun devicectl list devices
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE_FILE="scripts/device.local"
[ -f "$DEVICE_FILE" ] || { echo "UDID 파일 없음. 'xcrun devicectl list devices' 로 확인 후 $DEVICE_FILE 에 저장"; exit 1; }
UDID=$(tr -d '[:space:]' < "$DEVICE_FILE")
xcodegen generate --quiet
DERIVED="${DERIVED:-/tmp/tripshot-derived}"
xcodebuild -project TripShot.xcodeproj -scheme TripShot -destination "id=$UDID" \
  -configuration Debug -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet build 2>&1 \
  | tee /tmp/tripshot-device-build.log | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP=$(find "$DERIVED/Build/Products/Debug-iphoneos" -maxdepth 1 -name "TripShot.app" | head -1)
[ -n "$APP" ] || { echo "앱 번들을 찾지 못함"; exit 1; }
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" com.ls9702.tripshot || true
echo "설치 완료. 무료 서명은 7일 유효."
