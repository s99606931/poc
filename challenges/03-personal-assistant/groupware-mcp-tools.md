# groupware-mcp 도구 명세 (과제 3 개인비서)

> **대상**: `apps/groupware-mcp/src/tools/` (신규 서비스)
> **등록 위치**: `apps/groupware-mcp/src/mcp/server.py`
> **인증**: JWT ES256 (emp_cd, dept_cd, tenant_id 클레임)

---

## 1. 도구 목록

| # | 도구명 | 용도 | 예상 공수 |
|:-:|--------|------|:------:|
| 1 | `get_schedule` | 개인 일정 조회 | 0.5일 |
| 2 | `get_pending_approvals` | 결재 대기 목록 조회 | 0.5일 |
| 3 | `get_monthly_schedule` | 월간 일정 조회 | 선택 |

---

## 2. `get_schedule`

### 2.1 스펙

```python
@mcp.tool
async def get_schedule(
    emp_cd: str,                    # 사원 코드
    date_from: str = None,          # 시작일 (YYYY-MM-DD, 기본: 오늘)
    date_to: str = None,            # 종료일 (기본: date_from)
    include_colleagues: bool = False, # 팀 일정 포함 여부
) -> ScheduleResponse:
    """개인 일정 및 회의 조회 (그룹웨어 DB/API)"""
```

### 2.2 응답 스키마

```typescript
interface ScheduleResponse {
  emp_cd: string;
  date_from: string;
  date_to: string;
  total_count: number;
  schedules: Schedule[];
  summary: {
    meetings_count: number;
    business_trips_count: number;
    reports_deadline_count: number;
    all_day_count: number;
  };
}

interface Schedule {
  schedule_id: string;              // e.g. "GW-SCH-20260421-042"
  category: "MEETING" | "BUSINESS_TRIP" | "REPORT" | "PERSONAL" | "TRAINING";
  title: string;
  description: string | null;
  start_dt: string;                 // ISO 8601
  end_dt: string;                   // ISO 8601
  is_all_day: boolean;
  location: string | null;          // "본관 3층 회의실 A"
  online_url: string | null;        // Zoom/Teams URL
  organizer: {
    emp_cd: string;
    emp_nm: string;                 // 마스킹 규칙 적용
    dept_nm: string;
  };
  attendees: Attendee[];
  importance: "HIGH" | "MEDIUM" | "LOW";
  status: "CONFIRMED" | "TENTATIVE" | "CANCELLED";
  related_docs: string[];           // 첨부 문서 URL
  source: "REST_API" | "DB_DIRECT";
}

interface Attendee {
  emp_cd: string;
  emp_nm: string;                   // 마스킹됨
  dept_nm: string;
  position: string;
  rsvp_status: "ACCEPTED" | "TENTATIVE" | "DECLINED" | "PENDING";
}
```

### 2.3 구현 예시 (DB Direct 모드)

```python
# apps/groupware-mcp/src/tools/get_schedule.py

from datetime import datetime
from src.clients.groupware_client import GroupwareClient

async def get_schedule(
    emp_cd: str,
    date_from: str = None,
    date_to: str = None,
    include_colleagues: bool = False,
) -> ScheduleResponse:
    if date_from is None:
        date_from = datetime.now().strftime("%Y-%m-%d")
    if date_to is None:
        date_to = date_from

    # REST API 모드
    if GroupwareClient.mode == "REST":
        return await _fetch_via_rest(emp_cd, date_from, date_to)

    # DB Direct 모드
    sql = """
    SELECT s.schedule_id, s.category, s.title, s.description,
           s.start_dt, s.end_dt, s.is_all_day, s.location, s.online_url,
           s.organizer_emp_cd, s.importance, s.status
    FROM GW_SCHEDULE s
    INNER JOIN GW_SCHEDULE_ATTENDEE a ON s.schedule_id = a.schedule_id
    WHERE a.emp_cd = :emp_cd
      AND s.start_dt BETWEEN :date_from AND :date_to
      AND s.status != 'CANCELLED'
    ORDER BY s.start_dt ASC
    """
    rows = await GroupwareClient.query(sql, {
        "emp_cd": emp_cd,
        "date_from": f"{date_from}T00:00:00",
        "date_to": f"{date_to}T23:59:59",
    })

    schedules = []
    for row in rows:
        attendees = await _fetch_attendees(row["schedule_id"])
        organizer = await _fetch_employee(row["organizer_emp_cd"])
        schedules.append(Schedule(
            **row,
            organizer=organizer,
            attendees=attendees,
            related_docs=await _fetch_docs(row["schedule_id"]),
            source="DB_DIRECT",
        ))

    return ScheduleResponse(
        emp_cd=emp_cd,
        date_from=date_from,
        date_to=date_to,
        total_count=len(schedules),
        schedules=schedules,
        summary=_summarize(schedules),
    )
```

