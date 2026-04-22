# 03 개인비서 — 외부 시스템 의존성 명세

> **작성일**: 2026-04-21
> **목적**: 구현 전 확보해야 할 외부 시스템 접근 권한·스펙·담당자 정리

---

## 1. ERP 시스템 의존

### 1.1 접근 요건

| 항목 | 내용 | 담당 |
|------|------|------|
| **DB 종류** | MariaDB / Oracle / Tibero / MSSQL 중 1개 (고객 확정) | ERP 벤더 |
| **접근 방식** | sql-runner Read-Only 계정 | DBA |
| **인증** | DB 계정 (JWT ES256은 erp-mcp 자체 검증) | ERP 운영팀 |
| **네트워크** | 내부망 직접 접근 or VPN | 정보시스템팀 |

### 1.2 필요 테이블/뷰

아래 뷰들이 존재하지 않으면 **Phase 1 전에 생성 협의** 필수.

| 뷰/테이블 | 용도 | 샘플 위치 |
|---------|------|---------|
| `V_ALLI_HCM_DEADLINE` | 인사 마감 업무 (정기평가/출장정산 등) | [db-schemas.sql](db-schemas.sql) |
| `V_ALLI_ACC_CLOSING` | 회계 마감 업무 (월결산 등) | [db-schemas.sql](db-schemas.sql) |
| `V_ALLI_BDG_SUBMIT` | 예산 제출 마감 (예산요구/정산) | [db-schemas.sql](db-schemas.sql) |
| `V_ALLI_ACC_PENDING_EXPENSE` | 미결재 지출 결의서 | [db-schemas.sql](db-schemas.sql) |
| `V_ALLI_HCM_PENDING_LEAVE` | 미결재 휴가 신청 | [db-schemas.sql](db-schemas.sql) |
| `HRI_HR_MST` | 인사 마스터 (EMP_CD 기준) | 기존 ERP 테이블 |
| `SYS_DEPT` | 부서 마스터 | 기존 ERP 테이블 |

### 1.3 고객 제공 필요 자료

```
□ ERP DB 접속 정보 (.env 환경변수 형태):
  ERP_DB_HOST=192.168.x.x
  ERP_DB_PORT=3306
  ERP_DB_USER=alli_readonly
  ERP_DB_PASSWORD=<password>
  ERP_DB_NAME=erp_prod

□ 기존 뷰 존재 여부 확인 (10분 작업):
  SELECT COUNT(*) FROM information_schema.views
  WHERE table_name LIKE 'V_ALLI_%';

□ 위 5개 뷰 중 미존재분 생성 승인 + DDL 실행 (1~2일 작업, DBA 요청)

□ 샘플 데이터 제공 동의 (개발용):
  - HCM 마감 업무 50건
  - ACC 미결재 지출 30건
  - HCM 휴가 신청 20건
```

---

## 2. 그룹웨어 시스템 의존

