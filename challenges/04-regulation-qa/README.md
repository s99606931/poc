# 과제 4 — 규정 Q&A 서비스 구현 가이드

> **작성일**: 2026-04-21 | **기간**: 1.5주 | **재사용률**: 95%
> **과제 문서**: [../04-regulation-qa.md](../04-regulation-qa.md)

---

## 1. 개요

"연가 신청은 며칠 전까지 해야 하나요?" 같은 규정 질문에 RAG로 조항 근거와 함께 답변.

**흐름**: `chat-web → chat-api → ai-assistant (regulation_qa 모드) → ai-rag (Milvus 검색) → Gemma-4 답변 생성 → SSE`

---

## 2. 외부 의존성

| 시스템 | 비고 |
|--------|------|
| **Milvus 벡터 DB** | 규정 컬렉션 (과제 6에서 구축) |
| **BGE-M3** | 임베딩 (ai-llm 내부) |
| **bge-reranker-v2-m3** | 재순위 |
| **Gemma-4 31B AWQ** | 답변 생성 |

🔴 **P0-2 규정 문서 10종** — [상세](../15-per-challenge-decision-points.md#-d6-02-미확정-시-영향--poc-2-전체-지연-사유)

---

## 3. 폴더 구성

| 파일 | 내용 |
|------|------|
| README.md | 본 문서 |
| [external-dependencies.md](external-dependencies.md) | 규정 문서 요건 |
| [milvus-schema.md](milvus-schema.md) | 규정 컬렉션 + 파티션 설계 |
| [rag-pipeline.md](rag-pipeline.md) | RAG 검색·리랭킹·답변 흐름 |
| [api-samples.json](api-samples.json) | Q&A 요청/응답 샘플 |
| [prompt-templates.md](prompt-templates.md) | 규정 Q&A 시스템 프롬프트 |

---

## 4. 고객 결정 포인트

[../15-per-challenge-decision-points.md#-과제-4--규정-qa-서비스-대화형-rag](../15-per-challenge-decision-points.md) (8개)

핵심:
- D4-01 답변 범위 (조항만 / 해석 포함)
- D4-02 면책 문구 정책
- D4-07 피드백 수집 방식
