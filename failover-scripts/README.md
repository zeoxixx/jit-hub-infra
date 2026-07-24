# Scripts

DR(Failover) 자동화를 위한 스크립트입니다.

```
scripts/
├── logs/
├── 00-failover-common.sh
├── 01-switch-to-onprem.sh
├── 02-provision-dr.sh
├── 03-restore-primary.sh
├── approve-dr.sh
└── README.md
```

---

## approve-dr.sh

DR(Failover) 프로세스를 실행하는 메인 스크립트입니다.

### 주요 기능

- 장애 복구 승인 여부 확인
- On-Prem Failover 수행
- DR(EKS-B) 구축 실행
- 전체 실행 결과 출력

---

## 00-failover-common.sh

모든 Failover 스크립트에서 사용하는 공통 라이브러리입니다.

### 주요 기능

- 공통 환경변수 정의
- Context 관리
- Logging
- Health Check
- Rollout 상태 확인
- Argo CD Application 상태 확인
- 공통 유틸리티 함수 제공

---

## 01-switch-to-onprem.sh

Primary(EKS-A) 장애 발생 시 On-Premise 환경으로 서비스를 전환합니다.

### 주요 기능

- EKS-A Cloudflared 비활성화
- On-Prem Cloudflared 활성화
- 내부/외부 Health Check
- Failover 결과 기록

---

## 02-provision-dr.sh

DR Region(EKS-B)을 생성하고 애플리케이션을 배포합니다.

### 주요 기능

- Terraform 기반 DR 인프라 생성
- Argo CD ApplicationSet 적용
- GitOps 동기화 확인
- 애플리케이션 배포 확인
- Health Check 수행
- Cloudflared 활성화

---

## 03-restore-primary.sh

Primary(EKS-A) 복구 후 서비스를 다시 Primary 환경으로 전환합니다.

### 주요 기능

- Primary 서비스 상태 확인
- EKS-A Cloudflared 활성화
- On-Prem Cloudflared 비활성화
- 서비스 정상 여부 검증
- 복구 결과 기록

---

## logs/

Failover 및 DR 실행 로그가 저장되는 디렉터리입니다.

실행 시간, 단계별 수행 결과, 오류 로그 등을 기록하여 장애 분석 및 복구 이력을 관리합니다.