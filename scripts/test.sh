#!/usr/bin/env bash
# Mac: 시뮬레이터에서 단위 테스트 실행.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
SIM="${SIM:-platform=iOS Simulator,name=iPhone 17}"
xcodebuild -project TripShot.xcodeproj -scheme TripShot -destination "$SIM" \
  -quiet test 2>&1 | tee /tmp/tripshot-test.log | grep -E "error:|Test Case|Executed|TEST (SUCCEEDED|FAILED)"
echo "전체 로그: /tmp/tripshot-test.log"
