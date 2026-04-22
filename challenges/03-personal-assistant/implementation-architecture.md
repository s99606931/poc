# 과제 3 개인비서 — 구현 아키텍처 상세

> **목적**: 실제 구현 시 각 컴포넌트·클래스·함수 간 관계와 데이터 흐름 상세 기술
> **대상 독자**: 개발자 (D1 AI/백엔드, D2 풀스택)
> **연관 문서**: [architecture.md](architecture.md) (시스템 구성도) / [test-scenarios.md](test-scenarios.md) (테스트 시나리오)

---

## 1. 컴포넌트 계층 구조

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 1 — UI (React/Next.js)                                  │
│    chat-web: PersonalTaskCard.tsx                              │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2 — API Gateway (NestJS)                                │
│    chat-api: ChatController (SSE)                              │
├─────────────────────────────────────────────────────────────────┤
│  Layer 3 — AI Orchestration (FastAPI + LangGraph)              │
│    ai-assistant:                                                │
│      • routers/chat.py (SSE Stream Router)                     │
│      • graph/orchestrator_graph.py (Main Graph)                │
│      • graph/graphs/personal_assistant_graph.py (신규)         │
│      • graph/nodes/ (17 재사용 + 2 신규)                       │
├─────────────────────────────────────────────────────────────────┤
│  Layer 4 — MCP Tools (FastMCP)                                 │
│    erp-mcp: get_deadline_tasks, get_pending_items              │
│    groupware-mcp (신규): get_schedule, get_pending_approvals   │
├─────────────────────────────────────────────────────────────────┤
│  Layer 5 — Data Sources                                        │
│    sql-runner → ERP DB (Oracle/Tibero)                         │
│    groupware-mcp → Groupware DB/API                            │
│    vllm-vision → Gemma-4 31B AWQ (TP=4)                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. LangGraph 그래프 상세 구조

### 2.1 PersonalAssistantState (상태 스키마)

```python
# apps/ai-assistant/src/graph/graphs/personal_assistant_graph.py

from typing import TypedDict, Optional
from datetime import datetime

class PersonalAssistantState(TypedDict):
    # [Input] 호출 시 주입
    session_id: str
    emp_cd: str
    tenant_id: str
    user_query: str
    request_date: str                  # "2026-04-21"
    current_time: datetime

    # [Input 보강] classify_node에서 설정
    detected_intent: str               # "personal_assistant_today"
    emp_context: dict                  # {emp_nm, dept_nm, position}

    # [Phase 1 — parallel_fetch 결과]
    deadline_tasks: list               # erp-mcp 응답
    pending_items: list                # erp-mcp 응답
    schedules: list                    # groupware-mcp 응답
    approvals: list                    # groupware-mcp 응답
    fetch_errors: dict                 # {"erp_deadline": "timeout"} — 부분 실패 기록

    # [Phase 2 — analyze_priority 결과]
    priorities: list                   # LLM 분석 결과
    fallback_used: bool                # 규칙 기반 fallback 사용 여부

    # [Phase 3 — generate_guide 결과]
    guide_card: dict                   # PersonalTaskCard JSON
    summary_text: str                  # 2~3문장 요약
```

### 2.2 노드 구성 및 책임

```python
def build_personal_assistant_graph() -> StateGraph:
    g = StateGraph(PersonalAssistantState)

    # 노드 등록
    g.add_node("load_emp_context",    load_emp_context_node)      # 신규
    g.add_node("parallel_fetch",      parallel_fetch_node)         # fetch_node 기반
    g.add_node("analyze_priority",    analyze_priority_node)       # 신규
    g.add_node("generate_guide",      generate_guide_node)         # generate_node 기반

    # 조건부 라우팅
    g.add_conditional_edges(
        "parallel_fetch",
        check_fetch_result,
        {
            "all_success":     "analyze_priority",
            "partial_success": "analyze_priority",    # 부분 결과로 진행
            "all_failed":      "fallback_guide",       # 캐시 or 빈 응답
        }
    )

    g.add_conditional_edges(
        "analyze_priority",
        check_llm_success,
        {
            "llm_success": "generate_guide",
            "llm_failed":  "rule_based_guide",         # 규칙 기반 fallback
        }
    )

    g.set_entry_point("load_emp_context")
    g.add_edge("load_emp_context", "parallel_fetch")
    g.add_edge("generate_guide", END)
    g.add_edge("fallback_guide", END)
    g.add_edge("rule_based_guide", END)

    return g.compile()
```

