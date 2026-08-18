#!/bin/bash

set -Eeuo pipefail

ROOT_DIR=$(pwd)

# 시간 측정 결과만 저장
LOG_FILE="${ROOT_DIR}/provision-time-$(date '+%Y%m%d-%H%M%S').log"

TOTAL_START=$(date +%s)

log_time() {
  echo "$1" | tee -a "$LOG_FILE"
}

log_time "================================="
log_time " Terraform Deployment Start"
log_time " Start: $(date '+%Y-%m-%d %H:%M:%S')"
log_time "================================="


apply_layer () {

  LAYER=$1
  LAYER_START=$(date +%s)

  log_time ""
  log_time "================================="
  log_time " Applying ${LAYER}"
  log_time "================================="

  cd "${ROOT_DIR}/${LAYER}"


  # INIT
  INIT_START=$(date +%s)

  echo "[INIT] ${LAYER}"
  terraform init

  INIT_END=$(date +%s)
  INIT_TIME=$((INIT_END - INIT_START))


  # PLAN
  PLAN_START=$(date +%s)

  echo "[PLAN] ${LAYER}"
  terraform plan -out=tfplan

  PLAN_END=$(date +%s)
  PLAN_TIME=$((PLAN_END - PLAN_START))


  # APPLY
  APPLY_START=$(date +%s)

  echo "[APPLY] ${LAYER}"
  terraform apply tfplan

  APPLY_END=$(date +%s)
  APPLY_TIME=$((APPLY_END - APPLY_START))


  # LAYER TOTAL
  LAYER_END=$(date +%s)
  LAYER_TIME=$((LAYER_END - LAYER_START))


  log_time "---------------------------------"
  log_time "$(printf '%-20s INIT %02dm %02ds | PLAN %02dm %02ds | APPLY %02dm %02ds | TOTAL %02dm %02ds' \
    "$LAYER" \
    $((INIT_TIME / 60)) $((INIT_TIME % 60)) \
    $((PLAN_TIME / 60)) $((PLAN_TIME % 60)) \
    $((APPLY_TIME / 60)) $((APPLY_TIME % 60)) \
    $((LAYER_TIME / 60)) $((LAYER_TIME % 60)))"
  log_time "---------------------------------"

  cd "$ROOT_DIR"
}


apply_layer "01-network"
apply_layer "02-eks"
apply_layer "03-platform"
apply_layer "04-eks-workloads"
apply_layer "05-eks-autoscaling"


TOTAL_END=$(date +%s)
TOTAL_TIME=$((TOTAL_END - TOTAL_START))

log_time ""
log_time "================================="
log_time " Terraform Deployment Complete"
log_time " End: $(date '+%Y-%m-%d %H:%M:%S')"
log_time "$(printf ' Total Provisioning Time: %02dm %02ds' \
  $((TOTAL_TIME / 60)) \
  $((TOTAL_TIME % 60)))"
log_time "================================="

echo ""
echo "Timing log saved to: $LOG_FILE"