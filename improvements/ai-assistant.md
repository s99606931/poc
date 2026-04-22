# ai-assistant 서비스 개선 태스크 (POC 대응)

> **서비스**: `projects/10_alli-work/apps/ai-assistant`
> **현재 포트**: 4005
> **기술**: FastAPI + LangGraph (멀티 에이전트 오케스트레이터)
> **POC 역할**: 전 분야 AI 오케스트레이션 (POC 1, 2, 3 공통 핵심)
> **작성일**: 2026-04-21

> **📌 POC 확장 범위 요약**
>
> 기존 17개 노드 (`src/graph/nodes/`) 위에 4개 서브 그래프 신규 추가:
> | 그래프 | 관련 과제 | 재사용 노드 | 설계 문서 |
> |--------|---------|------------|---------|
> | `approval_draft_graph` | 과제 1 (전자결재 기안) | classify, fetch, plan, generate | [challenges/01](../challenges/01-intelligent-workflow.md) |
> | `personal_assistant_graph` | 과제 3 (개인비서) | parallel_fetch, generate | [challenges/03](../challenges/03-personal-assistant.md) |
> | `sync_graph` | 과제 2 (ERP 동기화, 2단계) | fetch, diff_detect(신규) | [challenges/02](../challenges/02-mcp-data-sync.md) |
> | `compliance_graph` | 과제 5 (문서 적합성) | classify, fetch, candidate_extraction, evidence_assess | [design/doc-compliance.md](../design/doc-compliance.md) |

---

## 현재 상태

```
✅ LangGraph 멀티 에이전트 파이프라인
✅ MCP 클라이언트 (erp-mcp 연동)
✅ 병렬 노드 실행 (parallel_fetch_node 패턴)
✅ ai-rag 내부 검색 API 연동
✅ ai_llm 스트리밍 응답
❌ groupware-mcp 클라이언트 없음
❌ ERP 자동화 (결재 기안, 경로 추천) 시나리오 미구현
❌ 규정 점검 전용 시나리오 없음
❌ 이상 패턴 설명 생성 시나리오 미구현
❌ 개인 맞춤형 비서 워크플로우 미구현
```

---

## 개선 태스크

### TASK-AI-01 groupware-mcp 클라이언트 추가

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (POC 1 ERP 자동화 필수) |
| **예상 공수** | 1일 |
| **담당** | AI/ML 중급 |

```python
# ai-assistant/src/clients/groupware_mcp_client.py
# erp-mcp 클라이언트 패턴 그대로 재사용

class GroupwareMCPClient:
    """groupware-mcp 서비스 HTTP 클라이언트"""
    
    BASE_URL = settings.GROUPWARE_MCP_URL  # http://groupware-mcp:4011
    
    async def get_approval_list(self, emp_cd: str, status: str = "pending") -> list:
        """대기 중인 결재 목록 조회"""
        
    async def create_approval_draft(self, draft_data: dict) -> dict:
        """전자결재 기안 등록"""
        
    async def get_schedule(self, emp_cd: str, target_date: str) -> list:
        """개인 일정 조회"""
        
    async def get_approval_route(self, doc_type: str, dept_cd: str) -> dict:
        """결재 경로 추천 조회"""
        
    async def get_hr_info(self, emp_cd: str) -> dict:
        """인사 정보 조회"""
```

#### 완료 기준
- groupware-mcp 서비스 기동 후 클라이언트 연결 테스트 통과

---

### TASK-AI-02 전자결재 자동 기안 LangGraph 시나리오

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (POC 1 핵심) |
| **예상 공수** | 4일 |
| **담당** | AI/ML 상급 |

```python
# ai-assistant/src/graphs/erp_approval_graph.py

def create_approval_graph():
    """전자결재 자동 기안 LangGraph"""
    
    graph = StateGraph(ApprovalState)
    
    # 노드 정의
    graph.add_node("parse_intent", parse_approval_intent)
    graph.add_node("fetch_erp_data", fetch_erp_expense_data)       # erp-mcp
    graph.add_node("fetch_approval_route", fetch_approval_route)    # groupware-mcp
    graph.add_node("generate_draft", generate_approval_draft)       # ai_llm
    graph.add_node("register_draft", register_to_groupware)         # groupware-mcp
    graph.add_node("respond", generate_response)
    
    # 엣지 정의
    graph.add_edge(START, "parse_intent")
    graph.add_edge("parse_intent", "fetch_erp_data")
    graph.add_edge("parse_intent", "fetch_approval_route")  # 병렬
    graph.add_edge(["fetch_erp_data", "fetch_approval_route"], "generate_draft")
    graph.add_conditional_edges(
        "generate_draft",
        should_register,  # 사용자 확인 후 등록
        {"confirm": "register_draft", "preview": "respond"}
    )
    graph.add_edge("register_draft", "respond")
    graph.add_edge("respond", END)
    
    return graph.compile()

# 트리거 키워드 → 시나리오 라우팅
SCENARIO_ROUTING = {
    "결재 기안|기안 작성|결재 요청": "approval_graph",
    "업무 리마인드|오늘 할일|마감 알려줘": "personal_assistant_graph",
    "규정 질문|규정 찾아줘": "regulation_qa_graph",
}
```