### 2.3 노드별 계약 (I/O 스펙)

#### load_emp_context_node

```python
async def load_emp_context_node(state: PersonalAssistantState) -> dict:
    """
    Input:
      - emp_cd, tenant_id
    Output:
      - emp_context: {emp_nm, dept_cd, dept_nm, position}
    Errors:
      - EmployeeNotFoundError → "사용자 정보를 찾을 수 없습니다"
    Dependency:
      - auth-api /employees/{emp_cd} 호출 (AuthClient)
    Timeout: 2초
    """
    emp_info = await auth_client.get_employee(
        state["emp_cd"],
        tenant_id=state["tenant_id"]
    )
    return {"emp_context": emp_info}
```

#### parallel_fetch_node (핵심)

```python
async def parallel_fetch_node(state: PersonalAssistantState) -> dict:
    """
    병렬 호출: 4개 MCP 도구 asyncio.gather
    Partial Failure 허용: 2개 이상 성공 시 진행
    """
    tasks = {
        "deadline_tasks": erp_mcp.call_tool("get_deadline_tasks", {
            "emp_cd": state["emp_cd"],
            "date": state["request_date"],
            "horizon_days": 7,
        }),
        "pending_items":  erp_mcp.call_tool("get_pending_items", {
            "emp_cd": state["emp_cd"],
        }),
        "schedules": groupware_mcp.call_tool("get_schedule", {
            "emp_cd": state["emp_cd"],
            "date_from": state["request_date"],
            "date_to":   state["request_date"],
        }),
        "approvals": groupware_mcp.call_tool("get_pending_approvals", {
            "emp_cd": state["emp_cd"],
            "role":  "APPROVER",
        }),
    }

    # 5초 타임아웃 + 각 개별 결과 수집
    results = await asyncio.gather(
        *tasks.values(),
        return_exceptions=True
    )

    output = {}
    errors = {}
    for key, result in zip(tasks.keys(), results):
        if isinstance(result, Exception):
            errors[key] = str(result)
            output[key] = []            # 빈 리스트로 진행
        else:
            output[key] = result.get(key, result)  # 키로 추출

    output["fetch_errors"] = errors
    return output
```

#### analyze_priority_node

```python
async def analyze_priority_node(state: PersonalAssistantState) -> dict:
    """
    LLM 호출 → JSON 우선순위 분석
    실패 시: rule_based_fallback으로 복귀 (조건부 라우팅)
    """
    user_prompt = ANALYZE_PRIORITY_USER_TEMPLATE.format(
        emp_name=state["emp_context"]["emp_nm"],
        dept_nm=state["emp_context"]["dept_nm"],
        position=state["emp_context"]["position"],
        date=state["request_date"],
        current_time=state["current_time"].isoformat(),
        deadline_tasks_summary=_summarize_deadline_tasks(state["deadline_tasks"]),
        pending_items_summary=_summarize_pending_items(state["pending_items"]),
        schedules_summary=_summarize_schedules(state["schedules"]),
        approvals_summary=_summarize_approvals(state["approvals"]),
    )

    try:
        response = await llm_client.chat_completions(
            model="coder",
            messages=[
                {"role": "system", "content": PERSONAL_ASSISTANT_SYSTEM},
                *FEW_SHOT_EXAMPLES,
                {"role": "user", "content": user_prompt},
            ],
            max_tokens=800,
            temperature=0.1,
            response_format={"type": "json_object"},
            timeout=10.0,
        )
        parsed = json.loads(response["content"])
        return {
            "priorities": parsed["priorities"],
            "fallback_used": False,
        }
    except (asyncio.TimeoutError, json.JSONDecodeError, httpx.HTTPError) as e:
        logger.warning(f"LLM 분석 실패: {e} — 규칙 기반 fallback으로 전환")
        return {
            "priorities": rule_based_priority_fallback(state),
            "fallback_used": True,
        }
```

#### generate_guide_node

