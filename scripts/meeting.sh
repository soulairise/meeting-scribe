#!/bin/bash
# 녹음부터 회의록·강의기록 생성까지 한 번에.
#
#   ./scripts/meeting.sh 600            10분 회의 녹음 후 회의록 생성
#   ./scripts/meeting.sh 600 lecture    10분 강의 녹음 후 강의기록 생성
#   ./scripts/meeting.sh                Ctrl+C 까지 녹음 (끝나면 수동으로 pipeline 실행)
set -euo pipefail
cd "$(dirname "$0")/.."

SECS="${1:-}"
MODE="${2:-meeting}"
OUT="$PWD/recordings"

[ -d build/MeetingScribe.app ] || ./scripts/build-app.sh release >/dev/null

if [ -z "$SECS" ]; then
  echo "녹음 시간을 지정하세요: ./scripts/meeting.sh <초> [meeting|lecture]"
  exit 1
fi

echo "▶ ${SECS}초 녹음합니다."
open build/MeetingScribe.app --args --out "$OUT" --seconds "$SECS"
sleep $((SECS + 4))          # WAV 헤더 확정까지 여유를 둔다

REC=$(ls -td "$OUT"/*/ | head -1)
echo "▶ 녹음 완료: $REC"
python3 scripts/pipeline.py "$REC" --mode "$MODE"
echo
echo "결과: $REC$MODE.md"
