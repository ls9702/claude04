#!/usr/bin/env bash
# Mac: 연결된 iPhone에 Debug 빌드 설치. UDID는 scripts/device.local 에 한 줄로 저장 (gitignore).
# UDID 확인: xcrun devicectl list devices
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE_FILE="scripts/device.local"
[ -f "$DEVICE_FILE" ] || { echo "UDID 파일 없음. 'xcrun devicectl list devices' 로 확인 후 $DEVICE_FILE 에 저장"; exit 1; }
UDID=$(tr -d '[:space:]' < "$DEVICE_FILE")
# 서명 팀 ID(Apple ID Personal Team). project.yml의 DEVELOPMENT_TEAM은 비워 두고, 개인 값은 scripts/team.local(gitignore)에 둔다.
# 확인: Xcode > Settings > Accounts에서 팀 선택 후 project.pbxproj의 DEVELOPMENT_TEAM, 또는 Accounts 화면의 Team ID.
TEAM_FILE="scripts/team.local"
TEAM_ARGS=()
if [ -f "$TEAM_FILE" ]; then
  TEAM_ARGS=(DEVELOPMENT_TEAM="$(tr -d '[:space:]' < "$TEAM_FILE")" CODE_SIGN_STYLE=Automatic)
else
  echo "경고: $TEAM_FILE 없음 — 팀 ID를 한 줄로 저장하면 무료 서명이 자동으로 됩니다"
fi
xcodegen generate --quiet
DERIVED="${DERIVED:-/tmp/tripshot-derived}"
# -quiet 빌드는 성공 시 아무것도 출력하지 않아 grep이 1을 반환한다 → pipefail로 스크립트가 끊기지 않게 set +e.
set +e
xcodebuild -project TripShot.xcodeproj -scheme TripShot -destination "id=$UDID" \
  -configuration Debug -derivedDataPath "$DERIVED" -allowProvisioningUpdates "${TEAM_ARGS[@]}" -quiet build 2>&1 \
  | tee /tmp/tripshot-device-build.log | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
STATUS=${PIPESTATUS[0]}
set -e
[ "$STATUS" -eq 0 ] || { echo "기기용 빌드 실패(exit $STATUS). 전체 로그: /tmp/tripshot-device-build.log"; exit "$STATUS"; }
APP=$(find "$DERIVED/Build/Products/Debug-iphoneos" -maxdepth 1 -name "TripShot.app" | head -1)
[ -n "$APP" ] || { echo "앱 번들을 찾지 못함"; exit 1; }
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" com.ls9702.tripshot || true
echo "설치 완료. 무료 서명은 7일 유효."
