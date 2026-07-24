#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  pwd
)"

RUN_ID="$(date '+%Y%m%d-%H%M%S')"

echo "DR 대응 시작"
echo "RUN_ID=${RUN_ID}"

RUN_ID="$RUN_ID" \
  "${SCRIPT_DIR}/01-switch-to-onprem.sh" &
PID_ONPREM=$!

RUN_ID="$RUN_ID" \
  "${SCRIPT_DIR}/02-provision-dr.sh" &
PID_DR=$!

wait "$PID_ONPREM"
RESULT_ONPREM=$?

wait "$PID_DR"
RESULT_DR=$?

echo
echo "온프레미스 긴급 전환 결과: ${RESULT_ONPREM}"
echo "EKS-B DR 구축 결과:       ${RESULT_DR}"

if [[ "$RESULT_ONPREM" -ne 0 ]] || [[ "$RESULT_DR" -ne 0 ]]; then
  echo "DR 대응 작업 중 하나 이상 실패했습니다."
  exit 1
fi

echo "전체 DR 대응 작업이 완료되었습니다."