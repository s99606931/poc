# 과제 3 개인비서 — 상세 구성도

> **작성일**: 2026-04-21

---

## 1. 전체 컴포넌트 아키텍처

```mermaid
%%{init: {'theme': 'dark', 'themeVariables': {'primaryColor': '#1d4ed8', 'primaryTextColor': '#f8fafc', 'primaryBorderColor': '#3b82f6', 'lineColor': '#94a3b8', 'secondaryColor': '#1e293b', 'tertiaryColor': '#0f172a', 'background': '#0f172a', 'mainBkg': '#1e293b', 'nodeBorder': '#475569', 'clusterBkg': '#1e293b', 'titleColor': '#f8fafc', 'edgeLabelBackground': '#1e293b'}}}%%
graph TB
    classDef ui fill:#2563eb,stroke:#1d4ed8,color:#fff
    classDef api fill:#059669,stroke:#047857,color:#fff
    classDef mcp fill:#c2440f,stroke:#9a3510,color:#fff
    classDef llm fill:#7c3aed,stroke:#6d28d9,color:#fff
    classDef ext fill:#b45309,stroke:#92400e,color:#fff

    subgraph UI["1. UI 레이어"]
        CW["chat-web :3000<br/>PersonalTaskCard"]:::ui
    end

    subgraph API["2. API 레이어"]
        CA["chat-api :4002<br/>mode=personal_assistant"]:::api
    end

    subgraph Orch["3. 오케스트레이션"]
        AA["ai-assistant :4005<br/>personal_assistant_graph"]:::api

        subgraph Nodes["LangGraph 노드"]
            N1["classify_node<br/>(재사용)"]:::api
            N2["parallel_fetch<br/>(fetch_node 재사용)"]:::api
            N3["analyze_priority<br/>(신규)"]:::api
            N4["generate_guide<br/>(generate_node 재사용)"]:::api
        end
    end

    subgraph MCP["4. MCP 도구"]
        EM["erp-mcp :4010<br/>• get_deadline_tasks<br/>• get_pending_items"]:::mcp
        GM["groupware-mcp :4011<br/>• get_schedule<br/>• get_pending_approvals"]:::mcp
    end

    subgraph SQL["5. SQL 실행"]
        SR["sql-runner :4004<br/>Read-Only"]:::api
    end

    subgraph LLM["6. LLM 추론"]
        VL["vllm-vision :6012<br/>Gemma-4 31B AWQ (TP=4)"]:::llm
    end

    subgraph External["7. 외부 데이터 소스"]
        EDB["ERP DB<br/>V_ALLI_HCM_DEADLINE<br/>V_ALLI_ACC_CLOSING<br/>V_ALLI_BDG_SUBMIT<br/>V_ALLI_ACC_PENDING_EXPENSE<br/>V_ALLI_HCM_PENDING_LEAVE"]:::ext
        GDB["그룹웨어 DB/API<br/>GW_SCHEDULE<br/>GW_SCHEDULE_ATTENDEE<br/>GW_APPROVAL<br/>GW_APPROVAL_LINE"]:::ext
    end

    CW -->|"SSE"| CA
    CA --> AA
    AA --> N1 --> N2 --> N3 --> N4
    N2 -->|"병렬 4개 호출"| EM
    N2 -->|"병렬 4개 호출"| GM
    N3 --> VL
    N4 --> VL
    EM --> SR
    SR --> EDB
    GM -->|"REST or DB"| GDB
```

---

## 2. 병렬 조회 타임라인

```mermaid
%%{init: {'theme': 'dark', 'themeVariables': {'primaryColor': '#1d4ed8', 'primaryTextColor': '#f8fafc', 'primaryBorderColor': '#3b82f6', 'lineColor': '#94a3b8', 'secondaryColor': '#1e293b', 'tertiaryColor': '#0f172a'}}}%%
sequenceDiagram
    participant PA as personal_assistant_graph
    participant EM as erp-mcp
    participant GM as groupware-mcp
    participant LLM as ai-llm (Gemma-4)

    Note over PA: 총 예상 시간: 8초 이내

    rect rgb(30, 60, 100)
        Note over PA,GM: Phase 1: 병렬 조회 (~5초)
        par ERP 마감업무
            PA->>+EM: get_deadline_tasks
            EM-->>-PA: tasks[] (1~2s)
        and ERP 미결재
            PA->>+EM: get_pending_items
            EM-->>-PA: items[] (1~2s)
        and 그룹웨어 일정
            PA->>+GM: get_schedule
            GM-->>-PA: schedules[] (2~3s)
        and 그룹웨어 결재
            PA->>+GM: get_pending_approvals
            GM-->>-PA: approvals[] (1~2s)
        end
    end

    rect rgb(60, 30, 100)
        Note over PA,LLM: Phase 2: 우선순위 분석 (~2초)
        PA->>+LLM: analyze_priority (JSON 응답)
        LLM-->>-PA: priorities[]
    end

    rect rgb(60, 30, 80)
        Note over PA,LLM: Phase 3: 가이드 생성 (~1초 SSE 스트리밍 시작)
        PA->>+LLM: generate_guide (SSE)
        LLM-->>-PA: 토큰 스트리밍
    end
```

