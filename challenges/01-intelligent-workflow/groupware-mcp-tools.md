# groupware-mcp 도구 (과제 1)

## 1. `get_approval_route` — 결재선 조회/추천

```python
@mcp.tool
async def get_approval_route(
    emp_cd: str,
    doc_type: str,              # TRIP | PURCHASE | OVERTIME
    amount: int = None,
    dept_cd: str = None,
) -> ApprovalRouteResponse:
    """결재선 규칙 + 과거 패턴 분석으로 결재 경로 추천"""
```

### 응답 샘플

```json
{
  "doc_type": "TRIP",
  "amount": 285000,
  "emp_cd": "EMP20240315",
  "recommended_route": [
    {"step": 1, "role": "팀장", "approver_emp_cd": "EMP20200205", "approver_nm": "김준수", "position": "과장", "dept_nm": "회계부", "limit_max": 500000},
    {"step": 2, "role": "부서장", "approver_emp_cd": "EMP20150301", "approver_nm": "박민수", "position": "부장", "dept_nm": "회계부", "limit_max": 1000000},
    {"step": 3, "role": "전결", "approver_emp_cd": "EMP20100101", "approver_nm": "정현훈", "position": "국장", "dept_nm": "재무과", "limit_max": null}
  ],
  "rule_applied": "TRIP_RULE_2026_V3 (금액 100,000원 초과 → 3단계 결재)",
  "alternative_routes": [
    {"note": "전결 위임 가능 시 국장 → 부장 전결", "route": [...]}
  ],
  "past_pattern": {
    "most_common_route_last_12m": [...],
    "match_rate": 0.92
  }
}
```

---

## 2. `get_doc_template` — 양식 조회

```python
@mcp.tool
async def get_doc_template(doc_type: str) -> DocTemplateResponse:
    """그룹웨어 공식 양식 조회"""
```

### 응답 샘플

```json
{
  "doc_type": "TRIP",
  "template_id": "TPL-TRIP-V3",
  "template_version": "3.0",
  "effective_from": "2026-01-01",
  "fields": [
    {"name": "title", "label": "제목", "required": true, "max_length": 100},
    {"name": "trip_destination", "label": "출장지", "required": true},
    {"name": "trip_period_start", "label": "출장 시작일", "required": true, "type": "DATE"},
    {"name": "trip_period_end", "label": "출장 종료일", "required": true, "type": "DATE"},
    {"name": "trip_purpose", "label": "출장 목적", "required": true, "max_length": 500},
    {"name": "amount", "label": "금액", "required": true, "type": "NUMBER"},
    {"name": "budget_account_cd", "label": "예산 계정", "required": true},
    {"name": "transport_type", "label": "교통수단", "required": false, "options": ["KTX", "고속버스", "자차", "항공"]},
    {"name": "accommodation", "label": "숙박", "required": false}
  ],
  "legal_basis": [
    "공무원 여비 규정 제5조 (출장비 지급 기준)",
    "기관 지출 규정 제12조"
  ],
  "template_url": "http://gw.agency.go.kr/template/TPL-TRIP-V3"
}
```

---

## 3. `create_approval_draft` — 기안 초안 등록

```python
@mcp.tool
async def create_approval_draft(
    requester_emp_cd: str,
    doc_type: str,
    template_id: str,
    fields: dict,               # template.fields에 대응하는 값
    approval_route: list,       # step/approver_emp_cd 리스트
    attachments: list = None,
    save_mode: str = "DRAFT",   # DRAFT | SUBMIT
) -> CreateDraftResponse:
    """그룹웨어에 기안 초안 저장 (또는 직접 제출)"""
```

### 응답 샘플

```json
{
  "approval_id": "GW-APR-20260421-102",
  "status": "DRAFT",
  "requester_emp_cd": "EMP20240315",
  "doc_type": "TRIP",
  "title": "부산 출장비 청구 (2026-04-15 ~ 04-17)",
  "amount": 285000,
  "approval_route": [
    {"step": 1, "approver_emp_cd": "EMP20200205", "status": "PENDING"},
    {"step": 2, "approver_emp_cd": "EMP20150301", "status": "PENDING"},
    {"step": 3, "approver_emp_cd": "EMP20100101", "status": "PENDING"}
  ],
  "created_at": "2026-04-21T10:15:23+09:00",
  "gw_url": "http://gw.agency.go.kr/approval/GW-APR-20260421-102",
  "edit_url": "http://gw.agency.go.kr/approval/GW-APR-20260421-102/edit",
  "message": "초안이 저장되었습니다. 담당자가 확인 후 상신하세요."
}
```

---

## 4. `get_approval_list` / `get_approval_detail` — 기존

개인비서(과제 3)와 동일 — [../03-personal-assistant/groupware-mcp-tools.md](../03-personal-assistant/groupware-mcp-tools.md) 참조
