# 과제 7 회계 감사 — 외부 의존성

## 1. ERP 회계 DB (필수)

```
□ Read-Only 계정 발급
□ 접근 허용 테이블:
  - ACC_EXPENSE (지출)
  - ACC_EXPENSE_DETAIL
  - ACC_APPROVAL_LINE
  - ACC_BUDGET
  - SYS_EMPLOYEE (인사 마스터)
□ 감사 DB 별도 (ERP와 분리 시)
```

## 2. 데이터 요건

| 데이터 | 필요 기간 | 건수 (예상) |
|--------|:-------:|:---------:|
| 지출 결의 | 최근 12개월 | 5,000~50,000건 |
| 결재 이력 | 최근 12개월 | 10,000~100,000건 |
| 예산 집행 | 최근 12개월 | 1,000~10,000건 |
| 과거 감사 적발 사례 | 최근 3년 | 10~100건 (학습용) |

## 3. 개인정보 마스킹

```python
# 감사 담당자는 실명, 그 외는 마스킹
MASKING_POLICY = {
    "auditor_role": "FULL",            # 전체 조회
    "department_head": "PARTIAL",      # 자기 부서만 실명
    "others": "ANONYMOUS",             # 사번만
}
```

## 4. 탐지 임계값 (D7-03 고객 결정)

```
중복 청구 탐지 기간: 30일 (고객 확정)
분할 지출 감지 기간: 7일
분할 지출 합계 기준: 50만원 (기관 결재 한도에 따름)
Z-Score 임계값: 2.5 (보수적)
Isolation Forest 이상치 비율: 5%
```

## 5. 재사용 자산

| 자산 | 재사용 방식 |
|------|---------|
| alli-audit 패키지 | audit.entity 확장 (category='audit_anomaly') |
| admin-web activities/audits 페이지 | 탐지 목록 표시 |
| admin-web dashboard | KPI 카드 추가 |
| sql-runner | ERP DB 쿼리 실행 |
| ai-assistant generate_node | 이상 패턴 자연어 설명 |
