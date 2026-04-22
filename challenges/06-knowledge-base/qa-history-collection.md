# Q&A 이력 자동 수집

## 1. 수집 조건 (고객 결정 D6-06)

```python
QA_COLLECTION_RULES = {
    "min_rating": 4,              # 평점 4/5 이상만
    "require_manual_review": True, # 수동 검증 후 저장
    "collection_schedule": "daily",  # 일배치
    "max_collected_per_day": 20,
}
```

## 2. 데이터 흐름

```
사용자 Q&A 답변 만족도 평가 (chat-web)
  → chat-api 저장 (PostgreSQL qa_feedback 테이블)
  → 일배치 (APScheduler 매일 02:00)
  → 평점 4/5 이상 + 수동 검토 대기 큐
  → 지식 관리자 검토 (admin-web /admin/qa-history/pending)
  → 승인 → Milvus qa_history 파티션 삽입
```

## 3. PostgreSQL 스키마

```sql
CREATE TABLE qa_feedback (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      VARCHAR(100) NOT NULL,
    emp_cd          VARCHAR(50),
    question        TEXT NOT NULL,
    answer          TEXT NOT NULL,
    retrieved_refs  JSONB,             -- [{regulation_name, article_no}, ...]
    rating          INTEGER,            -- 1~5
    comment         TEXT,
    is_approved     BOOLEAN DEFAULT FALSE,
    approved_by     VARCHAR(50),
    approved_at     TIMESTAMPTZ,
    milvus_chunk_id VARCHAR(100),       -- 저장 후 Milvus ID
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    tenant_id       VARCHAR(100) NOT NULL
);
CREATE INDEX idx_qa_feedback_rating ON qa_feedback(rating, is_approved);
```

## 4. 승인 UI (admin-web 확장)

```
/admin/qa-history/pending
- 평점 4/5 이상 미승인 Q&A 목록
- 각 항목: 질문 + 답변 + 원본 규정 링크
- [승인] [거부] 버튼
- 승인 시 Milvus qa_history 파티션에 upsert
```

## 5. 승인 로직

```python
async def approve_qa(feedback_id: str, approver_emp_cd: str):
    feedback = await db.get(QaFeedback, feedback_id)

    # Milvus 삽입
    chunk = {
        "chunk_id": f"QA-{feedback.id}",
        "regulation_id": "QA-HISTORY",
        "regulation_name": "Q&A 이력",
        "article_no": f"QA-{feedback.id}",
        "content": f"Q: {feedback.question}\nA: {feedback.answer}",
        "category": "QA",
        "embedding": await embed(feedback.question + " " + feedback.answer),
        "tenant_id": feedback.tenant_id,
        "is_active": True,
    }
    await milvus_insert("regulation_knowledge", "qa_history", chunk)

    # DB 업데이트
    feedback.is_approved = True
    feedback.approved_by = approver_emp_cd
    feedback.approved_at = datetime.now()
    feedback.milvus_chunk_id = chunk["chunk_id"]
    await db.save(feedback)
```

## 6. 개인정보 마스킹

저장 전 자동 처리:
```python
def mask_personal_info(text: str) -> str:
    # 이름: 홍길동 → 홍*동
    text = re.sub(r'([가-힣])[가-힣]([가-힣])', r'\1*\2', text)
    # 주민번호: 900101-1234567 → 900101-*******
    text = re.sub(r'(\d{6})-\d{7}', r'\1-*******', text)
    # 휴대폰: 010-1234-5678 → 010-****-5678
    text = re.sub(r'(\d{3})-\d{4}-(\d{4})', r'\1-****-\2', text)
    # 이메일: hong@agency.go.kr → h***@agency.go.kr
    text = re.sub(r'(\w)[\w.]+@', r'\1***@', text)
    return text
```
