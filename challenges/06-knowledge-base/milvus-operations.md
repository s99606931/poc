# Milvus 운영 가이드

## 1. 컬렉션 초기화

```python
from pymilvus import connections, FieldSchema, CollectionSchema, Collection, DataType

connections.connect(host="milvus", port="19530")

# 스키마 정의 → ../04-regulation-qa/milvus-schema.md 참조
schema = CollectionSchema(fields, description="행정 규정 지식 베이스")
collection = Collection("regulation_knowledge", schema)

# 파티션 생성
for p in ["regulation_hr", "regulation_finance", "regulation_general",
          "regulation_forms", "qa_history"]:
    collection.create_partition(p)

# 인덱스 생성
collection.create_index(
    field_name="embedding",
    index_params={
        "index_type": "IVF_FLAT",
        "metric_type": "IP",
        "params": {"nlist": 256},
    }
)

collection.load()
```

## 2. 규정 버전 업데이트

```python
# 신규 버전 삽입 + 기존 비활성화
async def update_regulation(regulation_id: str, new_version: str):
    # 1. 기존 버전 비활성화
    collection.upsert({
        "regulation_id": regulation_id,
        "is_active": False,
        "effective_to": datetime.now().strftime("%Y-%m-%d"),
    })

    # 2. 신규 버전 업로드 (bulk_upload 사용)
    await bulk_upload(new_version_file, version=new_version, is_active=True)

    # 3. Redis 캐시 무효화
    await redis.delete_pattern(f"qa:*:{regulation_id}:*")
```

## 3. 파티션 통계

```python
def get_stats():
    stats = {}
    for p in collection.partitions:
        stats[p.name] = {
            "entities": p.num_entities,
            "is_empty": p.is_empty,
        }
    return stats

# 출력 예시:
# {
#   "regulation_hr":       {"entities": 342, "is_empty": False},
#   "regulation_finance":  {"entities": 287, "is_empty": False},
#   "regulation_general":  {"entities": 156, "is_empty": False},
#   "regulation_forms":    {"entities": 45,  "is_empty": False},
#   "qa_history":          {"entities": 0,   "is_empty": True}
# }
```

## 4. 백업 / 복구

```bash
# Milvus etcd + MinIO 백업
docker exec milvus-standalone backup \
  --collection regulation_knowledge \
  --output /backup/$(date +%Y%m%d).tar.gz

# 복구
docker exec milvus-standalone restore \
  --input /backup/20260421.tar.gz
```

## 5. 용량 예측

```
단일 청크 크기:
- Vector (1024 × 4 bytes):    4 KB
- Sparse vector:               ~2 KB (가변)
- 메타 JSON:                   ~1 KB
- 합계:                        ~7 KB/청크

규정 10종 × 평균 50 조 × 항 단위 2개 = 1,000 청크
총 용량: ~7 MB (여유 포함 100 MB 예약)

본 사업 규모 (1,000종 × 50 조 × 2항) = 100,000 청크 → ~700 MB
```

## 6. 모니터링 메트릭

| 메트릭 | 경고 임계치 |
|--------|:---------:|
| 컬렉션 entities | 10,000건 초과 시 로드 시간 ↑ |
| 검색 latency P99 | > 500ms |
| IVF nlist | entities / 100 이상이면 재인덱싱 |
