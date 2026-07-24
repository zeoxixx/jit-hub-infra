#!/usr/bin/env bash

# =========================================================
# EKS-B → EKS-A Primary 원복
#
# Terraform 작업 없음
# ApplicationSet 작업 없음
# GitOps 작업 없음
#
# cloudflared replica만 이동한다.
# =========================================================

set -Eeuo pipefail

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  pwd
)"

export SCENARIO="restore-primary"
export RUN_ID="${RUN_ID:-$(date '+%Y%m%d-%H%M%S')}"

# shellcheck source=00-failover-common.sh
source "${SCRIPT_DIR}/00-failover-common.sh"


ORIGINAL_A_REPLICAS=0
ORIGINAL_B_REPLICAS=0
ORIGINAL_ONPREM_REPLICAS=0

A_CHANGED=false
B_CHANGED=false
ONPREM_CHANGED=false


rollback() {
  local exit_code="${1:-1}"

  log WARN \
    "Primary 원복 실패. 기존 replica 상태로 롤백 시작"

  # 기존 서비스 경로 복구
  if [[ "$B_CHANGED" == true ]]; then
    scale_cloudflared \
      "$CTX_B" \
      "$ORIGINAL_B_REPLICAS" \
      || true
  fi

  if [[ "$ONPREM_CHANGED" == true ]]; then
    scale_cloudflared \
      "$CTX_ONPREM" \
      "$ORIGINAL_ONPREM_REPLICAS" \
      || true
  fi

  if [[ "$A_CHANGED" == true ]]; then
    scale_cloudflared \
      "$CTX_A" \
      "$ORIGINAL_A_REPLICAS" \
      || true
  fi

  finish_script \
    "FAILED" \
    "Primary replica 원복 실패 및 기존 상태 복구"

  exit "$exit_code"
}


main() {
  log INFO \
    "EKS-B → EKS-A Primary 트래픽 원복 시작"

  log INFO \
    "Terraform 및 GitOps 작업 없이 cloudflared replica만 이동"

  require_command kubectl
  require_command curl

  # -------------------------------------------------------
  # 1. EKS-A 복구 상태 확인
  # -------------------------------------------------------

  run_step \
    "check_eks_a_context" \
    "$CTX_A" \
    check_context "$CTX_A" \
    || rollback $?

  run_step \
    "check_eks_a_cluster" \
    "$CTX_A" \
    check_cluster "$CTX_A" \
    || rollback $?

  run_step \
    "wait_eks_a_nodes" \
    "$CTX_A" \
    wait_for_nodes "$CTX_A" \
    || rollback $?

  run_step \
    "wait_eks_a_app_pods" \
    "$CTX_A" \
    wait_for_app_pods "$CTX_A" \
    || rollback $?

  run_step \
    "eks_a_internal_health" \
    "$CTX_A" \
    check_internal_health "$CTX_A" \
    || rollback $?

  capture_cluster_state \
    "$CTX_A" \
    "before-primary-restore"

  # -------------------------------------------------------
  # 2. 기존 replica 기록
  # -------------------------------------------------------

  ORIGINAL_A_REPLICAS="$(
    get_cloudflared_replicas "$CTX_A"
  )"

  if context_is_available "$CTX_B"; then
    ORIGINAL_B_REPLICAS="$(
      get_cloudflared_replicas "$CTX_B"
    )"
  fi

  if context_is_available "$CTX_ONPREM"; then
    ORIGINAL_ONPREM_REPLICAS="$(
      get_cloudflared_replicas "$CTX_ONPREM"
    )"
  fi

  log INFO \
    "원복 전 replica eks-a=${ORIGINAL_A_REPLICAS} eks-b=${ORIGINAL_B_REPLICAS} onprem=${ORIGINAL_ONPREM_REPLICAS}"

  # -------------------------------------------------------
  # 3. EKS-A cloudflared 활성화
  # -------------------------------------------------------

  run_step \
    "activate_cloudflared" \
    "eks-a" \
    scale_cloudflared "$CTX_A" 1 \
    || rollback $?

  A_CHANGED=true

  log INFO \
    "make-before-break: EKS-A connector 활성화 완료"

  # -------------------------------------------------------
  # 4. EKS-B cloudflared 비활성화
  # -------------------------------------------------------

  if context_is_available "$CTX_B"; then
    run_step \
      "deactivate_cloudflared" \
      "eks-b" \
      scale_cloudflared "$CTX_B" 0 \
      || rollback $?

    B_CHANGED=true
  else
    log WARN \
      "EKS-B context 또는 API 접근 불가. replica 축소 생략"
  fi

  # -------------------------------------------------------
  # 5. 온프레미스에 connector가 남아 있으면 정리
  # -------------------------------------------------------

  if context_is_available "$CTX_ONPREM"; then
    if [[ "$ORIGINAL_ONPREM_REPLICAS" -gt 0 ]]; then
      run_step \
        "deactivate_cloudflared" \
        "onprem" \
        scale_cloudflared "$CTX_ONPREM" 0 \
        || rollback $?

      ONPREM_CHANGED=true
    fi
  fi

  # -------------------------------------------------------
  # 6. 외부 health 확인
  # -------------------------------------------------------

  run_step \
    "external_health_after_primary_restore" \
    "eks-a" \
    check_external_health \
    || rollback $?

  capture_cluster_state \
    "$CTX_A" \
    "after-primary-restore"

  log INFO \
    "EKS-B → EKS-A Primary 트래픽 원복 완료"

  finish_script \
    "SUCCESS" \
    "cloudflared replica를 EKS-B에서 EKS-A로 이동 완료"
}

main "$@"