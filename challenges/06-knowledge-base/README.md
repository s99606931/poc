# 과제 6 — 지식 베이스 구축 구현 가이드

> **작성일**: 2026-04-21 | **기간**: 1.5주 | **재사용률**: 97%

## 1. 개요

규정 10종 → 청킹 → 임베딩 → Milvus 저장. **POC 2의 전제**.

🔴 **P0-2 필수**: 10종 규정 문서 제공 여부.

## 2. 폴더 구성

| 파일 | 내용 |
|------|------|
| README.md | 본 문서 |
| [external-dependencies.md](external-dependencies.md) | 규정 수집·포맷·보안 |
| [chunking-strategy.md](chunking-strategy.md) | 조 단위 청킹 로직 |
| [ingestion-pipeline.md](ingestion-pipeline.md) | OCR → 청킹 → 임베딩 → Milvus |
| [milvus-operations.md](milvus-operations.md) | 파티션 관리·버전 업데이트 |
| [qa-history-collection.md](qa-history-collection.md) | Q&A 이력 자동 수집 |

## 3. 실행 스크립트

```bash
# 1. HWP → PDF 변환 (libreoffice)
libreoffice --headless --convert-to pdf *.hwp

# 2. ai-rag upload 일괄 호출
python scripts/bulk_upload_regulations.py \
  --partition regulation_hr \
  --files ./pdfs/복무규정_v2.3.pdf ./pdfs/연가지침_v1.5.pdf ./pdfs/출장규정_v3.0.pdf

# 3. 품질 검증 (20 테스트 쿼리)
python scripts/evaluate_retrieval.py --partition regulation_hr --queries ./test_queries.json
```

## 4. 관련 문서

- [../04-regulation-qa/milvus-schema.md](../04-regulation-qa/milvus-schema.md) — Milvus 컬렉션 스키마
- [../../services/improvements/ai-rag.md](../../services/improvements/ai-rag.md)
- [../../services/improvements/hwp-rag-pipeline.md](../../services/improvements/hwp-rag-pipeline.md)
