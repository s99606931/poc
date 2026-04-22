# 업로드 파이프라인

## 1. 전체 흐름

```
[Input] 규정 문서 파일 (HWP/PDF/DOCX)
    ↓
[Step 1] 포맷 변환
    HWP → libreoffice → PDF
    DOCX → python-docx 직접 파싱
    ↓
[Step 2] 텍스트 추출
    PDF (텍스트 레이어) → pdfplumber
    PDF (스캔) → ocr-service (PP-OCRv5)
    ↓
[Step 3] 청킹
    조 단위 + 항 단위 (필요 시)
    ↓
[Step 4] 임베딩
    BGE-M3 (batch=32, max_seq=512)
    ↓
[Step 5] Milvus 저장
    ai-rag POST /upload (파티션 지정)
    ↓
[Step 6] 품질 검증
    테스트 쿼리 20건으로 Top-5 정확도 ≥ 85% 확인
```

## 2. 일괄 업로드 스크립트

```python
# scripts/bulk_upload_regulations.py

import asyncio
import httpx
from pathlib import Path

async def upload_regulation(
    file_path: Path,
    regulation_id: str,
    regulation_name: str,
    partition: str,
    version: str,
    effective_from: str,
    tenant_id: str,
):
    """ai-rag upload_router 호출"""
    async with httpx.AsyncClient(timeout=300.0) as client:
        with open(file_path, "rb") as f:
            resp = await client.post(
                "http://ai-rag:4006/upload",
                files={"file": (file_path.name, f, "application/pdf")},
                data={
                    "metadata_json": json.dumps({
                        "regulation_id": regulation_id,
                        "regulation_name": regulation_name,
                        "partition": partition,
                        "version": version,
                        "effective_from": effective_from,
                        "is_active": True,
                    }),
                    "tenant_id": tenant_id,
                },
            )
            resp.raise_for_status()
            result = resp.json()
    print(f"✅ {regulation_name}: {result['chunks_count']} chunks uploaded")
    return result

async def main():
    regulations = [
        {"file": "복무규정_v2.3.pdf",      "id": "REG-HR-001",  "name": "복무규정",     "partition": "regulation_hr",      "version": "v2.3"},
        {"file": "연가지침_v1.5.pdf",      "id": "REG-HR-002",  "name": "연가지침",     "partition": "regulation_hr",      "version": "v1.5"},
        {"file": "출장규정_v3.0.pdf",      "id": "REG-HR-003",  "name": "출장규정",     "partition": "regulation_hr",      "version": "v3.0"},
        {"file": "예산집행지침_v2.1.pdf",  "id": "REG-FIN-001", "name": "예산집행지침",  "partition": "regulation_finance", "version": "v2.1"},
        # ... 6종 더
    ]

    tasks = [
        upload_regulation(
            Path(f"./pdfs/{r['file']}"),
            r["id"], r["name"], r["partition"], r["version"],
            "2024-01-01", "tenant-001"
        )
        for r in regulations
    ]
    await asyncio.gather(*tasks)

if __name__ == "__main__":
    asyncio.run(main())
```

## 3. 진행률 모니터링

```python
# 업로드 후 Milvus 카운트 확인
from pymilvus import Collection

collection = Collection("regulation_knowledge")
collection.load()

for partition in ["regulation_hr", "regulation_finance", "regulation_general", "regulation_forms"]:
    stats = collection.partition(partition).num_entities
    print(f"{partition}: {stats}건")
```

## 4. 품질 평가 (테스트 쿼리 20개)

```python
# scripts/evaluate_retrieval.py

TEST_QUERIES = [
    {"query": "연가 신청은 며칠 전까지?", "expected_article": "복무규정 제12조", "partition": "regulation_hr"},
    {"query": "출장비 한도 금액은?", "expected_article": "출장규정 제7조", "partition": "regulation_hr"},
    # ... 20건
]

async def evaluate():
    results = {"total": 0, "top1_hit": 0, "top5_hit": 0}
    for t in TEST_QUERIES:
        search_result = await ai_rag_search(t["query"], partition=t["partition"], top_k=5)
        results["total"] += 1
        if t["expected_article"] in search_result[0]["metadata"]["article_no"]:
            results["top1_hit"] += 1
        if any(t["expected_article"] in r["metadata"]["article_no"] for r in search_result):
            results["top5_hit"] += 1

    print(f"Top-1 정확도: {results['top1_hit']}/{results['total']} = {results['top1_hit']/results['total']*100:.1f}%")
    print(f"Top-5 정확도: {results['top5_hit']}/{results['total']} = {results['top5_hit']/results['total']*100:.1f}%")
    # 목표: Top-5 ≥ 85%
```
