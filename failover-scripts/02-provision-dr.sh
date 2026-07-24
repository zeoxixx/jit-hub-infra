#!/usr/bin/env bash

# =========================================================
# EKS-B JIT 프로비저닝
#
# 1. 기존 Terraform state를 사용하여 02~05 apply
# 2. EKS-B kubeconfig/context 생성
# 3. 온프레미스 Argo CD Cluster Secret 생성 확인
# 4. ApplicationSet 재적용
# 5. GitOps 배포 완료 대기
# 6. 온프레미스 → EKS-B 트래픽 전환
# =========================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SCENARIO="provision-dr"
export RUN_ID="${RUN_ID:-$(date '+%Y%m%d-%H%M%S')}"

# shellcheck source=00-failover-common.sh
source "${SCRIPT_DIR}/00-failover-common.sh"


# =========================================================
# AWS / Terraform
# =========================================================

AWS_REGION="${AWS_REGION:-ap-northeast-1}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DR_BASE_DIR="${PROJECT_ROOT}/terraform/aws/envs/dr-region-b"

DR_EKS_STACK="${DR_EKS_STACK:-02-eks}"
DR_PLATFORM_STACK="${DR_PLATFORM_STACK:-03-platform}"
DR_WORKLOAD_STACK="${DR_WORKLOAD_STACK:-04-eks-workloads}"
DR_AUTOSCALING_STACK="${DR_AUTOSCALING_STACK:-05-eks-autoscaling}"

# Terraform output으로 못 찾는 경우 환경변수로 직접 지정
DR_CLUSTER_NAME="${DR_CLUSTER_NAME:-}"


# =========================================================
# Traffic rollback 상태
# =========================================================

ORIGINAL_A_REPLICAS=0
ORIGINAL_ONPREM_REPLICAS=0
ORIGINAL_B_REPLICAS=0

B_CHANGED=false
A_CHANGED=false
ONPREM_CHANGED=false


terraform_init() {
  local stack_path="$1"

  # state 삭제나 backend 재설정은 하지 않는다.
  terraform \
    -chdir="$stack_path" \
    init \
    -input=false
}

terraform_apply() {
  local stack_path="$1"

  terraform \
    -chdir="$stack_path" \
    apply \
    -auto-approve \
    -input=false
}

apply_stack() {
  local stack_name="$1"
  local stack_path="${DR_BASE_DIR}/${stack_name}"

  if [[ ! -d "$stack_path" ]]; then
    log ERROR \
      "Terraform stack 디렉터리가 없습니다: ${stack_path}"

    return 1
  fi

  run_step \
    "terraform_init_${stack_name}" \
    "$stack_name" \
    terraform_init "$stack_path"

  run_step \
    "terraform_apply_${stack_name}" \
    "$stack_name" \
    terraform_apply "$stack_path"
}

resolve_cluster_name() {
  local eks_path="${DR_BASE_DIR}/${DR_EKS_STACK}"
  local output_name

  if [[ -n "$DR_CLUSTER_NAME" ]]; then
    printf '%s\n' "$DR_CLUSTER_NAME"
    return 0
  fi

  for output_name in \
    cluster_name \
    eks_cluster_name \
    name
  do
    if terraform \
      -chdir="$eks_path" \
      output \
      -raw "$output_name" \
      >/dev/null 2>&1; then

      terraform \
        -chdir="$eks_path" \
        output \
        -raw "$output_name"

      return 0
    fi
  done

  log ERROR \
    "Terraform output에서 EKS-B cluster name을 찾지 못했습니다."

  log ERROR \
    "DR_CLUSTER_NAME 환경변수를 직접 지정하세요."

  return 1
}

update_dr_kubeconfig() {
  local cluster_name="$1"

  aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$cluster_name" \
    --alias "$CTX_B"
}


fail_without_traffic_change() {
  local exit_code="${1:-1}"
  local message="${2:-DR 프로비저닝 실패}"

  finish_script \
    "FAILED" \
    "$message"

  exit "$exit_code"
}


rollback_traffic() {
  local exit_code="${1:-1}"

  log WARN \
    "EKS-B 최종 트래픽 전환 실패. 기존 replica 복구 시작"

  # 기존 경로부터 복구
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

  if [[ "$B_CHANGED" == true ]]; then
    scale_cloudflared \
      "$CTX_B" \
      "$ORIGINAL_B_REPLICAS" \
      || true
  fi

  finish_script \
    "FAILED" \
    "EKS-B 최종 트래픽 전환 실패 및 replica 롤백"

  exit "$exit_code"
}