#### 완료 기준
- "출장비 청구 기안 작성해줘" → 기안 문서 초안 생성 및 그룹웨어 등록 E2E 성공

---

### TASK-AI-03 개인 맞춤형 비서 LangGraph 시나리오

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (POC 1 핵심) |
| **예상 공수** | 3일 |
| **담당** | AI/ML 상급 |

```python
# ai-assistant/src/graphs/personal_assistant_graph.py

def create_personal_assistant_graph():
    """개인 맞춤형 비서 LangGraph (병렬 데이터 수집)"""
    
    graph = StateGraph(PersonalAssistantState)
    
    graph.add_node("fetch_erp_deadlines", fetch_erp_deadlines)     # erp-mcp 병렬
    graph.add_node("fetch_gw_schedule", fetch_gw_schedule)          # groupware-mcp 병렬
    graph.add_node("fetch_pending_approvals", fetch_pending_approvals)  # 병렬
    graph.add_node("prioritize_tasks", prioritize_with_llm)         # ai_llm
    graph.add_node("respond", generate_assistant_response)
    
    # 병렬 데이터 수집 → 우선순위 분석
    graph.add_edge(START, ["fetch_erp_deadlines", "fetch_gw_schedule", "fetch_pending_approvals"])
    graph.add_edge(
        ["fetch_erp_deadlines", "fetch_gw_schedule", "fetch_pending_approvals"],
        "prioritize_tasks"
    )
    graph.add_edge("prioritize_tasks", "respond")
    graph.add_edge("respond", END)
    
    return graph.compile()
```

#### 완료 기준
- "오늘 처리할 업무 알려줘" → ERP 마감일 + 그룹웨어 일정 통합 → 우선순위 순 응답

---

### TASK-AI-04 이상 패턴 설명 생성 (POC 3 지원)

| 항목 | 내용 |
|------|------|
| **우선순위** | P1 (POC 3 감사 지원) |
| **예상 공수** | 2일 |
| **담당** | AI/ML 중급 |

```python
# ai-assistant/src/graphs/audit_explanation_graph.py
# audit-anomaly → ai-assistant API 호출 → 이상 패턴 자연어 설명 생성

@router.post("/internal/audit/explain")
async def explain_anomaly(
    anomaly_data: AnomalyData,
    regulation_context: Optional[str] = None
):
    """
    audit-anomaly가 발견한 이상 패턴을 자연어로 설명
    + 관련 규정 조항 함께 제시 (ai-rag 연동)
    """
    
    # ai-rag에서 관련 규정 검색
    regulation_refs = await rag_client.search(
        query=f"{anomaly_data.rule_name} 관련 규정",
        partition="regulation_finance"
    )
    
    # LLM으로 감사 담당자용 설명 생성
    explanation = await llm_client.generate(
        prompt=AUDIT_EXPLANATION_PROMPT.format(
            anomaly=anomaly_data.dict(),
            regulations=regulation_refs
        )
    )
    
    return {
        "explanation": explanation,
        "regulation_refs": [r["article_title"] for r in regulation_refs],
        "recommended_action": "감사팀 검토 요청" if anomaly_data.risk_level == "HIGH" else "모니터링 유지"
    }
```

---

### TASK-AI-05 시나리오 라우팅 강화

| 항목 | 내용 |
|------|------|
| **우선순위** | P1 |
| **예상 공수** | 2일 |

```python
# Intent 분류 → 시나리오 라우팅
INTENT_CLASSIFIER_PROMPT = """
사용자의 요청을 다음 시나리오 중 하나로 분류하세요:

1. APPROVAL_DRAFT: 결재 기안 작성 요청 (예: "기안 작성해줘", "결재 올려줘")
2. PERSONAL_ASSISTANT: 업무/일정 가이드 (예: "오늘 할일", "마감 알려줘")
3. REGULATION_QA: 규정 질문 (예: "연가 며칠", "출장 규정")
4. GENERAL_CHAT: 일반 대화

사용자 입력: {user_input}
분류 결과 (숫자만):
"""

async def route_to_scenario(user_input: str) -> str:
    intent = await classify_intent(user_input)
    return SCENARIO_MAPPING[intent]
```

---

## 완료 체크리스트

```
□ TASK-AI-01: groupware-mcp 클라이언트 구현 및 연결 테스트
□ TASK-AI-02: 전자결재 기안 LangGraph 구현 (E2E 테스트 포함)
□ TASK-AI-03: 개인 비서 LangGraph 구현 (병렬 수집 확인)
□ TASK-AI-04: 이상 패턴 설명 API 구현 (audit-anomaly 연동)
□ TASK-AI-05: Intent 분류 → 시나리오 라우팅 구현
□ 시나리오별 LangGraph 스트리밍 SSE 테스트
□ chat-web → ai-assistant E2E 통합 테스트
```
