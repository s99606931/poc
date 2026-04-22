# erp-mcp 도구 (과제 1)

## `get_expense_info` — 지출 정보 조회 (기안 작성용)

### 스펙

```python
@mcp.tool
async def get_expense_info(
    emp_cd: str,
    doc_type: str,              # TRIP | PURCHASE | OVERTIME
    amount: int = None,         # 예상 금액 (예산 검증)
    ref_period: str = None,     # YYYYMM (예산 기준 월)
) -> ExpenseInfoResponse:
    """ERP 지출 이력 + 예산 잔액 + 지출 한도 조회"""
```

### 응답 샘플 (출장비 시나리오)

```json
{
  "emp_cd": "EMP20240315",
  "doc_type": "TRIP",
  "requested_amount": 285000,

  "budget_info": {
    "budget_account_cd": "BA-2026-ACC-TRIP-001",
    "budget_account_nm": "2026년 회계부 출장비",
    "total_allocated": 12000000,
    "used_amount": 4500000,
    "balance": 7500000,
    "balance_ratio": 0.625,
    "source_view": "V_ALLI_BDG_BALANCE"
  },

  "expense_limit": {
    "per_trip_limit": 500000,
    "monthly_limit": 1500000,
    "current_month_used": 120000,
    "current_month_remaining": 1380000,
    "is_within_limit": true,
    "source_view": "V_ALLI_ACC_EXPENSE_LIMIT"
  },

  "past_expenses": [
    {
      "exp_id": "EXP-20260315-042",
      "date": "2026-03-15",
      "title": "대전 출장비",
      "amount": 185000,
      "destination": "대전",
      "duration_days": 2,
      "status": "APPROVED"
    },
    {
      "exp_id": "EXP-20260205-017",
      "date": "2026-02-05",
      "title": "서울 출장비",
      "amount": 125000,
      "destination": "서울",
      "duration_days": 1,
      "status": "APPROVED"
    }
  ],

  "required_docs": [
    {"type": "RECEIPT", "required": true, "note": "출장비 영수증 필수 (숙박/교통)"},
    {"type": "TRIP_REPORT", "required": true, "note": "출장 보고서 (5일 이내 제출)"},
    {"type": "ITINERARY", "required": false, "note": "출장 일정표 (권장)"}
  ],

  "warnings": [],
  "recommendations": [
    "과거 부산 출장 실적 없음 — 지출 근거 명확히 기재 권장",
    "예산 잔액 625만원 충분"
  ]
}
```

### 쿼리 대상 뷰

- `V_ALLI_BDG_BALANCE`: 예산 잔액
- `V_ALLI_ACC_EXPENSE_LIMIT`: 지출 한도 (규정 기반)
- `V_ALLI_ACC_EXPENSE_HIST`: 과거 지출 이력

---

## 관련 문서

- [db-schemas.sql](db-schemas.sql)
- [groupware-mcp-tools.md](groupware-mcp-tools.md)
