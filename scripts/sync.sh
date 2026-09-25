#!/usr/bin/env bash
# 공유 브랜치와 동기화: pull --rebase 후 push.
set -euo pipefail
cd "$(dirname "$0")/.."
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git pull --rebase origin "$BRANCH"
git push origin "$BRANCH"
