# 과제 5 — 문서 적합성 검점 구현 가이드

> **작성일**: 2026-04-21 | **기간**: 1.5주 | **재사용률**: 95%
> **과제 문서**: [../05-document-compliance.md](../05-document-compliance.md)

---

## 1. 개요

기안문·보고서·공문 PDF 업로드 → OCR → 규정 검색 → 조항별 위반 평가 → 수정 제안.
**구현 위치**: `ai-assistant/src/graph/graphs/compliance_graph.py` (통합, 별도 서비스 아님)

### 흐름

```
admin-web 업로드 → admin-api/compliance → ai-assistant compliance_graph
  ├─ ocr_extract (ocr-service)
  ├─ classify_doc_type (LLM)
  ├─ fetch_regulations (ai-rag, RAG 모드)
  ├─ candidate_extraction_node (재사용)
  ├─ evidence_assess_node (재사용, 핵심)
  ├─ generate_suggestions
  └─ violation_formatter
```

---

## 2. 외부 의존성

| 시스템 | 상태 |
|--------|:---:|
| ocr-service (PP-OCRv5) | ✅ |
| ai-rag + Milvus (규정) | ✅ (과제 6 완료 전제) |
| Gemma-4 31B AWQ | ✅ |
| ai-assistant (compliance_graph) | 신규 추가 |
| admin-api compliance 모듈 | 신규 추가 |

---

## 3. 폴더 구성

| 파일 | 내용 |
|------|------|
| README.md | 본 문서 |
| [external-dependencies.md](external-dependencies.md) | 외부 의존성 |
| [compliance-graph-spec.md](compliance-graph-spec.md) | LangGraph 그래프 상세 |
| [violation-rules.md](violation-rules.md) | 위반 항목 분류·감점 기준 |
| [api-samples.json](api-samples.json) | 업로드 → 결과 샘플 |
| [db-schemas.sql](db-schemas.sql) | alli-audit compliance_check 저장 |

---

## 4. 고객 결정 포인트

[../decisions.md#-과제-5--문서-적합성-검점](../decisions.md) (8개)

핵심:
- D5-03 점검 결과 활용 (참고/차단/경고)
- D5-02 위반 판정 수준 (엄격/균형/관대)