```python
async def generate_guide_node(state: PersonalAssistantState) -> dict:
    """
    SSE 스트리밍: LLM 토큰을 실시간 chat-api로 전달
    동시에 최종 guide_card JSON도 구성하여 반환
    """
    guide_stream = llm_client.chat_completions_stream(
        model="coder",
        messages=[
            {"role": "system", "content": GENERATE_GUIDE_SYSTEM},
            {"role": "user",   "content": GENERATE_GUIDE_USER_TEMPLATE.format(
                priorities_json=json.dumps(state["priorities"], ensure_ascii=False),
                current_time=state["current_time"].isoformat(),
                emp_name=state["emp_context"]["emp_nm"],
            )},
        ],
        max_tokens=1500,
        temperature=0.3,
        response_format={"type": "json_object"},
    )

    full_response = ""
    async for chunk in guide_stream:
        full_response += chunk
        # chat-api SSE writer에 전달 (별도 streaming context)
        await state["sse_writer"].send({
            "event": "personal_assistant_card.chunk",
            "data": chunk,
        })

    guide_card = json.loads(full_response)
    return {
        "guide_card": guide_card,
        "summary_text": guide_card.get("summary", ""),
    }
```

---

## 3. 외부 시스템 통신 계약

### 3.1 erp-mcp 호출 (MCP 프로토콜)

```python
# apps/ai-assistant/src/clients/mcp_client.py

class MCPClient:
    def __init__(self, base_url: str, auth_token: str):
        self.base_url = base_url
        self.auth_token = auth_token

    async def call_tool(self, tool_name: str, params: dict) -> dict:
        """
        MCP over HTTP + SSE 프로토콜
        - JWT ES256 인증 (emp_cd, tenant_id, dept_cd 클레임)
        - 재시도 3회 (지수 백오프)
        - 서킷 브레이커 (3회 연속 실패 → 60초 차단)
        """
        request = {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": params},
            "id": str(uuid.uuid4()),
        }

        for attempt in range(3):
            try:
                resp = await self.http.post(
                    f"{self.base_url}/mcp/execute",
                    json=request,
                    headers={"Authorization": f"Bearer {self.auth_token}"},
                    timeout=5.0,
                )
                resp.raise_for_status()
                result = resp.json()
                if "error" in result:
                    raise MCPError(result["error"]["message"])
                return result["result"]
            except (httpx.TimeoutException, httpx.HTTPError) as e:
                if attempt < 2:
                    await asyncio.sleep(2 ** attempt)
                else:
                    raise
```

### 3.2 sql-runner 호출 (erp-mcp 내부)

```python
# apps/erp-mcp/src/clients/sql_runner_client.py

class SQLRunnerClient:
    @classmethod
    async def query(cls, sql: str, params: dict) -> list[dict]:
        """
        sql-runner (:4004)로 Read-Only 쿼리 위임
        - 감사 로그 자동 기록 (sql-runner 측)
        - 파라미터 바인딩 (SQL injection 방지)
        - 최대 결과 1000행 제한
        """
        resp = await cls.http.post(
            f"{cls.base_url}/api/v1/query",
            json={
                "sql": sql,
                "params": params,
                "driver": settings.ERP_DB_DRIVER,  # oracle | tibero | mariadb
                "mode": "read_only",
                "max_rows": 1000,
                "timeout_sec": 3,
            },
        )
        return resp.json()["rows"]
```

---

## 4. 데이터 변환 파이프라인

### 4.1 DB Row → MCP Response

```python
# apps/erp-mcp/src/tools/get_deadline_tasks.py

async def get_deadline_tasks(emp_cd: str, date: str, horizon_days: int = 7) -> dict:
    raw_rows = await SQLRunnerClient.query(SQL_DEADLINE_TASKS, {
        "emp_cd": emp_cd,
        "date": date,
        "end_date": (date + timedelta(days=horizon_days)).isoformat(),
    })

    tasks = [
        DeadlineTask(
            task_id=row["task_id"],
            category=row["category"],
            subcategory=row["subcategory"],
            title=row["title"],
            description=row["description"],
            deadline=_parse_datetime(row["deadline"]),
            days_remaining=_calc_days_remaining(row["deadline"], date),
            importance=row["importance"],
            urgency=_urgency_level(row["deadline"], date),
            source_view=_source_by_category(row["category"]),
            related_url=row["related_url"],
            department_cd=row["department_cd"],
            submitted=row["submitted"] == "Y",
        ).dict()
        for row in raw_rows
    ]

    # 감사 로그
    await audit_log({
        "tool": "get_deadline_tasks",
        "emp_cd": emp_cd,
        "result_count": len(tasks),
    })

    return {
        "emp_cd": emp_cd,
        "query_date": date,
        "horizon_days": horizon_days,
        "total_count": len(tasks),
        "tasks": tasks,
        "summary": _summarize(tasks),
    }
```

