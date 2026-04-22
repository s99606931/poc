# 과제 1 전자결재 기안 — 구현 아키텍처 상세

> **연관**: [test-scenarios.md](test-scenarios.md) / [README.md](README.md)

---

## 1. 컴포넌트 계층

```
UI:      chat-web (PersonalTaskCard → ApprovalDraftCard)
API:     chat-api SSE
Orch:    ai-assistant.approval_draft_graph (신규)
MCP:     erp-mcp.get_expense_info (신규)
         groupware-mcp.{get_approval_route, get_doc_template, create_approval_draft} (신규)
LLM:     vllm-vision Gemma-4 31B (초안 생성 + 규정 검증)
RAG:     ai-rag (지출 규정 검색)
Data:    ERP DB (예산/지출), 그룹웨어 DB/API, Milvus (규정)
```

## 2. approval_draft_graph 구조

```python
class ApprovalDraftState(TypedDict):
    # Input
    session_id: str
    emp_cd: str
    tenant_id: str
    user_query: str               # "부산 출장비 청구 기안 작성해줘"

    # Phase 1: classify_node (재사용)
    doc_type: str                 # TRIP | PURCHASE | OVERTIME
    confidence: float
    extracted_entities: dict      # {destination, start_date, end_date, transport, ...}

    # Phase 2: parallel_fetch_node (재사용)
    erp_expense_info: dict        # get_expense_info 응답
    approval_route: dict          # get_approval_route 응답
    doc_template: dict            # get_doc_template 응답

    # Phase 3: generate_draft_node (신규)
    draft_content: dict           # LLM 생성 기안 본문 (JSON)

    # Phase 4: validate_draft_node (evidence_assess_node 재사용)
    compliance_result: dict       # {is_compliant, score, warnings, ...}

    # Phase 5: register_node (신규)
    approval_id: str              # "GW-APR-20260421-102"
    gw_url: str
    save_mode: str                # DRAFT | SUBMIT
```

### 그래프 빌드

```python
def build_approval_draft_graph() -> StateGraph:
    g = StateGraph(ApprovalDraftState)

    g.add_node("classify_doc_type", classify_node)       # 재사용
    g.add_node("parallel_fetch",    parallel_fetch_node)  # 재사용
    g.add_node("generate_draft",    generate_draft_node)  # 신규
    g.add_node("validate_draft",    evidence_assess_node) # 재사용
    g.add_node("register_or_save",  register_node)        # 신규

    # 조건부 라우팅 — 규정 위반 시
    g.add_conditional_edges(
        "validate_draft",
        route_on_compliance,
        {
            "compliant":            "register_or_save",  # score >= 70
            "warnings_only":        "register_or_save",  # 경고만, 저장은 허용
            "critical_violation":   "ask_user_confirm",  # 사용자 확인
        }
    )

    return g.compile()
```

## 3. 핵심 노드 계약

### generate_draft_node

```python
async def generate_draft_node(state: ApprovalDraftState) -> dict:
    """
    Gemma-4 호출로 기안 JSON 생성
    - Few-shot 3종 (TRIP/PURCHASE/OVERTIME)
    - response_format=json_object 강제
    - template.fields와 정확히 매칭되는 키 검증
    """
    prompt = APPROVAL_DRAFT_USER_TEMPLATE.format(
        user_message=state["user_query"],
        doc_type=state["doc_type"],
        classify_confidence=state["confidence"],
        extracted_entities_json=json.dumps(state["extracted_entities"]),
        template_id=state["doc_template"]["template_id"],
        template_fields_json=json.dumps(state["doc_template"]["fields"]),
        budget_balance=state["erp_expense_info"]["budget_info"]["balance"],
        budget_account_cd=state["erp_expense_info"]["budget_info"]["budget_account_cd"],
        per_trip_limit=state["erp_expense_info"]["expense_limit"]["per_trip_limit"],
        past_expenses_summary=summarize_past(state["erp_expense_info"]["past_expenses"]),
        approval_route_summary=summarize_route(state["approval_route"]),
    )

    response = await llm_client.chat_completions(
        model="coder",
        messages=[
            {"role": "system", "content": APPROVAL_DRAFT_SYSTEM},
            *FEW_SHOT_EXAMPLES,
            {"role": "user", "content": prompt},
        ],
        max_tokens=2000,
        temperature=0.2,
        response_format={"type": "json_object"},
    )

    draft = json.loads(response["content"])

    # template.fields 검증
    required_fields = [f["name"] for f in state["doc_template"]["fields"] if f["required"]]
    missing = [f for f in required_fields if f not in draft]
    if missing:
        logger.warning(f"필수 필드 누락: {missing}")
        draft = await retry_with_strict_prompt(...)

    return {"draft_content": draft}
```