### 2.4 응답 샘플

```json
{
  "emp_cd": "EMP20240315",
  "date_from": "2026-04-21",
  "date_to": "2026-04-21",
  "total_count": 3,
  "schedules": [
    {
      "schedule_id": "GW-SCH-20260421-042",
      "category": "MEETING",
      "title": "회계부 주간 업무 회의",
      "description": "4월 월결산 진행 상황 공유 및 5월 예산 계획 논의",
      "start_dt": "2026-04-21T10:00:00+09:00",
      "end_dt": "2026-04-21T11:00:00+09:00",
      "is_all_day": false,
      "location": "본관 3층 회의실 A",
      "online_url": null,
      "organizer": {
        "emp_cd": "EMP20150301",
        "emp_nm": "박*수",
        "dept_nm": "회계부"
      },
      "attendees": [
        {"emp_cd": "EMP20240315", "emp_nm": "본인", "dept_nm": "회계부", "position": "주임", "rsvp_status": "ACCEPTED"},
        {"emp_cd": "EMP20200205", "emp_nm": "김*준", "dept_nm": "회계부", "position": "과장", "rsvp_status": "ACCEPTED"},
        {"emp_cd": "EMP20220611", "emp_nm": "이*영", "dept_nm": "회계부", "position": "대리", "rsvp_status": "TENTATIVE"}
      ],
      "importance": "HIGH",
      "status": "CONFIRMED",
      "related_docs": ["http://gw.agency.go.kr/doc/202604-weekly-report.pdf"],
      "source": "DB_DIRECT"
    },
    {
      "schedule_id": "GW-SCH-20260421-058",
      "category": "REPORT",
      "title": "월결산 보고서 제출 마감",
      "description": "2026-04 월결산 보고서 작성 후 회계부장 결재 필요",
      "start_dt": "2026-04-21T18:00:00+09:00",
      "end_dt": "2026-04-21T18:00:00+09:00",
      "is_all_day": false,
      "location": null,
      "online_url": null,
      "organizer": {"emp_cd": "SYSTEM", "emp_nm": "시스템", "dept_nm": "시스템"},
      "attendees": [
        {"emp_cd": "EMP20240315", "emp_nm": "본인", "dept_nm": "회계부", "position": "주임", "rsvp_status": "ACCEPTED"}
      ],
      "importance": "HIGH",
      "status": "CONFIRMED",
      "related_docs": [],
      "source": "DB_DIRECT"
    },
    {
      "schedule_id": "GW-SCH-20260421-073",
      "category": "TRAINING",
      "title": "행정정보시스템 AI 도입 설명회 (선택)",
      "description": "전 부서 대상 AI 활용 사례 공유",
      "start_dt": "2026-04-21T14:00:00+09:00",
      "end_dt": "2026-04-21T15:30:00+09:00",
      "is_all_day": false,
      "location": "대강당",
      "online_url": "https://zoom.us/j/123456789",
      "organizer": {"emp_cd": "EMP20100101", "emp_nm": "정*훈", "dept_nm": "정보시스템팀"},
      "attendees": [],
      "importance": "LOW",
      "status": "CONFIRMED",
      "related_docs": [],
      "source": "DB_DIRECT"
    }
  ],
  "summary": {
    "meetings_count": 1,
    "business_trips_count": 0,
    "reports_deadline_count": 1,
    "all_day_count": 0
  }
}
```

