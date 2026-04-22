# compliance_graph 상세 스펙

## 1. 파일 위치

`apps/ai-assistant/src/graph/graphs/compliance_graph.py`

## 2. 노드 구성

| 노드 | 신규/재사용 | 역할 |
|------|:---------:|------|
| `ocr_extract_node` | 신규 | ocr-service 호출 (PDF/Image) |
| `classify_node` | 재사용 | 문서 유형 분류 (LLM) |
| `fetch_node` | 재사용 | ai-rag 규정 검색 (RAG 모드) |
| `candidate_extraction_node` | 재사용 | 위반 후보 추출 |
| `evidence_assess_node` | 재사용 | 조항별 위반 판정 (핵심) |
| `generate_node` | 재사용 | 수정 제안 생성 |
| `violation_formatter_node` | 신규 | JSON 결과 포맷 + 점수 계산 |

## 3. ComplianceState 스키마

```python
@dataclass
class ComplianceState:
    # Input
    file_bytes: bytes
    file_type: str                    # pdf | docx | hwp | xlsx
    tenant_id: str
    doc_type_hint: str | None

    # Intermediate
    extracted_text: str = ""
    page_count: int = 0
    doc_type: str = ""
    doc_type_confidence: float = 0.0
    related_regulations: list = field(default_factory=list)
    violation_candidates: list = field(default_factory=list)
    violations: list = field(default_factory=list)
    suggestions: list = field(default_factory=list)

    # Output
    is_compliant: bool = True
    score: int = 100
    grade: str = "A"
```

## 4. 흐름 구성

```python
def build_compliance_graph():
    g = StateGraph(ComplianceState)

    g.add_node("ocr_extract",          ocr_extract_node)
    g.add_node("classify",             classify_node)
    g.add_node("fetch_regulations",    fetch_node)
    g.add_node("extract_candidates",   candidate_extraction_node)
    g.add_node("assess_evidence",      evidence_assess_node)
    g.add_node("generate_suggestions", generate_node)
    g.add_node("format_result",        violation_formatter_node)

    g.set_entry_point("ocr_extract")
    g.add_edge("ocr_extract",          "classify")
    g.add_edge("classify",             "fetch_regulations")
    g.add_edge("fetch_regulations",    "extract_candidates")
    g.add_edge("extract_candidates",   "assess_evidence")
    g.add_edge("assess_evidence",      "generate_suggestions")
    g.add_edge("generate_suggestions", "format_result")
    g.add_edge("format_result",        END)

    return g.compile()
```

## 5. 파티션 자동 선택

```python
DOC_TYPE_TO_PARTITIONS = {
    "품의서":     ["regulation_finance", "regulation_general"],
    "계약서":     ["regulation_finance"],
    "공문서":     ["regulation_general"],
    "출장명령서": ["regulation_hr", "regulation_finance"],
    "회의록":     ["regulation_general"],
    "입찰공고":   ["regulation_finance"],
    "기안문":     ["regulation_general", "regulation_finance"],
}
```

## 6. 성능 목표

| 지표 | 목표 |
|------|:---:|
| 10페이지 이하 점검 | ≤ 30초 |
| 50페이지 이하 점검 | ≤ 120초 |
| OCR 정확도 | ≥ 95% (일반), ≥ 85% (스캔본) |
| 위반 탐지 정밀도 | ≥ 70% |
| 위반 탐지 재현율 | ≥ 80% |
