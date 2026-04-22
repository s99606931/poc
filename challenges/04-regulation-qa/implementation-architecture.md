# 과제 4 규정 Q&A — 구현 아키텍처

> **연관**: [test-scenarios.md](test-scenarios.md) | [rag-pipeline.md](rag-pipeline.md)

---

## 1. 컴포넌트 계층

```
UI:     chat-web (RegulationCitationPanel 슬롯)
API:    chat-api (chat_mode=regulation_qa 라우팅)
Orch:   ai-assistant.regulation_qa_graph (신규)
RAG:    ai-rag search_router + rerank_client (완비)
Vector: Milvus regulation_knowledge 컬렉션 (5 파티션)
Embed:  BGE-M3 (ai-llm 내부)
Rerank: bge-reranker-v2-m3
LLM:    vllm-vision Gemma-4 31B AWQ
```

## 2. RegulationQAState

```python
class RegulationQAState(TypedDict):
    session_id: str
    emp_cd: str
    tenant_id: str
    user_query: str               # "연가 신청은 며칠 전까지?"

    # Partition selection
    selected_partitions: list     # ["regulation_hr"]

    # Cache check
    cache_hit: bool
    cache_key: str

    # Search phase
    query_embedding: list         # BGE-M3 1024-dim
    retrieved_chunks: list        # Milvus Top-20
    reranked_chunks: list         # Reranker Top-5
    search_time_ms: int

    # Answer phase
    answer_text: str              # SSE 스트리밍 결과
    citations: list               # [{regulation_name, article_no, relevance}]
    related_questions: list       # LLM 제안 follow-up 3개
    quality_score: int            # 자동 평가 (0~100)
```

## 3. 그래프 구성

```python
def build_regulation_qa_graph():
    g = StateGraph(RegulationQAState)

    g.add_node("check_cache",         check_cache_node)
    g.add_node("select_partition",    select_partition_node)
    g.add_node("embed_query",         embed_query_node)
    g.add_node("milvus_search",       milvus_search_node)
    g.add_node("rerank",              rerank_node)
    g.add_node("generate_answer",     generate_answer_node)  # SSE
    g.add_node("evaluate_quality",    evaluate_quality_node)
    g.add_node("save_cache",          save_cache_node)

    g.set_entry_point("check_cache")

    g.add_conditional_edges(
        "check_cache",
        lambda s: "hit" if s["cache_hit"] else "miss",
        {"hit": END, "miss": "select_partition"}
    )

    g.add_edge("select_partition", "embed_query")
    g.add_edge("embed_query",      "milvus_search")
    g.add_edge("rerank",           "generate_answer")
    g.add_edge("generate_answer",  "evaluate_quality")
    g.add_edge("evaluate_quality", "save_cache")
    g.add_edge("save_cache",       END)

    return g.compile()
```

## 4. 핵심 노드 상세

### select_partition_node

```python
async def select_partition_node(state: RegulationQAState) -> dict:
    """키워드 기반 파티션 자동 선택 + LLM 보조"""
    query = state["user_query"]

    # 1. 키워드 매칭 (즉시)
    keyword_match = select_by_keywords(query)  # regulation_hr | finance | general

    # 2. 애매한 경우 LLM 분류 (신뢰도 보강)
    if len(keyword_match) == 0 or len(keyword_match) > 2:
        classified = await llm_client.chat_completions(
            messages=[
                {"role": "system", "content": "다음 질문이 인사/회계/일반 규정 중 어디에 속하는지 분류"},
                {"role": "user", "content": query}
            ],
            max_tokens=50, temperature=0.0
        )
        llm_match = parse_classification(classified["content"])
        keyword_match = list(set(keyword_match + llm_match))

    # 3. 기본값: 전체 검색
    if not keyword_match:
        keyword_match = ["regulation_hr", "regulation_finance", "regulation_general"]

    return {"selected_partitions": keyword_match}
```

### milvus_search_node + rerank_node

