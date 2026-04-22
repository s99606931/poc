# Milvus 규정 지식 베이스 스키마

## 1. 컬렉션: `regulation_knowledge`

### 1.1 필드 정의

```python
from pymilvus import FieldSchema, CollectionSchema, DataType

fields = [
    FieldSchema("chunk_id",          DataType.VARCHAR, max_length=100, is_primary=True),
    # 메타
    FieldSchema("regulation_id",     DataType.VARCHAR, max_length=100),  # "REG-HR-001"
    FieldSchema("regulation_name",   DataType.VARCHAR, max_length=500),  # "복무규정"
    FieldSchema("article_no",        DataType.VARCHAR, max_length=50),   # "제12조"
    FieldSchema("article_title",     DataType.VARCHAR, max_length=500),  # "연가 신청"
    FieldSchema("paragraph_no",      DataType.VARCHAR, max_length=20),   # "제2항"
    FieldSchema("content",           DataType.VARCHAR, max_length=5000),
    # 분류
    FieldSchema("category",          DataType.VARCHAR, max_length=50),   # "HR"
    FieldSchema("doc_types",         DataType.ARRAY,   element_type=DataType.VARCHAR, max_capacity=10),
    # 버전 관리
    FieldSchema("version",           DataType.VARCHAR, max_length=20),   # "v2.3"
    FieldSchema("effective_from",    DataType.VARCHAR, max_length=20),   # "2024-01-01"
    FieldSchema("effective_to",      DataType.VARCHAR, max_length=20),   # "" or "2026-06-30"
    FieldSchema("is_active",         DataType.BOOL),
    # 출처
    FieldSchema("source_file",       DataType.VARCHAR, max_length=500),  # "복무규정_v2.3.pdf"
    FieldSchema("page_no",           DataType.INT32),
    # 벡터
    FieldSchema("embedding",         DataType.FLOAT_VECTOR, dim=1024),  # BGE-M3
    FieldSchema("sparse_embedding",  DataType.SPARSE_FLOAT_VECTOR),      # BGE-M3 sparse (선택)
    # 테넌트
    FieldSchema("tenant_id",         DataType.VARCHAR, max_length=100),
]

schema = CollectionSchema(fields, description="행정 규정 지식 베이스")
```

### 1.2 파티션 설계

```python
PARTITIONS = {
    "regulation_hr":       "인사/복무 규정",
    "regulation_finance":  "회계/예산 규정",
    "regulation_general":  "일반 행정 규정",
    "regulation_forms":    "서식/양식",
    "qa_history":          "우수 Q&A 이력 (평점 4/5+)",
}
```

### 1.3 인덱스

```python
collection.create_index(
    field_name="embedding",
    index_params={
        "index_type": "IVF_FLAT",    # 또는 HNSW (대규모 시)
        "metric_type": "IP",          # Inner Product (정규화된 임베딩)
        "params": {"nlist": 256},
    }
)

# Scalar 인덱스 (필터링 가속)
collection.create_index(field_name="category")
collection.create_index(field_name="is_active")
collection.create_index(field_name="tenant_id")
```

---

## 2. 샘플 데이터

```json
{
  "chunk_id": "REG-HR-001-art12-p2",
  "regulation_id": "REG-HR-001",
  "regulation_name": "복무규정",
  "article_no": "제12조",
  "article_title": "연가의 신청",
  "paragraph_no": "제2항",
  "content": "제12조(연가의 신청) ① 연가를 사용하고자 하는 공무원은 소속 기관의 장에게 신청하여야 한다. ② 연가의 신청은 사용하고자 하는 날의 최소 3일 전까지 신청함을 원칙으로 한다. 다만, 긴급한 사유가 있는 경우에는 그러하지 아니하다.",
  "category": "HR",
  "doc_types": ["휴가신청", "인사"],
  "version": "v2.3",
  "effective_from": "2024-01-01",
  "effective_to": "",
  "is_active": true,
  "source_file": "복무규정_v2.3.pdf",
  "page_no": 8,
  "embedding": [0.123, -0.456, ...],
  "tenant_id": "tenant-001"
}
```

---

## 3. 청킹 전략

### 3.1 조(Article) 단위 (기본)

```python
import re

def chunk_by_article(text: str, metadata: dict) -> list:
    """규정 본문을 조 단위로 청킹"""
    pattern = re.compile(r'(제\s*\d+\s*조(?:\s*의\s*\d+)?(?:\s*\([^)]+\))?)')
    parts = pattern.split(text)

    chunks = []
    for i in range(1, len(parts), 2):
        article_header = parts[i]
        article_body = parts[i+1] if i+1 < len(parts) else ""

        # 조 내부에 항(①②③)이 여러 개면 하위 청킹
        paragraphs = re.split(r'([①②③④⑤⑥⑦⑧⑨⑩])', article_body)

        chunks.append({
            "article_no": article_header,
            "content": f"{article_header} {article_body}".strip(),
            **metadata
        })
    return chunks
```

### 3.2 최대 청크 크기

- 1,500 토큰 이하 (BGE-M3 max 8,192이나 실용적 크기)
- 조가 너무 길면 항 단위 분할
- 표·이미지는 별도 chunk (OCR 텍스트 + reference)

---

## 4. 업로드 파이프라인

```
문서 파일 (HWP/PDF)
  ↓ ocr-service (PaddleOCR) or python-docx
  텍스트 추출
  ↓ chunk_by_article
  청크 리스트
  ↓ BGE-M3 embedding (batch=32)
  벡터 + 메타
  ↓ ai-rag upload_router (/upload POST)
  ↓ Milvus insert (파티션별)
  완료
```

### 업로드 API 호출 예시

```bash
# 기존 ai-rag upload_router 재사용
curl -X POST http://ai-rag:4006/upload \
  -H "X-Tenant-ID: tenant-001" \
  -F "file=@복무규정_v2.3.pdf" \
  -F 'metadata={"regulation_id":"REG-HR-001","category":"HR","version":"v2.3","partition":"regulation_hr"}'
```

---

## 5. 버전 관리

### 규정 개정 시

```
1. 신규 버전 업로드 (version="v2.4", effective_from="2026-07-01")
2. 기존 버전 비활성화 (is_active=false) 또는 effective_to 설정
3. 검색 시 필터: is_active=true AND effective_from <= NOW()

[대안: 이전 버전 보관]
3개월 유예 기간: 두 버전 모두 is_active=true 유지 + "(구규정)" 표시
```
