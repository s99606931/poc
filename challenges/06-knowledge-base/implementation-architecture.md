# 과제 6 지식 베이스 — 구현 아키텍처

> **연관**: [test-scenarios.md](test-scenarios.md) | [ingestion-pipeline.md](ingestion-pipeline.md)

---

## 1. 컴포넌트 계층

```
Input:    admin-web /admin/documents 업로드 (관리자) or CLI bulk_upload
API:      admin-api regulation 모듈 (POST /regulations/upload)
RAG:      ai-rag upload_router (재사용, 신규 개발 없음)
OCR:      ocr-service (PP-OCRv5)
Convert:  libreoffice (HWP → PDF)
Chunking: ai-rag 내부 services/regulation_chunking.py (신규)
Embed:    BGE-M3 (ai-llm)
Storage:  Milvus regulation_knowledge (5 파티션)
Meta:     PostgreSQL regulations 테이블 (버전 관리)
```

## 2. 업로드 파이프라인 상세

```mermaid
flowchart TD
    A["규정 파일 업로드<br/>HWP/PDF/DOCX"] --> B{"파일 유형"}
    B -->|HWP| C1["libreoffice 변환<br/>HWP → PDF"]
    B -->|PDF| C2["파싱 방식 결정"]
    B -->|DOCX| C3["python-docx 직접 파싱"]

    C2 --> D{"텍스트 레이어?"}
    D -->|있음| E1["pdfplumber 추출"]
    D -->|없음 (스캔)| E2["PP-OCRv5 OCR"]

    C1 --> C2
    C3 --> F["텍스트 전처리<br/>정규화"]
    E1 --> F
    E2 --> F

    F --> G["조 단위 청킹<br/>chunk_by_article"]
    G --> H{"청크 크기"}
    H -->|≤ 1500| I["청크 유지"]
    H -->|> 1500| J["항 단위 재분할<br/>chunk_by_paragraph"]

    I --> K["메타데이터 부여<br/>{reg_id, article, version, ...}"]
    J --> K

    K --> L["BGE-M3 임베딩<br/>batch=32"]
    L --> M["Milvus 저장<br/>파티션별"]
    M --> N["PostgreSQL<br/>regulations 테이블 기록"]
    N --> O["품질 검증 (20 쿼리)"]
    O --> P{"Top-5 ≥ 85%?"}
    P -->|No| Q["청킹 튜닝 반복"]
    P -->|Yes| R["완료"]
```

## 3. 주요 클래스

### RegulationIngestionService

```python
# apps/ai-rag/src/services/regulation_ingestion.py

class RegulationIngestionService:
    def __init__(self,
                 ocr_client: OCRClient,
                 embedding_client: EmbeddingClient,
                 milvus_client: MilvusClient,
                 db_session: AsyncSession):
        self.ocr = ocr_client
        self.embedding = embedding_client
        self.milvus = milvus_client
        self.db = db_session

    async def ingest(self, file: UploadFile, metadata: RegulationMetadata) -> IngestionResult:
        # 1. 파일 변환
        pdf_path = await self._ensure_pdf(file)

        # 2. 텍스트 추출
        text = await self._extract_text(pdf_path)

        # 3. 청킹
        chunks = chunk_by_article(text, metadata=metadata.dict())
        chunks = self._validate_chunks(chunks)

        # 4. 임베딩
        embeddings = await self.embedding.embed_batch(
            [c["content"] for c in chunks],
            batch_size=32
        )

        # 5. Milvus 저장
        for chunk, emb in zip(chunks, embeddings):
            chunk["embedding"] = emb
        await self.milvus.insert(
            collection="regulation_knowledge",
            partition=metadata.partition,
            entities=chunks
        )

        # 6. 메타 DB 기록
        await self.db.execute(insert(Regulation).values(
            regulation_id=metadata.regulation_id,
            regulation_name=metadata.regulation_name,
            version=metadata.version,
            effective_from=metadata.effective_from,
            chunks_count=len(chunks),
            file_hash=compute_hash(pdf_path),
            uploaded_by=metadata.uploaded_by,
        ))

        return IngestionResult(
            regulation_id=metadata.regulation_id,
            chunks_count=len(chunks),
            partition=metadata.partition,
        )
```

### RegulationChunker (조 단위 특화)

