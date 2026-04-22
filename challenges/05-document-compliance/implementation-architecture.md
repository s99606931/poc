# 과제 5 문서 적합성 — 구현 아키텍처

> **연관**: [test-scenarios.md](test-scenarios.md) | [compliance-graph-spec.md](compliance-graph-spec.md)

---

## 1. 컴포넌트 계층

```
UI:      admin-web /admin/documents (기존 확장)
API:     admin-api compliance 모듈 (신규)
         POST /compliance/check
Orch:    ai-assistant compliance_graph (신규, 7 노드)
OCR:     ocr-service :6014 (PP-OCRv5, GPU 0)
RAG:     ai-rag (기존) 규정 검색
LLM:     vllm-vision (evidence_assess, 핵심)
Storage: alli-audit (compliance_check 카테고리)
```

## 2. ComplianceState

```python
class ComplianceState(TypedDict):
    # Input
    file_bytes: bytes
    file_type: str
    tenant_id: str
    doc_type_hint: str | None

    # Phase 1: OCR
    extracted_text: str
    page_count: int
    ocr_applied: bool

    # Phase 2: Classify
    doc_type: str                  # 품의서|계약서|공문서|...
    doc_type_confidence: float

    # Phase 3: RAG
    related_regulations: list      # Top 10 rerank 결과

    # Phase 4: Candidate extraction
    violation_candidates: list     # [{chunk, suspected_rule, reason}]

    # Phase 5: Evidence assess (핵심)
    violations: list               # 확정 위반 [{rule, detail, severity}]
    compliant_items: list

    # Phase 6: Suggestions
    suggestions: list              # 수정 제안

    # Phase 7: Format
    is_compliant: bool
    score: int                     # 0~100
    grade: str                     # A~F
```

## 3. 그래프 구성

```python
def build_compliance_graph():
    g = StateGraph(ComplianceState)

    g.add_node("ocr_extract",          ocr_extract_node)        # 신규
    g.add_node("classify",             classify_node)           # 재사용
    g.add_node("fetch_regulations",    fetch_node)              # 재사용 (RAG 모드)
    g.add_node("extract_candidates",   candidate_extraction_node) # 재사용
    g.add_node("assess_evidence",      evidence_assess_node)    # 재사용 (핵심)
    g.add_node("generate_suggestions", generate_node)           # 재사용
    g.add_node("format_result",        violation_formatter_node) # 신규

    # 선형 파이프라인
    g.set_entry_point("ocr_extract")
    g.add_edge("ocr_extract", "classify")
    g.add_edge("classify", "fetch_regulations")
    g.add_edge("fetch_regulations", "extract_candidates")
    g.add_edge("extract_candidates", "assess_evidence")
    g.add_edge("assess_evidence", "generate_suggestions")
    g.add_edge("generate_suggestions", "format_result")
    g.add_edge("format_result", END)

    return g.compile()
```

## 4. 핵심 노드 상세

### ocr_extract_node

```python
async def ocr_extract_node(state: ComplianceState) -> dict:
    """ocr-service 호출 (PP-OCRv5 korean)"""
    async with httpx.AsyncClient(timeout=60.0) as client:
        resp = await client.post(
            f"{OCR_SERVICE_URL}/extract",
            files={"file": state["file_bytes"]},
            data={"file_type": state["file_type"]},
        )
    result = resp.json()
    return {
        "extracted_text": result["full_text"],
        "page_count": result["page_count"],
        "ocr_applied": result["ocr_applied"],  # True if scan image
    }
```

### extract_candidates + assess_evidence (핵심 2단계)

```python
async def candidate_extraction_node(state: ComplianceState) -> dict:
    """
    문서 텍스트의 각 섹션을 관련 규정 조항과 매칭
    → 위반 "후보" 추출 (빠른 스크리닝)
    """
    chunks = chunk_document(state["extracted_text"], max_size=500)

    candidates = []
    for chunk in chunks:
        # chunk ↔ regulation 쌍으로 후보 발굴
        for reg in state["related_regulations"]:
            match_score = await llm_quick_match(chunk, reg)  # 빠른 LLM
            if match_score >= 0.50:
                candidates.append({
                    "chunk_text": chunk,
                    "suspected_rule": reg["article_no"],
                    "regulation": reg,
                    "match_score": match_score,
                })
    return {"violation_candidates": candidates}

async def evidence_assess_node(state: ComplianceState) -> dict:
    """
    각 후보에 대해 정밀 평가 (실제 위반인가?)
    → LLM 깊이 있는 추론 (temperature=0.0, JSON)
    """
    violations = []
    compliant = []

    for candidate in state["violation_candidates"]:
        result = await llm_deep_assess(
            chunk=candidate["chunk_text"],
            regulation=candidate["regulation"],
            doc_type=state["doc_type"],
        )
        # result: {is_compliant, confidence, violation_detail, severity}

        if not result["is_compliant"] and result["confidence"] >= 0.80:
            violations.append({
                "regulation_name": candidate["regulation"]["regulation_name"],
                "article_no": candidate["regulation"]["article_no"],
                "violation_detail": result["violation_detail"],
                "severity": result["severity"],
                "confidence": result["confidence"],
                "location": locate_in_document(candidate["chunk_text"], state["extracted_text"]),
                "violation_type": classify_violation(result["violation_detail"]),
            })
        elif result["is_compliant"]:
            compliant.append({
                "regulation_name": candidate["regulation"]["regulation_name"],
                "article_no": candidate["regulation"]["article_no"],
                "score": 100,
            })

    return {"violations": violations, "compliant_items": compliant}
```

### violation_formatter_node

```python
def violation_formatter_node(state: ComplianceState) -> dict:
    """최종 점수 + 등급 계산"""
    score = 100
    for v in state["violations"]:
        penalty = VIOLATION_WEIGHTS.get(v["violation_type"], 10)
        score -= penalty

    score = max(0, min(100, score))
    grade = _score_to_grade(score)

    return {
        "is_compliant": score >= 70,
        "score": score,
        "grade": grade,
    }
```

## 5. 성능 SLO

| SLI | SLO |
|-----|:---:|
| 10페이지 문서 점검 | ≤ 30초 |
| 50페이지 문서 점검 | ≤ 120초 |
| 파일 크기 한도 | 50 MB |
| 동시 처리 | 5건 |
| 위반 탐지 정밀도 (Precision) | ≥ 70% |
| 위반 탐지 재현율 (Recall) | ≥ 80% |
| OCR 정확도 (일반 문서) | ≥ 95% |
| OCR 정확도 (스캔본) | ≥ 85% |