---

## 3. `get_pending_approvals`

### 3.1 스펙

```python
@mcp.tool
async def get_pending_approvals(
    emp_cd: str,                    # 결재자 사원 코드
    role: str = "APPROVER",         # APPROVER (결재해야 할 것) | REQUESTER (본인이 제출한 것)
) -> PendingApprovalsResponse:
    """결재 대기 목록 조회 (그룹웨어 결재 시스템)"""
```

### 3.2 응답 스키마

```typescript
interface PendingApprovalsResponse {
  emp_cd: string;
  role: "APPROVER" | "REQUESTER";
  total_count: number;
  approvals: PendingApproval[];
  summary: {
    urgent_count: number;           // 제출 3일 초과
    same_day_count: number;
    total_amount: number;           // 지출 관련 총액
  };
}

interface PendingApproval {
  approval_id: string;              // "GW-APR-20260419-187"
  doc_type: string;                 // "출장비 청구", "물품 구매"
  title: string;
  requester: {
    emp_cd: string;
    emp_nm: string;
    dept_nm: string;
  };
  submitted_at: string;             // ISO 8601
  waiting_hours: number;            // 대기 시간 (시간)
  amount: number | null;
  importance: "HIGH" | "MEDIUM" | "LOW";
  current_step: number;             // 현재 결재 단계
  total_steps: number;              // 전체 결재 단계 수
  approval_line: ApprovalStep[];    // 전체 결재선
  gw_url: string;                   // 그룹웨어 결재 페이지
  related_docs: string[];
}

interface ApprovalStep {
  step: number;                     // 1, 2, 3...
  approver_emp_cd: string;
  approver_nm: string;
  approver_position: string;
  status: "PENDING" | "APPROVED" | "REJECTED" | "DELEGATED";
  acted_at: string | null;
  comment: string | null;
}
```

### 3.3 응답 샘플

```json
{
  "emp_cd": "EMP20150301",
  "role": "APPROVER",
  "total_count": 4,
  "approvals": [
    {
      "approval_id": "GW-APR-20260418-187",
      "doc_type": "출장비 청구",
      "title": "부산 출장비 청구 (2026-04-15 ~ 04-17)",
      "requester": {
        "emp_cd": "EMP20240315",
        "emp_nm": "홍*동",
        "dept_nm": "회계부"
      },
      "submitted_at": "2026-04-18T14:30:00+09:00",
      "waiting_hours": 72,
      "amount": 285000,
      "importance": "MEDIUM",
      "current_step": 2,
      "total_steps": 3,
      "approval_line": [
        {"step": 1, "approver_emp_cd": "EMP20200205", "approver_nm": "김*준", "approver_position": "과장", "status": "APPROVED", "acted_at": "2026-04-19T09:00:00+09:00", "comment": "확인"},
        {"step": 2, "approver_emp_cd": "EMP20150301", "approver_nm": "본인", "approver_position": "부장", "status": "PENDING", "acted_at": null, "comment": null},
        {"step": 3, "approver_emp_cd": "EMP20100101", "approver_nm": "정*훈", "approver_position": "국장", "status": "PENDING", "acted_at": null, "comment": null}
      ],
      "gw_url": "http://gw.agency.go.kr/approval/GW-APR-20260418-187",
      "related_docs": ["http://gw.agency.go.kr/doc/20260418-expense-receipt.pdf"]
    }
  ],
  "summary": {
    "urgent_count": 1,
    "same_day_count": 0,
    "total_amount": 285000
  }
}
```

---

## 4. `get_monthly_schedule` (선택)

```python
@mcp.tool
async def get_monthly_schedule(
    emp_cd: str,
    year: int,
    month: int,
) -> MonthlyScheduleResponse:
    """월간 일정 요약 (캘린더 뷰용)"""
```