```python
# apps/ai-rag/src/services/regulation_chunking.py

import re
from typing import Iterator

ARTICLE_PATTERN = re.compile(r'(제\s*\d+\s*조(?:\s*의\s*\d+)?(?:\s*\([^)]+\))?)')
PARAGRAPH_PATTERN = re.compile(r'([①②③④⑤⑥⑦⑧⑨⑩])')
MAX_CHUNK_SIZE = 1500

def chunk_by_article(text: str, metadata: dict) -> list[dict]:
    """
    규정 문서를 조(Article) 단위로 청킹.
    조가 너무 길면 항 단위로 재분할.
    """
    parts = ARTICLE_PATTERN.split(text)
    chunks = []

    for i in range(1, len(parts), 2):
        article_header = parts[i].strip()
        body = parts[i + 1] if i + 1 < len(parts) else ""
        full_article = f"{article_header} {body}".strip()

        if len(full_article) <= MAX_CHUNK_SIZE:
            chunks.append({
                "chunk_id": f"{metadata['regulation_id']}-{_sanitize_article(article_header)}",
                "content": full_article,
                "article_no": article_header,
                "paragraph_no": None,
                **metadata,
            })
        else:
            # 항 단위 재분할
            chunks.extend(chunk_by_paragraph(article_header, body, metadata))

    return chunks

def chunk_by_paragraph(article_header: str, body: str, metadata: dict) -> list[dict]:
    parts = PARAGRAPH_PATTERN.split(body)
    chunks = [{
        "chunk_id": f"{metadata['regulation_id']}-{_sanitize_article(article_header)}-intro",
        "content": f"{article_header} (개요) {parts[0][:200]}",
        "article_no": article_header,
        "paragraph_no": None,
        **metadata,
    }]

    for i in range(1, len(parts), 2):
        para_no = parts[i]
        para_body = parts[i + 1] if i + 1 < len(parts) else ""
        chunks.append({
            "chunk_id": f"{metadata['regulation_id']}-{_sanitize_article(article_header)}-{para_no}",
            "content": f"{article_header}{para_no} {para_body}".strip(),
            "article_no": article_header,
            "paragraph_no": para_no,
            **metadata,
        })
    return chunks
```

## 4. 규정 버전 관리

```python
async def update_regulation(regulation_id: str, new_version_file: UploadFile, new_metadata: dict):
    """기존 버전 비활성화 + 신규 버전 업로드"""

    # 1. 기존 버전 비활성화
    await milvus.update(
        collection="regulation_knowledge",
        filter=f"regulation_id == '{regulation_id}'",
        data={"is_active": False, "effective_to": datetime.now().strftime("%Y-%m-%d")}
    )

    # 2. 신규 버전 업로드
    result = await ingestion_service.ingest(new_version_file, new_metadata)

    # 3. Redis 캐시 무효화
    await redis.delete_pattern(f"qa:*:{regulation_id}:*")
    await redis.delete_pattern(f"qa:*:partition:{new_metadata['partition']}:*")

    # 4. 감사 로그
    await alli_audit.create(
        category="regulation_update",
        severity="GREEN",
        title=f"규정 개정: {new_metadata['regulation_name']} → {new_metadata['version']}",
        body=f"이전 청크 {old_count}개 비활성화, 신규 {result.chunks_count}개 추가"
    )
```

## 5. 품질 검증 파이프라인

```python
async def evaluate_ingestion(regulation_id: str, test_queries: list[dict]) -> QualityReport:
    """
    업로드 직후 품질 자동 평가.
    test_queries: [{query, expected_article, partition}]
    """
    results = {"total": 0, "top1_hit": 0, "top5_hit": 0, "misses": []}

    for tq in test_queries:
        search_result = await ai_rag.search(
            query=tq["query"],
            partitions=[tq["partition"]],
            top_k=5
        )
        results["total"] += 1

        top5_articles = [r["metadata"]["article_no"] for r in search_result]
        if tq["expected_article"] in top5_articles[:1]:
            results["top1_hit"] += 1
        if tq["expected_article"] in top5_articles:
            results["top5_hit"] += 1
        else:
            results["misses"].append({
                "query": tq["query"],
                "expected": tq["expected_article"],
                "got": top5_articles
            })

    return QualityReport(
        regulation_id=regulation_id,
        top1_accuracy=results["top1_hit"] / results["total"],
        top5_accuracy=results["top5_hit"] / results["total"],
        misses=results["misses"],
        passed=results["top5_hit"] / results["total"] >= 0.85
    )
```

## 6. Q&A 이력 자동 수집

```python
# chat-api에서 사용자 피드백 수신 시
async def collect_qa_feedback(feedback: QaFeedback):
    # 1. PostgreSQL 저장
    await db.insert(QaFeedback, feedback)

    # 2. 평점 4 이상 + 승인 대기 큐
    if feedback.rating >= 4:
        await admin_api.create_review_task({
            "type": "QA_APPROVAL",
            "feedback_id": feedback.id,
            "assignee": "knowledge_manager",
        })

# 지식 관리자 승인 시
async def approve_qa(feedback_id: str):
    fb = await db.get(QaFeedback, feedback_id)

    # Milvus qa_history 파티션에 저장
    chunk = {
        "chunk_id": f"QA-{fb.id}",
        "content": f"Q: {mask_pii(fb.question)}\nA: {mask_pii(fb.answer)}",
        "category": "QA",
        "embedding": await embedding.embed(fb.question + " " + fb.answer),
        "is_active": True,
    }
    await milvus.insert("regulation_knowledge", "qa_history", chunk)

    fb.is_approved = True
    await db.save(fb)
```

## 7. 성능 SLO

| SLI | SLO |
|-----|:---:|
| 10종 규정 일괄 업로드 | ≤ 30분 |
| 단일 규정 업로드 (조 100개) | ≤ 3분 |
| 청킹 성공률 | ≥ 95% |
| Top-5 검색 정확도 | ≥ 85% |
| Milvus 저장 용량 | ≤ 100 MB (10종) |
