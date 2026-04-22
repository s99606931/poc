# erp-mcp 도구 명세 (과제 3 개인비서)

> **대상**: `apps/erp-mcp/src/tools/`
> **등록 위치**: `apps/erp-mcp/src/mcp/server.py`
> **인증**: JWT ES256 (emp_cd, dept_cd, tenant_id 클레임)

---

## 1. 도구 목록

| # | 도구명 | 용도 | 신규/기존 | 예상 공수 |
|:-:|--------|------|:-------:|:------:|
| 1 | `get_deadline_tasks` | 마감 임박 업무 조회 | **신규** | 0.5일 |
| 2 | `get_pending_items` | 미결재 알림 조회 | **신규** | 0.5일 |
| 3 | `get_monthly_schedule` | 월간 마감 일정 | 신규 (선택) | 0.5일 |

---

## 2. `get_deadline_tasks`

### 2.1 스펙

```python
@mcp.tool
async def get_deadline_tasks(
    emp_cd: str,                    # 사원 코드 (JWT에서 자동 주입 가능)
    date: str = None,               # 기준일 (YYYY-MM-DD, 기본: 오늘)
    horizon_days: int = 7,          # 조회 범위 (기본 7일)
    categories: list[str] = None,   # HCM | ACC | BDG | ALL (기본: ALL)
) -> DeadlineTasksResponse:
    """개인별 마감 임박 업무 조회 (HCM/ACC/BDG 통합)"""
```

### 2.2 응답 스키마

```typescript
interface DeadlineTasksResponse {
  emp_cd: string;
  query_date: string;               // 기준일
  horizon_days: number;
  total_count: number;
  tasks: DeadlineTask[];
  summary: {
    d0_count: number;               // 오늘 마감
    d1_count: number;               // 내일 마감
    d3_count: number;               // 3일 이내
    d7_count: number;               // 7일 이내
  };
}

interface DeadlineTask {
  task_id: string;                  // 고유 ID (e.g. "HCM-EVAL-20260421-001")
  category: "HCM" | "ACC" | "BDG";  // 인사/회계/예산
  subcategory: string;              // e.g. "정기평가", "월결산"
  title: string;                    // "2026년 상반기 정기평가 제출"
  description: string;              // 상세
  deadline: string;                 // ISO 8601: "2026-04-30T18:00:00+09:00"
  days_remaining: number;           // 남은 일수 (0=오늘)
  importance: "HIGH" | "MEDIUM" | "LOW";
  urgency: "D0" | "D1" | "D3" | "D7";
  source_view: string;              // "V_ALLI_HCM_DEADLINE"
  related_url: string | null;       // ERP 페이지 링크
  department_cd: string;            // 담당 부서 코드
  submitted: boolean;               // 이미 제출 여부
}
```

### 2.3 구현 예시

```python
# apps/erp-mcp/src/tools/get_deadline_tasks.py

from datetime import datetime, timedelta
from src.clients.sql_runner_client import SQLRunnerClient
from src.mcp.schemas import DeadlineTasksResponse

async def get_deadline_tasks(
    emp_cd: str,
    date: str = None,
    horizon_days: int = 7,
    categories: list[str] = None,
) -> DeadlineTasksResponse:
    if date is None:
        date = datetime.now().strftime("%Y-%m-%d")
    if categories is None or "ALL" in categories:
        categories = ["HCM", "ACC", "BDG"]

    end_date = (datetime.strptime(date, "%Y-%m-%d") + timedelta(days=horizon_days)).strftime("%Y-%m-%d")

    sql = """
    SELECT task_id, category, subcategory, title, description,
           deadline, importance, department_cd, related_url, submitted
    FROM V_ALLI_HCM_DEADLINE
    WHERE emp_cd = :emp_cd
      AND deadline BETWEEN :date AND :end_date
      AND submitted = 'N'
    UNION ALL
    SELECT task_id, category, subcategory, title, description,
           deadline, importance, department_cd, related_url, submitted
    FROM V_ALLI_ACC_CLOSING
    WHERE responsible_emp_cd = :emp_cd
      AND deadline BETWEEN :date AND :end_date
      AND closed_yn = 'N'
    UNION ALL
    SELECT task_id, category, subcategory, title, description,
           deadline, importance, department_cd, related_url, submitted
    FROM V_ALLI_BDG_SUBMIT
    WHERE submitter_emp_cd = :emp_cd
      AND deadline BETWEEN :date AND :end_date
      AND submitted = 'N'
    ORDER BY deadline ASC
    """
    rows = await SQLRunnerClient.query(sql, {
        "emp_cd": emp_cd,
        "date": date,
        "end_date": end_date,
    })

    tasks = [
        DeadlineTask(
            **row,
            days_remaining=_calc_days(row["deadline"], date),
            urgency=_urgency_level(row["deadline"], date),
            source_view=_source_by_category(row["category"]),
        )
        for row in rows
    ]
    tasks = [t for t in tasks if t.category in categories]

    return DeadlineTasksResponse(
        emp_cd=emp_cd,
        query_date=date,
        horizon_days=horizon_days,
        total_count=len(tasks),
        tasks=tasks,
        summary=_summarize(tasks),
    )
```