### 4.2 MCP Response → LangGraph State

- 원본 JSON을 그대로 state.deadline_tasks에 저장
- summary 필드는 analyze_priority_node에서 프롬프트 주입 시 사용

### 4.3 State → LLM Prompt

```python
def _summarize_deadline_tasks(tasks: list) -> str:
    """LLM 프롬프트용 요약 문자열 생성"""
    if not tasks:
        return "(없음)"
    return "\n".join(
        f"- [{t['task_id']}] {_urgency_emoji(t['days_remaining'])} "
        f"{t['title']} (D-{t['days_remaining']}, {t['importance']})"
        for t in tasks
    )
```

### 4.4 LLM JSON → PersonalTaskCard

```typescript
// apps/chat-web/src/components/slots/PersonalTaskCard.tsx

interface PersonalTaskCardProps {
  summary: string;
  current_time: string;
  matrix: {
    q1_urgent_important: TaskItem[];
    q2_important_not_urgent: TaskItem[];
    q3_urgent_not_important: TaskItem[];
    q4_not_urgent_not_important: TaskItem[];
  };
  recommended_action_sequence: string[];
  follow_ups: FollowUp[];
}

interface TaskItem {
  id: string;
  time: string;        // "D-0 18:00" or "10:00~11:00"
  title: string;
  category: string;
  link: string | null;
}
```

---

## 5. 에러 처리 매트릭스

| 단계 | 에러 유형 | 처리 방식 | 사용자 경험 |
|------|---------|---------|---------|
| `load_emp_context` | EmployeeNotFound | 즉시 에러 반환 | "사용자 정보 오류" 메시지 |
| `parallel_fetch` | 개별 MCP 타임아웃 (5s) | 빈 리스트로 진행 | "일부 데이터 조회 실패" 배너 |
| `parallel_fetch` | 4개 모두 실패 | fallback_guide 노드 | "잠시 후 다시 시도해주세요" |
| `analyze_priority` | LLM 타임아웃 (10s) | 규칙 기반 fallback | "기본 정렬로 표시" 배지 |
| `analyze_priority` | JSON 파싱 실패 | 규칙 기반 fallback | 동일 |
| `generate_guide` | LLM 스트리밍 중단 | 부분 응답 완성 시도 | "이어받기" 버튼 제공 |
| `generate_guide` | 최종 JSON 불완전 | 수동 구성 (priorities 기반) | 일부 필드 누락 허용 |

---

## 6. 캐싱 전략

### 6.1 Redis 캐시 키 설계

```
# 계층별 캐시
personal_assistant:{tenant_id}:{emp_cd}:{date}           TTL=5분 (최종 결과)
mcp:erp:deadline_tasks:{emp_cd}:{date}                   TTL=10분
mcp:erp:pending_items:{emp_cd}                           TTL=1분 (실시간성)
mcp:gw:schedule:{emp_cd}:{date}                          TTL=5분
mcp:gw:pending_approvals:{emp_cd}                        TTL=1분
emp_context:{tenant_id}:{emp_cd}                         TTL=1시간
```

### 6.2 캐시 무효화

```python
# 사용자가 "새로고침" 클릭 시
await cache.delete_pattern(f"personal_assistant:{tenant_id}:{emp_cd}:*")
await cache.delete_pattern(f"mcp:*:{emp_cd}:*")

# 인사 변경 시 (과제 2 sync에서 트리거)
await cache.delete(f"emp_context:{tenant_id}:{emp_cd}")
```

---

## 7. 관찰 가능성 (Observability)

### 7.1 메트릭 (Prometheus)