### register_node

```python
async def register_node(state: ApprovalDraftState) -> dict:
    """
    그룹웨어에 기안 등록 (또는 초안 저장)
    - save_mode=DRAFT: 기본, 담당자 확인 후 상신
    - save_mode=SUBMIT: 자동 상신 (고객 D1-02에 따라)
    """
    resp = await groupware_mcp.call_tool("create_approval_draft", {
        "requester_emp_cd": state["emp_cd"],
        "doc_type": state["doc_type"],
        "template_id": state["doc_template"]["template_id"],
        "fields": state["draft_content"],
        "approval_route": [
            {"step": r["step"], "approver_emp_cd": r["approver_emp_cd"]}
            for r in state["approval_route"]["recommended_route"]
        ],
        "save_mode": state.get("save_mode", "DRAFT"),
    })

    return {
        "approval_id": resp["approval_id"],
        "gw_url": resp["gw_url"],
    }
```

## 4. 데이터 흐름 (Happy Path)

```
User: "부산 출장비 청구 기안 작성해줘 (2026-04-27~29, KTX, 2박)"
  ↓
classify_doc_type:
  → doc_type=TRIP, confidence=0.97
  → entities: {destination:부산, start:2026-04-27, end:2026-04-29, transport:KTX, nights:2}
  ↓
parallel_fetch (3개 병렬):
  ├─ erp-mcp.get_expense_info(TRIP):
  │    예산 잔액 7,500,000원, 지출 한도 500,000원/회, 과거 출장 2건
  ├─ groupware-mcp.get_approval_route(TRIP, amount=285000):
  │    3단계 (팀장→부장→국장), rule=TRIP_RULE_2026_V3_MID
  └─ groupware-mcp.get_doc_template(TRIP):
       template_id=TPL-TRIP-V3, fields=[title, trip_destination, ...]
  ↓
generate_draft (LLM):
  JSON: {title:"부산 출장비 청구...", amount:285000, legal_basis:"공무원 여비규정 제5조", ...}
  ↓
validate_draft (evidence_assess 재사용):
  RAG 검색 → "공무원 여비규정 제5조" 조회
  LLM 평가 → {is_compliant:true, score:92, warnings:[], ...}
  ↓
register_or_save (save_mode=DRAFT):
  groupware-mcp.create_approval_draft() → approval_id, gw_url
  ↓
chat-web ApprovalDraftCard:
  [본문 편집 textarea] + [결재선 바] + [예산 잔액 표시] + [상신 버튼]
```

## 5. 에러 처리

| 단계 | 에러 | 복구 |
|------|------|------|
| classify | 신뢰도 < 0.7 | 사용자에게 재질문 (명확화) |
| parallel_fetch | erp 타임아웃 | 예산 검증 스킵 + 경고 |
| parallel_fetch | groupware 실패 | **Write 불가 → 초안 전송만** |
| generate_draft | JSON 파싱 실패 | strict prompt 재시도 |
| validate_draft | 위반 발견 | 사용자 확인 UI로 분기 |
| register | 그룹웨어 Write 거부 | 초안을 DB 임시 저장 |

## 6. 성능 SLO

| SLI | SLO |
|-----|:---:|
| P50 응답 시간 | ≤ 8초 |
| P95 응답 시간 | ≤ 12초 |
| 기안 생성 성공률 | ≥ 80% (담당자 평가) |
| 필수 필드 포함률 | ≥ 95% |