### 2.4 응답 샘플

```json
{
  "emp_cd": "EMP20240315",
  "query_date": "2026-04-21",
  "horizon_days": 7,
  "total_count": 4,
  "tasks": [
    {
      "task_id": "ACC-CLOSE-202604-001",
      "category": "ACC",
      "subcategory": "월결산",
      "title": "2026년 4월 월결산 마감",
      "description": "회계 전표 입력 완료 및 월결산 확정 필요",
      "deadline": "2026-04-21T18:00:00+09:00",
      "days_remaining": 0,
      "importance": "HIGH",
      "urgency": "D0",
      "source_view": "V_ALLI_ACC_CLOSING",
      "related_url": "http://erp.agency.go.kr/acc/close/202604",
      "department_cd": "D010201",
      "submitted": false
    },
    {
      "task_id": "HCM-EVAL-2026H1-003",
      "category": "HCM",
      "subcategory": "정기평가",
      "title": "2026년 상반기 정기평가 피평가자 의견 제출",
      "description": "팀장 평가 확인 후 본인 의견 2주 이내 제출",
      "deadline": "2026-04-23T23:59:59+09:00",
      "days_remaining": 2,
      "importance": "MEDIUM",
      "urgency": "D3",
      "source_view": "V_ALLI_HCM_DEADLINE",
      "related_url": "http://erp.agency.go.kr/hcm/eval/2026h1",
      "department_cd": "D010201",
      "submitted": false
    },
    {
      "task_id": "BDG-REQ-202605-042",
      "category": "BDG",
      "subcategory": "예산요구서",
      "title": "2026년 5월 부서 예산요구서 제출",
      "description": "5월 집행 예정 예산 항목별 요구서 작성",
      "deadline": "2026-04-28T18:00:00+09:00",
      "days_remaining": 7,
      "importance": "MEDIUM",
      "urgency": "D7",
      "source_view": "V_ALLI_BDG_SUBMIT",
      "related_url": "http://erp.agency.go.kr/bdg/req/202605",
      "department_cd": "D010201",
      "submitted": false
    }
  ],
  "summary": {
    "d0_count": 1,
    "d1_count": 0,
    "d3_count": 1,
    "d7_count": 1
  }
}
```

---

## 3. `get_pending_items`

### 3.1 스펙

```python
@mcp.tool
async def get_pending_items(
    emp_cd: str,
    categories: list[str] = None,   # EXPENSE | LEAVE | OVERTIME | ALL
) -> PendingItemsResponse:
    """미결재 알림 조회 (본인 제출 건 중 상급자 결재 대기)"""
```

### 3.2 응답 스키마

```typescript
interface PendingItemsResponse {
  emp_cd: string;
  total_count: number;
  items: PendingItem[];
  summary: {
    expense_count: number;
    leave_count: number;
    overtime_count: number;
    long_waiting_count: number;     // 3일 이상 대기
  };
}

interface PendingItem {
  item_id: string;                  // e.g. "EXP-20260418-001"
  category: "EXPENSE" | "LEAVE" | "OVERTIME";
  title: string;                    // "출장비 청구 (서울 출장)"
  amount: number | null;            // 금액 (휴가 등은 null)
  submitted_at: string;             // ISO 8601
  waiting_days: number;             // 대기 일수
  current_approver: {
    emp_cd: string;
    emp_nm: string;                 // 마스킹됨 (본인만 전체)
    dept_nm: string;
    position: string;
  };
  next_approver: { ... } | null;    // 다음 결재자
  status: "PENDING" | "REVIEWING" | "HOLD";
  source_view: string;
  erp_url: string;
}
```