activate_eks_b_applications() {
  local deployments=(
    gateway-service
    auth-service
    weather-service
    traffic-service
    tourist-service
  )

  local deployment

  for deployment in "${deployments[@]}"; do
    if ! kubectl \
      --context "$CTX_B" \
      -n "$APP_NAMESPACE" \
      get deployment "$deployment" \
      >/dev/null 2>&1; then

      log ERROR \
        "EKS-B Deployment를 찾을 수 없습니다: ${APP_NAMESPACE}/${deployment}"

      return 1
    fi

    log INFO \
      "EKS-B 애플리케이션 활성화 deployment=${deployment} replicas=1"

    kubectl \
      --context "$CTX_B" \
      -n "$APP_NAMESPACE" \
      scale deployment "$deployment" \
      --replicas=1
  done
}

main() {
  local cluster_name

  log INFO \
    "EKS-B JIT 프로비저닝 시작"

  log INFO \
    "Terraform state 파일은 삭제하거나 초기화하지 않음"

  log INFO \
    "DR base directory=${DR_BASE_DIR}"

  require_command terraform
  require_command aws
  require_command kubectl
  require_command curl

  # 온프레미스 Argo CD에 접근할 수 있어야 한다.
  run_step \
    "check_onprem_context" \
    "$CTX_ONPREM" \
    check_context "$CTX_ONPREM" \
    || fail_without_traffic_change $? \
      "온프레미스 context 확인 실패"

  run_step \
    "check_onprem_cluster" \
    "$CTX_ONPREM" \
    check_cluster "$CTX_ONPREM" \
    || fail_without_traffic_change $? \
      "온프레미스 클러스터 연결 실패"

  # -------------------------------------------------------
  # 1. EKS-B 클러스터 프로비저닝
  # -------------------------------------------------------

  apply_stack "$DR_EKS_STACK" \
    || fail_without_traffic_change $? \
      "02-eks Terraform apply 실패"

  cluster_name="$(
    resolve_cluster_name
  )" || fail_without_traffic_change $? \
    "EKS-B cluster name 확인 실패"

  log INFO \
    "EKS-B cluster_name=${cluster_name}"

  # -------------------------------------------------------
  # 2. kubeconfig/context 생성
  #
  # 03, 04, 05 Terraform provider가 kubeconfig context를
  # 사용하는 경우를 대비해 platform보다 먼저 실행한다.
  # -------------------------------------------------------

  run_step \
    "update_kubeconfig" \
    "$CTX_B" \
    update_dr_kubeconfig "$cluster_name" \
    || fail_without_traffic_change $? \
      "EKS-B kubeconfig 생성 실패"

  run_step \
    "check_eks_b_context" \
    "$CTX_B" \
    check_context "$CTX_B" \
    || fail_without_traffic_change $? \
      "EKS-B context 확인 실패"

  run_step \
    "check_eks_b_cluster" \
    "$CTX_B" \
    check_cluster "$CTX_B" \
    || fail_without_traffic_change $? \
      "EKS-B API 연결 실패"

  run_step \
    "wait_eks_b_nodes" \
    "$CTX_B" \
    wait_for_nodes "$CTX_B" \
    || fail_without_traffic_change $? \
      "EKS-B Node Ready 실패"

  # -------------------------------------------------------
  # 3. Platform
  # -------------------------------------------------------

  apply_stack "$DR_PLATFORM_STACK" \
    || fail_without_traffic_change $? \
      "03-platform Terraform apply 실패"

  # -------------------------------------------------------
  # 4. Workloads 기반 리소스
  #
  # 온프레미스 Argo CD의 cluster secret 등이 여기에 있거나
  # platform에 있더라도 apply는 멱등적으로 동작한다.
  # -------------------------------------------------------

  apply_stack "$DR_WORKLOAD_STACK" \
    || fail_without_traffic_change $? \
      "04-eks-workloads Terraform apply 실패"

  # -------------------------------------------------------
  # 5. Autoscaling
  # -------------------------------------------------------

  apply_stack "$DR_AUTOSCALING_STACK" \
    || fail_without_traffic_change $? \
      "05-eks-autoscaling Terraform apply 실패"

  # -------------------------------------------------------
  # 6. 온프레미스 Argo CD Cluster Secret 확인
  #
  # Terraform:
  # kubernetes_secret.eks_b_cluster_secret
  # -------------------------------------------------------

  run_step \
    "wait_argocd_cluster_secret" \
    "onprem-argocd" \
    wait_for_argocd_cluster_secret "$CTX_ONPREM" \
    || fail_without_traffic_change $? \
      "EKS-B Argo CD Cluster Secret 확인 실패"

  capture_argocd_state \
    "$CTX_ONPREM" \
    "before-applicationset-apply"

  # -------------------------------------------------------
  # 7. ApplicationSet 재적용
  #
  # 이미 존재하면 configured 또는 unchanged가 나오며
  # state에는 영향을 주지 않는다.
  # -------------------------------------------------------

  run_step \
    "apply_applicationsets" \
    "onprem-argocd" \
    apply_applicationsets "$CTX_ONPREM" \
    || fail_without_traffic_change $? \
      "ApplicationSet 적용 실패"

  capture_argocd_state \
    "$CTX_ONPREM" \
    "after-applicationset-apply"

  # -------------------------------------------------------
  # 8. GitOps 배포 완료 대기
  # -------------------------------------------------------

  run_step \
    "wait_eks_b_gitops_applications" \
    "eks-b" \
    wait_for_eks_b_applications "$CTX_ONPREM" \
    || fail_without_traffic_change $? \
      "EKS-B GitOps Application 배포 실패"

  # EKS-B GitOps values는 Cold Standby를 위해 replicas=0이다.
  # DR 전환 시 실제 서비스 Deployment를 1개씩 활성화한다.
  run_step \
    "activate_eks_b_applications" \
    "$CTX_B" \
    activate_eks_b_applications \
    || fail_without_traffic_change $? \
      "EKS-B 애플리케이션 replica 활성화 실패"
  

  # -------------------------------------------------------
  # 9. 실제 서비스 Pod 및 내부 health 확인
  # -------------------------------------------------------

  run_step \
    "wait_eks_b_app_pods" \
    "$CTX_B" \
    wait_for_app_pods "$CTX_B" \
    || fail_without_traffic_change $? \
      "EKS-B 애플리케이션 Pod Ready 실패"

  run_step \
    "eks_b_internal_health" \
    "$CTX_B" \
    check_internal_health "$CTX_B" \
    || fail_without_traffic_change $? \
      "EKS-B 내부 health check 실패"

  capture_cluster_state \
    "$CTX_B" \
    "before-eks-b-traffic-switch"

  # -------------------------------------------------------
  # 10. 현재 replica 기록
  # -------------------------------------------------------

  ORIGINAL_B_REPLICAS="$(
    get_cloudflared_replicas "$CTX_B"
  )"

  if context_is_available "$CTX_ONPREM"; then
    ORIGINAL_ONPREM_REPLICAS="$(
      get_cloudflared_replicas "$CTX_ONPREM"
    )"
  fi

  if context_is_available "$CTX_A"; then
    ORIGINAL_A_REPLICAS="$(
      get_cloudflared_replicas "$CTX_A"
    )"
  fi

  log INFO \
    "전환 전 replica eks-a=${ORIGINAL_A_REPLICAS} onprem=${ORIGINAL_ONPREM_REPLICAS} eks-b=${ORIGINAL_B_REPLICAS}"

  # -------------------------------------------------------
  # 11. EKS-B cloudflared 활성화
  # -------------------------------------------------------

  run_step \
    "activate_cloudflared" \
    "eks-b" \
    scale_cloudflared "$CTX_B" 1 \
    || rollback_traffic $?

  B_CHANGED=true

  log INFO \
    "make-before-break: EKS-B connector 활성화 완료"

  # -------------------------------------------------------
  # 12. 기존 connector 정리
  #
  # 01이 성공했으면 onprem=1, eks-a=0
  # 01이 실패했더라도 최종 상태를 맞추기 위해 둘 다 0 처리
  # -------------------------------------------------------

  if context_is_available "$CTX_ONPREM"; then
    run_step \
      "deactivate_cloudflared" \
      "onprem" \
      scale_cloudflared "$CTX_ONPREM" 0 \
      || rollback_traffic $?

    ONPREM_CHANGED=true
  fi

  if context_is_available "$CTX_A"; then
    run_step \
      "deactivate_cloudflared" \
      "eks-a" \
      scale_cloudflared "$CTX_A" 0 \
      || rollback_traffic $?

    A_CHANGED=true
  else
    log WARN \
      "EKS-A API 접근 불가. replica 축소 생략"
  fi

  # -------------------------------------------------------
  # 13. 외부 health 확인
  # -------------------------------------------------------

  run_step \
    "external_health_after_dr_switch" \
    "eks-b" \
    check_external_health \
    || rollback_traffic $?

  capture_cluster_state \
    "$CTX_B" \
    "after-eks-b-traffic-switch"

  capture_argocd_state \
    "$CTX_ONPREM" \
    "final-gitops-state"

  log INFO \
    "EKS-B 프로비저닝 및 최종 트래픽 전환 완료"

  finish_script \
    "SUCCESS" \
    "Terraform 02~05 및 GitOps 배포 후 EKS-B 전환 완료"
}


main "$@"