---

## 3. 데이터 변환 흐름

```mermaid
%%{init: {'theme': 'dark', 'themeVariables': {'primaryColor': '#1d4ed8', 'primaryTextColor': '#f8fafc', 'primaryBorderColor': '#3b82f6', 'lineColor': '#94a3b8', 'secondaryColor': '#1e293b', 'tertiaryColor': '#0f172a'}}}%%
flowchart LR
    A["Raw DB Rows<br/>(ERP + 그룹웨어)"] --> B["MCP Response<br/>(JSON 표준화)"]
    B --> C["LangGraph State<br/>(PersonalAssistantState)"]
    C --> D["LLM Prompt<br/>(Eisenhower 포맷)"]
    D --> E["LLM Response<br/>(priorities JSON)"]
    E --> F["Guide Markdown<br/>+ 카드 JSON"]
    F --> G["SSE Stream<br/>chat-web"]
    G --> H["PersonalTaskCard<br/>(React 렌더링)"]
```

---

## 4. Eisenhower Matrix 우선순위 분석

```
               중요함 (Important)           비중요 (Not Important)
           ┌─────────────────────────────────────────────────┐
  긴급함   │ Q1: 긴급·중요                 │ Q3: 긴급·비중요       │
 (Urgent)  │ → 즉시 실행 (Do)              │ → 위임 or 빠르게 처리  │
           │                              │                    │
           │ 예: 월결산 마감 (D-0 18:00)    │ 예: 출장비 결재 재촉    │
           ├──────────────────────────────┼────────────────────┤
 비긴급    │ Q2: 비긴급·중요               │ Q4: 비긴급·비중요      │
 (Not     │ → 계획적으로 처리 (Schedule)  │ → 제거/스킵 (Delete)   │
 Urgent)   │                              │                    │
           │ 예: 정기평가 의견 제출 (D-2)    │ 예: 선택 설명회 참석    │
           └─────────────────────────────────────────────────┘
```

### 점수 공식

```
urgency_score = max(0, 10 - days_remaining × 2)   (1~10)
importance_score = HIGH=10 / MEDIUM=6 / LOW=3
total_score = urgency_score × importance_score
```

### Quadrant 할당

```python
def assign_quadrant(urgency: int, importance: int) -> str:
    if urgency >= 7 and importance >= 7:
        return "Q1"  # 긴급·중요 (즉시 실행)
    elif urgency < 7 and importance >= 7:
        return "Q2"  # 비긴급·중요 (계획)
    elif urgency >= 7 and importance < 7:
        return "Q3"  # 긴급·비중요 (위임)
    else:
        return "Q4"  # 비긴급·비중요 (제거)
```

---

## 5. 에러 처리 & Fallback

```mermaid
%%{init: {'theme': 'dark', 'themeVariables': {'primaryColor': '#1d4ed8', 'primaryTextColor': '#f8fafc', 'primaryBorderColor': '#3b82f6', 'lineColor': '#94a3b8', 'secondaryColor': '#1e293b', 'tertiaryColor': '#0f172a'}}}%%
graph TD
    A["parallel_fetch 시작"] --> B{"타임아웃 5초"}
    B -->|"모두 성공"| C["analyze_priority 진행"]
    B -->|"부분 실패"| D["사용 가능한 데이터로 진행<br/>+ 부분 결과 안내"]
    B -->|"모두 실패"| E["규칙 기반 fallback<br/>(캐시된 최근 데이터 or 빈 응답)"]

    C --> F{"LLM 분석 성공?"}
    D --> F
    F -->|"Yes"| G["LLM 우선순위 사용"]
    F -->|"No (타임아웃/에러)"| H["규칙 기반 우선순위<br/>(마감일 단순 정렬)"]

    G --> I["가이드 생성"]
    H --> I
    E --> I
```

---

## 6. 캐싱 전략

| 레이어 | 캐시 키 | TTL | 목적 |
|--------|--------|:---:|------|
| Redis (ai-assistant) | `personal_assistant:{emp_cd}:{date}` | 5분 | 동일 사용자 반복 호출 |
| erp-mcp | `deadline_tasks:{emp_cd}:{date}` | 10분 | ERP 부하 감소 |
| groupware-mcp | `schedule:{emp_cd}:{date}` | 5분 | 그룹웨어 API Rate Limit 회피 |

> **주의**: 미결재 건은 실시간성 중요 → 캐싱 TTL 짧게 (1분 이하) 또는 캐싱 안 함.

---

## 7. 관련 문서

- [README.md](README.md) — 구현 체크리스트
- [erp-mcp-tools.md](erp-mcp-tools.md) — ERP MCP 도구 스펙
- [groupware-mcp-tools.md](groupware-mcp-tools.md) — 그룹웨어 MCP 도구 스펙
- [db-schemas.sql](db-schemas.sql) — DB 테이블/뷰 구조
- [api-samples.json](api-samples.json) — 전체 End-to-End 샘플
- [prompt-templates.md](prompt-templates.md) — LLM 프롬프트
