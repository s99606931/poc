# 청킹 전략

## 1. 조(Article) 단위 (규정 문서 기본)

```python
import re

ARTICLE_PATTERN = re.compile(
    r'(제\s*\d+\s*조(?:\s*의\s*\d+)?(?:\s*\([^)]+\))?)'
)

def chunk_by_article(text: str, metadata: dict) -> list[dict]:
    parts = ARTICLE_PATTERN.split(text)
    chunks = []
    for i in range(1, len(parts), 2):
        header = parts[i]
        body = parts[i + 1] if i + 1 < len(parts) else ""

        # 조 전체 텍스트
        full_text = f"{header} {body}".strip()

        # 너무 긴 조는 항 단위 재분할
        if len(full_text) > 1500:
            sub_chunks = chunk_by_paragraph(header, body, metadata)
            chunks.extend(sub_chunks)
        else:
            chunks.append({
                "content": full_text,
                "article_no": header,
                **metadata,
            })
    return chunks
```

## 2. 항(Paragraph) 단위 (장문 조)

```python
PARAGRAPH_PATTERN = re.compile(r'([①②③④⑤⑥⑦⑧⑨⑩])')

def chunk_by_paragraph(article_header, body, metadata):
    parts = PARAGRAPH_PATTERN.split(body)
    chunks = [{
        "content": f"{article_header} (개요) {parts[0][:200]}",
        "article_no": article_header,
        "paragraph_no": None,
        **metadata,
    }]
    for i in range(1, len(parts), 2):
        para_no = parts[i]
        para_body = parts[i + 1] if i + 1 < len(parts) else ""
        chunks.append({
            "content": f"{article_header}{para_no} {para_body}".strip(),
            "article_no": article_header,
            "paragraph_no": para_no,
            **metadata,
        })
    return chunks
```

## 3. 서식/양식 (비규정 문서)

```python
def chunk_by_section(text, max_chunk_size=1000):
    """섹션 헤더(##, ###) 기준 분할, 크기 초과 시 문단 단위로"""
    sections = re.split(r'\n##+ ', text)
    chunks = []
    for section in sections:
        if len(section) <= max_chunk_size:
            chunks.append(section)
        else:
            # 문단 단위로 재분할 (overlap 50자)
            chunks.extend(split_with_overlap(section, max_chunk_size, overlap=50))
    return chunks
```

## 4. 메타데이터

```python
{
    "regulation_id": "REG-HR-001",
    "regulation_name": "복무규정",
    "article_no": "제12조",
    "article_title": "연가의 신청",
    "paragraph_no": "제2항",
    "category": "HR",                  # HR | FINANCE | GENERAL | FORMS
    "doc_types": ["휴가신청"],
    "version": "v2.3",
    "effective_from": "2024-01-01",
    "effective_to": null,
    "is_active": true,
    "source_file": "복무규정_v2.3.pdf",
    "page_no": 8,
    "tenant_id": "tenant-001",
}
```

## 5. 품질 검증

```python
def validate_chunks(chunks):
    """청킹 품질 검사"""
    issues = []

    for c in chunks:
        # 너무 짧은 청크
        if len(c["content"]) < 50:
            issues.append({"chunk_id": c.get("chunk_id"), "issue": "too_short"})

        # 조 번호 누락
        if not c.get("article_no") and c.get("category") != "FORMS":
            issues.append({"chunk_id": c.get("chunk_id"), "issue": "no_article_no"})

        # 메타 누락
        required = ["regulation_id", "regulation_name", "category", "is_active"]
        if any(not c.get(k) for k in required):
            issues.append({"chunk_id": c.get("chunk_id"), "issue": "missing_meta"})

    return issues
```