### 3.3 응답 샘플

```json
{
  "emp_cd": "EMP20240315",
  "total_count": 3,
  "items": [
    {
      "item_id": "EXP-20260418-001",
      "category": "EXPENSE",
      "title": "부산 출장비 청구 (2026-04-15 ~ 04-17)",
      "amount": 285000,
      "submitted_at": "2026-04-18T14:30:00+09:00",
      "waiting_days": 3,
      "current_approver": {
        "emp_cd": "EMP20200205",
        "emp_nm": "김*준",
        "dept_nm": "회계부",
        "position": "과장"
      },
      "next_approver": {
        "emp_cd": "EMP20150301",
        "emp_nm": "박*수",
        "dept_nm": "회계부",
        "position": "부장"
      },
      "status": "PENDING",
      "source_view": "V_ALLI_ACC_PENDING_EXPENSE",
      "erp_url": "http://erp.agency.go.kr/acc/expense/EXP-20260418-001"
    },
    {
      "item_id": "LV-20260419-007",
      "category": "LEAVE",
      "title": "연차 1일 신청 (2026-04-25)",
      "amount": null,
      "submitted_at": "2026-04-19T10:15:00+09:00",
      "waiting_days": 2,
      "current_approver": {
        "emp_cd": "EMP20200205",
        "emp_nm": "김*준",
        "dept_nm": "회계부",
        "position": "과장"
      },
      "next_approver": null,
      "status": "PENDING",
      "source_view": "V_ALLI_HCM_PENDING_LEAVE",
      "erp_url": "http://erp.agency.go.kr/hcm/leave/LV-20260419-007"
    }
  ],
  "summary": {
    "expense_count": 2,
    "leave_count": 1,
    "overtime_count": 0,
    "long_waiting_count": 1
  }
}
```

---

## 4. `get_monthly_schedule` (선택)

### 4.1 스펙

```python
@mcp.tool
async def get_monthly_schedule(
    emp_cd: str,
    year: int,
    month: int,
) -> MonthlyScheduleResponse:
    """ERP 월간 마감 일정 조회 (결산/보고서 등 정기 마감)"""
```

### 4.2 응답 샘플 (요약)

```json
{
  "emp_cd": "EMP20240315",
  "year": 2026,
  "month": 4,
  "events": [
    {"date": "2026-04-21", "event": "월결산 마감", "category": "ACC"},
    {"date": "2026-04-25", "event": "정기평가 피평가자 의견 제출 마감", "category": "HCM"},
    {"date": "2026-04-28", "event": "5월 예산요구서 제출", "category": "BDG"},
    {"date": "2026-04-30", "event": "월급여 집행", "category": "PAY"}
  ]
}
```

---

## 5. MCP 서버 등록

```python
# apps/erp-mcp/src/mcp/server.py

from src.tools.get_deadline_tasks import get_deadline_tasks
from src.tools.get_pending_items import get_pending_items
from src.tools.get_monthly_schedule import get_monthly_schedule

mcp.add_tool(get_deadline_tasks)
mcp.add_tool(get_pending_items)
mcp.add_tool(get_monthly_schedule)
```

---

## 6. 단위 테스트

```python
# apps/erp-mcp/tests/tools/test_get_deadline_tasks.py

import pytest
from src.tools.get_deadline_tasks import get_deadline_tasks

@pytest.mark.asyncio
async def test_get_deadline_tasks_normal():
    resp = await get_deadline_tasks(emp_cd="EMP20240315", horizon_days=7)
    assert resp.total_count >= 0
    assert all(0 <= t.days_remaining <= 7 for t in resp.tasks)

@pytest.mark.asyncio
async def test_get_deadline_tasks_empty():
    resp = await get_deadline_tasks(emp_cd="UNKNOWN", horizon_days=7)
    assert resp.total_count == 0
```

---

## 7. 관련 문서

- [db-schemas.sql](db-schemas.sql) — 쿼리 대상 뷰 DDL
- [api-samples.json](api-samples.json) — 전체 샘플 JSON 묶음
- [groupware-mcp-tools.md](groupware-mcp-tools.md) — 그룹웨어 쪽 스펙
- [../../services/improvements/erp-mcp.md](../../services/improvements/erp-mcp.md) — erp-mcp 확장 가이드