응답 예시 (요약):
```json
{
  "emp_cd": "EMP20240315",
  "year": 2026,
  "month": 4,
  "events_by_date": {
    "2026-04-21": [
      {"schedule_id": "GW-SCH-20260421-042", "title": "회계부 주간 업무 회의", "time": "10:00"},
      {"schedule_id": "GW-SCH-20260421-058", "title": "월결산 보고서 제출 마감", "time": "18:00"}
    ],
    "2026-04-22": [
      {"schedule_id": "GW-SCH-20260422-011", "title": "외부 감사 대응 회의", "time": "14:00"}
    ]
  }
}
```

---

## 5. 그룹웨어 클라이언트 추상화

### 5.1 인터페이스

```python
# apps/groupware-mcp/src/clients/groupware_client.py

from abc import ABC, abstractmethod
from enum import Enum

class GroupwareMode(Enum):
    REST = "REST_API"
    DB = "DB_DIRECT"
    MOCK = "MOCK"

class GroupwareClient(ABC):
    """그룹웨어 연동 어댑터 인터페이스"""

    @classmethod
    def create(cls, config):
        mode = GroupwareMode(config.GROUPWARE_MODE)
        if mode == GroupwareMode.REST:
            return GroupwareRestClient(config)
        elif mode == GroupwareMode.DB:
            return GroupwareDbClient(config)
        elif mode == GroupwareMode.MOCK:
            return GroupwareMockClient(config)

    @abstractmethod
    async def get_schedules(self, emp_cd, date_from, date_to): ...

    @abstractmethod
    async def get_pending_approvals(self, emp_cd, role): ...

    @abstractmethod
    async def get_employee(self, emp_cd): ...
```

### 5.2 벤더별 구현 전략

| 벤더 | 주 연동 방식 | 주의사항 |
|------|:---------:|---------|
| 두레이 (Dooray) | REST API | OAuth 2.0, Rate limit 확인 |
| 한컴 그룹웨어 | REST API | API 키, SOAP 혼재 가능 |
| 영림원 그룹웨어 | DB Direct (보통) | Oracle/Tibero |
| 네이버웍스 | REST API | OAuth, 토큰 만료 갱신 |
| 기타 사내 시스템 | DB Direct | 테이블 매핑 커스텀 |

---

## 6. 환경 변수 (.env)

```env
# 그룹웨어 모드
GROUPWARE_MODE=REST_API              # REST_API | DB_DIRECT | MOCK

# REST API 모드
GROUPWARE_API_URL=https://gw.agency.go.kr/api/v1
GROUPWARE_API_KEY=<api-key>
GROUPWARE_OAUTH_CLIENT_ID=<client-id>
GROUPWARE_OAUTH_CLIENT_SECRET=<secret>

# DB Direct 모드
GROUPWARE_DB_HOST=192.168.x.x
GROUPWARE_DB_PORT=3306
GROUPWARE_DB_NAME=groupware
GROUPWARE_DB_USER=alli_readonly
GROUPWARE_DB_PASSWORD=<password>

# 공통
GROUPWARE_TIMEOUT_SEC=10
GROUPWARE_RETRY_COUNT=3
```

---

## 7. MCP 서버 등록

```python
# apps/groupware-mcp/src/mcp/server.py

from src.tools.get_schedule import get_schedule
from src.tools.get_pending_approvals import get_pending_approvals
from src.tools.get_monthly_schedule import get_monthly_schedule

mcp.add_tool(get_schedule)
mcp.add_tool(get_pending_approvals)
mcp.add_tool(get_monthly_schedule)
```

---

## 8. 관련 문서

- [erp-mcp-tools.md](erp-mcp-tools.md) — ERP 쪽 스펙
- [db-schemas.sql](db-schemas.sql) — GW_SCHEDULE / GW_APPROVAL 스키마
- [../../design/groupware-mcp.md](../../design/groupware-mcp.md) — groupware-mcp 전체 설계
- [external-dependencies.md](external-dependencies.md) — 그룹웨어 접근 권한 사전 협의
