#!/usr/bin/env bash
# Mac: XcodeGen으로 프로젝트 생성 후 시뮬레이터용 빌드. 오류만 추려서 출력.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen 없음: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
SIM="${SIM:-platform=iOS Simulator,name=iPhone 17}"
set +e
xcodebuild -project TripShot.xcodeproj -scheme TripShot -destination "$SIM" \
  -configuration Debug -quiet build 2>&1 | tee /tmp/tripshot-build.log | grep -E "error:|warning: unused|BUILD (SUCCEEDED|FAILED)"
STATUS=${PIPESTATUS[0]}
set -e
echo "전체 로그: /tmp/tripshot-build.log"
exit $STATUS
