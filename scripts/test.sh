#!/usr/bin/env bash
# Mac: 시뮬레이터에서 단위 테스트 실행.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
SIM="${SIM:-platform=iOS Simulator,name=iPhone 17}"
# 테스트 호스트(앱)가 뜨면서 위치 권한 대화상자가 남으면 xcodebuild가 종료를 기다리며 10분 이상 멈춘다.
# 시뮬레이터를 먼저 부팅하고 권한을 미리 허용해 둔다(실패해도 테스트는 진행).
# 테스트가 실패하면 xcodebuild가 simctl diagnose로 진단을 모으다 600초 타임아웃까지 멈추므로 수집을 끈다.
SIM_NAME=$(sed -n 's/.*name=\([^,]*\).*/\1/p' <<<"$SIM")
xcrun simctl boot "$SIM_NAME" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null 2>&1 || true
for svc in location camera photos microphone; do
  xcrun simctl privacy "$SIM_NAME" grant "$svc" com.ls9702.tripshot >/dev/null 2>&1 || true
done
xcodebuild -project TripShot.xcodeproj -scheme TripShot -destination "$SIM" \
  -collect-test-diagnostics never -quiet test 2>&1 | tee /tmp/tripshot-test.log | grep -E "error:|Test Case|Executed|TEST (SUCCEEDED|FAILED)"
echo "전체 로그: /tmp/tripshot-test.log"