```python
# apps/ai-assistant/src/observability/metrics.py

PA_REQUEST_COUNT = Counter(
    'ai_assistant_personal_assistant_requests_total',
    'Total personal assistant requests',
    ['tenant_id', 'status']
)

PA_LATENCY = Histogram(
    'ai_assistant_personal_assistant_duration_seconds',
    'Request latency',
    ['phase'],  # fetch | analyze | generate
    buckets=[0.5, 1.0, 2.0, 3.0, 5.0, 8.0, 13.0]
)

PA_FETCH_PARTIAL = Counter(
    'ai_assistant_personal_assistant_partial_fetch_total',
    'Partial fetch failures',
    ['missing_source']  # erp_deadline | gw_schedule | ...
)

PA_FALLBACK = Counter(
    'ai_assistant_personal_assistant_fallback_total',
    'Rule-based fallback invocations'
)
```

### 7.2 분산 추적 (OpenTelemetry)

```python
from opentelemetry import trace

tracer = trace.get_tracer(__name__)

@tracer.start_as_current_span("personal_assistant_graph")
async def invoke(state):
    with tracer.start_as_current_span("parallel_fetch"):
        ...
    with tracer.start_as_current_span("analyze_priority"):
        ...
    with tracer.start_as_current_span("generate_guide"):
        ...
```

Trace ID가 chat-api → ai-assistant → erp-mcp/groupware-mcp → sql-runner까지 전파되어 전체 요청 흐름 추적 가능.

### 7.3 구조화 로그

```json
{
  "timestamp": "2026-04-21T10:05:23.456+09:00",
  "level": "INFO",
  "service": "ai-assistant",
  "trace_id": "abc123...",
  "span_id": "def456...",
  "event": "personal_assistant.completed",
  "session_id": "sess-20260421-abc123",
  "emp_cd": "EMP20240315",
  "tenant_id": "tenant-001",
  "phase_durations_ms": {
    "load_context": 120,
    "parallel_fetch": 3840,
    "analyze_priority": 1820,
    "generate_guide": 2110
  },
  "total_duration_ms": 7890,
  "result": {
    "tasks_count": 8,
    "fallback_used": false,
    "fetch_errors": {}
  }
}
```

---

## 8. 배포 구성 (Docker Compose)

```yaml
# docker-compose.yaml 변경점

services:
  groupware-mcp:                    # 신규 서비스
    image: harbor.allsharp.co.kr/alli/groupware-mcp:1.0.0
    container_name: alli-groupware-mcp
    depends_on:
      - auth-api
      - sql-runner
    environment:
      - GROUPWARE_MODE=${GROUPWARE_MODE:-REST_API}
      - GROUPWARE_API_URL=${GROUPWARE_API_URL}
      - GROUPWARE_API_KEY=${GROUPWARE_API_KEY}
      - AUTH_API_URL=http://auth-api:4003
      - SQL_RUNNER_URL=http://sql-runner:4004
    ports:
      - "4011:4011"
    networks:
      - alli
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4011/health"]
      interval: 30s
```

---

## 9. 성능 SLO / SLI

| SLI (측정 지표) | SLO (목표) | 경고 임계치 |
|---------------|:---------:|:---------:|
| P50 전체 응답 시간 | ≤ 5초 | 7초 |
| P95 전체 응답 시간 | ≤ 8초 | 12초 |
| P99 전체 응답 시간 | ≤ 13초 | 20초 |
| parallel_fetch 성공률 | ≥ 98% | 95% |
| LLM 분석 성공률 | ≥ 95% | 90% |
| 캐시 히트율 | ≥ 30% | 20% |
| fallback 사용률 | ≤ 5% | 10% |

---

## 10. 관련 문서

- [architecture.md](architecture.md) — 시스템 구성도 (초기 버전)
- [test-scenarios.md](test-scenarios.md) — 테스트 시나리오 (본 문서와 쌍)
- [erp-mcp-tools.md](erp-mcp-tools.md) — ERP MCP 도구 계약
- [groupware-mcp-tools.md](groupware-mcp-tools.md) — 그룹웨어 MCP 도구 계약
- [prompt-templates.md](prompt-templates.md) — LLM 프롬프트