```python
async def milvus_search_node(state: RegulationQAState) -> dict:
    results = await ai_rag.search({
        "query_embedding": state["query_embedding"],
        "collection": "regulation_knowledge",
        "partitions": state["selected_partitions"],
        "top_k": 20,
        "filter": {
            "is_active": True,
            "tenant_id": state["tenant_id"],
        },
        "similarity_threshold": 0.60,
    })
    return {"retrieved_chunks": results}

async def rerank_node(state: RegulationQAState) -> dict:
    reranked = await ai_rag.rerank({
        "query": state["user_query"],
        "documents": state["retrieved_chunks"],
        "top_k": 5,
        "model": "bge-reranker-v2-m3",
    })
    # rerank_score 기준 임계치 필터
    filtered = [c for c in reranked if c["rerank_score"] >= 0.30]
    return {"reranked_chunks": filtered}
```

### generate_answer_node (SSE 스트리밍)

```python
async def generate_answer_node(state: RegulationQAState) -> dict:
    # Context Assembly
    context = build_context(state["reranked_chunks"])

    # 담당 부서 조회 (면책 문구용)
    dept = await get_responsible_dept(
        category=state["reranked_chunks"][0]["category"] if state["reranked_chunks"] else "GENERAL"
    )

    full_answer = ""
    async for chunk in llm_client.chat_completions_stream(
        model="coder",
        messages=[
            {"role": "system", "content": REGULATION_QA_SYSTEM},
            {"role": "user", "content": QA_USER_TEMPLATE.format(
                retrieved_contexts=context,
                question=state["user_query"],
                responsible_dept=dept,
            )}
        ],
        max_tokens=800,
        temperature=0.1,
    ):
        full_answer += chunk
        await state["sse_writer"].send({"event": "answer.chunk", "data": chunk})

    # Citations 추출
    citations = extract_citations(full_answer, state["reranked_chunks"])

    return {
        "answer_text": full_answer,
        "citations": citations,
    }
```

## 5. 캐싱 전략

```python
def build_cache_key(state: RegulationQAState) -> str:
    query_hash = hashlib.md5(state["user_query"].encode()).hexdigest()[:12]
    return f"qa:{state['tenant_id']}:{query_hash}"

async def check_cache_node(state: RegulationQAState) -> dict:
    key = build_cache_key(state)
    cached = await redis.get(key)
    if cached:
        return {
            "cache_key": key,
            "cache_hit": True,
            "answer_text": cached["answer"],
            "citations": cached["citations"],
        }
    return {"cache_key": key, "cache_hit": False}

async def save_cache_node(state: RegulationQAState) -> dict:
    # 품질 점수 80+ 응답만 캐싱 (저품질 캐싱 방지)
    if state["quality_score"] >= 80:
        await redis.setex(
            state["cache_key"],
            86400,  # 24시간
            json.dumps({
                "answer": state["answer_text"],
                "citations": state["citations"],
            })
        )
    return {}
```

## 6. 품질 자동 평가

```python
def evaluate_quality(state) -> int:
    score = 0
    # 1. 근거 조항 포함 (0~40)
    if re.search(r'제\d+조', state["answer_text"]):
        score += 40
    # 2. 면책 문구 포함 (0~20)
    if "참고용" in state["answer_text"] or "담당 부서" in state["answer_text"]:
        score += 20
    # 3. 검색된 조항 언급 (0~20)
    mentioned = sum(1 for c in state["reranked_chunks"] if c["article_no"] in state["answer_text"])
    score += min(20, mentioned * 5)
    # 4. 답변 길이 적정 (0~20)
    if 100 <= len(state["answer_text"]) <= 800:
        score += 20
    return score
```

## 7. 성능 SLO

| SLI | SLO |
|-----|:---:|
| RAG 검색 응답 | ≤ 3초 |
| 전체 Q&A 응답 | ≤ 5초 (SSE 첫 토큰) |
| 답변 정확도 (전문가 평가) | ≥ 85% |
| 조항 번호 포함률 | ≥ 90% |
| 캐시 적중 시 응답 | ≤ 500ms |