> 🔴 **P0-1 결정**: [그룹웨어 Write 권한 확보](../decisions.md#-d2-06-미확정-시-영향--과제-2-전체-불가-사유)
> 본 과제(03)는 **Read-Only 로 충분** — Write는 과제 2(ERP 동기화)에만 필요

### 2.1 접근 요건

| 항목 | 내용 | 담당 |
|------|------|------|
| **그룹웨어 벤더** | 두레이 / 한컴 / 영림원 / 네이버웍스 / 기타 | 고객 확정 필요 |
| **접근 방식 A** | REST API (권장) | 그룹웨어 담당자 |
| **접근 방식 B** | DB Direct (백업) | 그룹웨어 DBA |
| **인증** | API Key / OAuth 2.0 / Basic Auth | 그룹웨어 벤더 |
| **읽기 범위** | 일정, 결재 대기 목록 | 본인 데이터만 |

### 2.2 필요 API/테이블

**REST API 모드** (벤더 확인 필요):
| Endpoint | 기능 | 대안 |
|---------|------|------|
| `GET /api/schedule?emp_cd=&from=&to=` | 개인 일정 조회 | DB Direct |
| `GET /api/approval/pending?emp_cd=` | 결재 대기 목록 | DB Direct |
| `GET /api/employee/{emp_cd}` | 사원 정보 (선택) | ERP HRI_HR_MST |

**DB Direct 모드** (대체):
| 테이블 | 용도 |
|--------|------|
| `GW_SCHEDULE` | 일정 마스터 |
| `GW_SCHEDULE_ATTENDEE` | 참석자 매핑 |
| `GW_APPROVAL` | 결재 문서 마스터 |
| `GW_APPROVAL_LINE` | 결재선 + 상태 |

### 2.3 고객 제공 필요 자료

```
□ 그룹웨어 벤더 및 버전 확인
□ API 스펙 문서 (Swagger/Postman Collection) — 있을 경우
□ 테스트 API Key 또는 DB Read 계정 발급
□ 샘플 데이터:
  - 일정 20건 (오늘 ~ 향후 7일)
  - 결재 대기 10건
□ 연동 담당자 지정 (벤더 엔지니어 또는 내부 담당자)

□ 대안 (API/DB 모두 미제공 시):
  - Mock 데이터로 PoC 개발
  - 실 연동은 본 사업 전환 시
```

---

## 3. AI 모델 의존 (기존 인프라)

| 구성요소 | 호출 | 의존 |
|---------|------|------|
| **vllm-vision (:6012)** | Gemma-4 31B AWQ TP=4 | 20_alli-llm 운영 중 ✅ |
| **ai-llm (:6001)** | BGE-M3 임베딩 (fallback) | 20_alli-llm 운영 중 ✅ |
| **ai-assistant (:4005)** | 17개 노드 재사용 | 10_alli-work 운영 중 ✅ |

추가 리소스 필요 없음.

---

## 4. 사전 협의 우선순위표

| 우선순위 | 항목 | 기한 |
|:------:|------|:---:|
| 🔴 P0 | ERP Read-Only 계정 발급 | Phase 0 (W-2) |
| 🔴 P0 | V_ALLI_* 5개 뷰 존재 확인 + 미존재 시 생성 | Phase 0 (W-1) |
| 🔴 P0 | 그룹웨어 API/DB 접근 방식 결정 | Phase 0 (W-1) |
| 🟡 P1 | 그룹웨어 API 샘플 수신 | Phase 1 (W1) |
| 🟡 P1 | 개인정보 마스킹 정책 확정 | Phase 1 (W1) |
| 🟢 P2 | Mock 모드 대체 시나리오 준비 | 상시 |

---

## 5. 리스크 & 대응

| 리스크 | 영향 | 대응 |
|--------|:---:|------|
| ERP 뷰 미존재 | 탐지 불가 | DBA에 DDL 요청 (2일) + 생성 전까지 Mock |
| 그룹웨어 API 미공개 | 일정 조회 불가 | DB Direct 전환 or Mock 데이터 |
| 개인정보 마스킹 기준 미확정 | 법적 리스크 | 최소 정보만 표시 (본인 데이터만) |
| ERP-그룹웨어 사원코드 불일치 | 조회 실패 | 사원코드 매핑 테이블 생성 |
| LLM 우선순위 판단 오류 | UX 품질 저하 | 규칙 기반 + LLM 혼합 |

---

## 6. 관련 문서

- [db-schemas.sql](db-schemas.sql) — 필요 뷰 DDL
- [erp-mcp-tools.md](erp-mcp-tools.md) — ERP MCP 도구 명세
- [groupware-mcp-tools.md](groupware-mcp-tools.md) — 그룹웨어 MCP 도구 명세
- [../../customer/checklist.md](../../customer/checklist.md) — B1~B8 외부 시스템 체크리스트
