#!/bin/bash
# 회의 녹음을 시작한다.
#
# ⚠️ 반드시 `open`으로 앱을 띄운다. 셸에서 바이너리를 직접 실행하면
#    시스템 오디오 탭의 권한 주체가 부모 프로세스(터미널)가 되어 무음만 녹음된다.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/build/MeetingScribe.app"
OUT="${OUT:-$PWD/recordings}"
SECONDS_ARG="${1:-}"

[ -d "$APP" ] || { echo "앱이 없습니다. 먼저 ./scripts/build-app.sh 를 실행하세요."; exit 1; }

ARGS=(--out "$OUT")
if [ -n "$SECONDS_ARG" ]; then
  ARGS+=(--seconds "$SECONDS_ARG")
  echo "${SECONDS_ARG}초간 녹음합니다..."
else
  echo "녹음을 시작합니다. 중지하려면: pkill -INT -f MeetingScribe"
fi

BEFORE=$(ls "$OUT" 2>/dev/null | wc -l)
open "$APP" --args "${ARGS[@]}"

if [ -n "$SECONDS_ARG" ]; then
  sleep $((SECONDS_ARG + 2))
  LATEST=$(ls -td "$OUT"/*/ 2>/dev/null | head -1)
  echo "저장됨: $LATEST"
  for f in "$LATEST"mic.wav "$LATEST"system.wav; do
    [ -f "$f" ] && printf "  %-12s %s\n" "$(basename "$f")" "$(afinfo "$f" 2>/dev/null | awk -F': ' '/duration/{printf "%.1f초", $2}')"
  done
fi
