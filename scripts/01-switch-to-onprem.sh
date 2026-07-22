#!/usr/bin/env bash

# =========================================================
# EKS-A → 온프레미스 긴급 트래픽 전환
# =========================================================

set -Eeuo pipefail

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  pwd
)"

export SCENARIO="switch-to-onprem"
export RUN_ID="${RUN_ID:-$(date '+%Y%m%d-%H%M%S')}"

# shellcheck source=00-failover-common.sh
source "${SCRIPT_DIR}/00-failover-common.sh"


ORIGINAL_A_REPLICAS=0
ORIGINAL_ONPREM_REPLICAS=0

ONPREM_CHANGED=false
A_CHANGED=false


rollback() {
  local exit_code="${1:-1}"

  log WARN \
    "온프레미스 전환 실패. 기존 replica 상태로 롤백 시작"

  # 기존 서비스 경로인 EKS-A부터 복구
  if [[ "$A_CHANGED" == true ]]; then
    scale_cloudflared \
      "$CTX_A" \
      "$ORIGINAL_A_REPLICAS" \
      || true
  fi

  if [[ "$ONPREM_CHANGED" == true ]]; then
    scale_cloudflared \
      "$CTX_ONPREM" \
      "$ORIGINAL_ONPREM_REPLICAS" \
      || true
  fi

  finish_script \
    "FAILED" \
    "온프레미스 전환 실패 및 replica 롤백 수행"

  exit "$exit_code"
}


main() {
  log INFO \
    "EKS-A → 온프레미스 긴급 트래픽 전환 시작"

  require_command kubectl
  require_command curl

  run_step \
    "check_context" \
    "$CTX_A" \
    check_context "$CTX_A" \
    || rollback $?

  run_step \
    "check_context" \
    "$CTX_ONPREM" \
    check_context "$CTX_ONPREM" \
    || rollback $?

  run_step \
    "check_onprem_cluster" \
    "$CTX_ONPREM" \
    check_cluster "$CTX_ONPREM" \
    || rollback $?

  # EKS-A는 장애 상황일 수 있으므로 연결 실패가 곧 스크립트 실패는 아니다.
  if check_cluster "$CTX_A"; then
    log INFO \
      "EKS-A Kubernetes API 연결 가능"
  else
    log WARN \
      "EKS-A Kubernetes API 연결 실패. 장애 상황으로 간주"
  fi

  ORIGINAL_A_REPLICAS="$(
    get_cloudflared_replicas "$CTX_A"
  )"

  ORIGINAL_ONPREM_REPLICAS="$(
    get_cloudflared_replicas "$CTX_ONPREM"
  )"

  log INFO \
    "기존 replica eks-a=${ORIGINAL_A_REPLICAS} onprem=${ORIGINAL_ONPREM_REPLICAS}"

  capture_cluster_state \
    "$CTX_ONPREM" \
    "before-switch-onprem"

  # -------------------------------------------------------
  # 온프레미스 서비스 자체 확인
  # -------------------------------------------------------

  run_step \
    "internal_health_before_switch" \
    "onprem" \
    check_internal_health "$CTX_ONPREM" \
    || rollback $?

  # -------------------------------------------------------
  # 온프레미스 cloudflared 활성화
  # -------------------------------------------------------

  run_step \
    "activate_cloudflared" \
    "onprem" \
    scale_cloudflared "$CTX_ONPREM" 1 \
    || rollback $?

  ONPREM_CHANGED=true

  log INFO \
    "make-before-break: 온프레미스 connector 활성화 완료"

  # -------------------------------------------------------
  # EKS-A cloudflared 비활성화
  #
  # EKS-A Kubernetes API 자체가 죽은 경우 scale이 불가능할 수 있다.
  # 이 경우 Cloudflare 연결은 기존 connector heartbeat 만료 후 제거된다.
  # -------------------------------------------------------

  if context_is_available "$CTX_A"; then
    run_step \
      "deactivate_cloudflared" \
      "eks-a" \
      scale_cloudflared "$CTX_A" 0 \
      || rollback $?

    A_CHANGED=true
  else
    log WARN \
      "EKS-A API 접근 불가로 replica 축소 생략"
  fi

  # -------------------------------------------------------
  # 외부 도메인 확인
  # -------------------------------------------------------

  run_step \
    "external_health_after_switch" \
    "onprem" \
    check_external_health \
    || rollback $?

  capture_cluster_state \
    "$CTX_ONPREM" \
    "after-switch-onprem"

  log INFO \
    "EKS-A → 온프레미스 긴급 트래픽 전환 완료"

  finish_script \
    "SUCCESS" \
    "온프레미스 긴급 우회 완료"
}

main "$@"