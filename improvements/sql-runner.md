# sql-runner 서비스 개선 태스크 (POC 대응)

> **서비스**: `projects/10_alli-work/apps/sql-runner`
> **현재 포트**: 4004
> **기술**: FastAPI + 4개 DB 드라이버 (PostgreSQL, MySQL, Oracle, MSSQL)
> **POC 역할**: 감사 DB 직접 쿼리 실행 (POC 3) + ERP/그룹웨어 DB 조회 지원
> **작성일**: 2026-04-21

> **📌 POC 확장 범위 요약**
> 핵심 작업: **감사 DB 커넥션 추가** (Read-Only 계정) + **감사 전용 집계 쿼리** 구현.
> 과제 7/8에서 erp_expense, erp_travel, corp_card_usage, erp_attendance 테이블 교차 조회.

---

## 현재 상태

```
✅ PostgreSQL 드라이버 (asyncpg)
✅ MySQL 드라이버 (aiomysql)
✅ Oracle 드라이버 (cx_Oracle)
✅ MSSQL 드라이버 (aioodbc)
✅ Read-Only SQL 검증기 (SELECT 만 허용)
✅ 커넥션 풀 관리
✅ 멀티테넌트 DB 설정 분리
❌ 복잡한 JOIN 쿼리 최적화 없음
❌ 감사 전용 집계 쿼리 미지원
❌ 쿼리 결과 스트리밍 없음
❌ 감사 DB 연결 설정 없음
❌ 쿼리 실행 이력 로깅 없음
```

---

## 개선 태스크

### TASK-SQL-01 감사 DB 드라이버 연결 설정

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (POC 3 필수) |
| **예상 공수** | 1일 |
| **담당** | 데이터엔지니어 |

```yaml
# sql-runner/config/connections.yaml
# 감사 DB 연결 설정 (POC 전용)

audit_db:
  type: postgresql          # 감사 DB가 PostgreSQL 기반인 경우
  host: ${AUDIT_DB_HOST}
  port: ${AUDIT_DB_PORT:-5432}
  database: ${AUDIT_DB_NAME}
  user: ${AUDIT_DB_USER}
  password: ${AUDIT_DB_PASSWORD}
  pool_min: 2
  pool_max: 10
  readonly: true            # Read-Only 보장
  schema: public            # 감사 스키마 (기관마다 다를 수 있음)
  connect_timeout: 10
  command_timeout: 60       # 복잡한 집계 쿼리 허용

erp_db:
  type: oracle              # ERP 시스템이 Oracle 기반인 경우
  host: ${ERP_DB_HOST}
  port: ${ERP_DB_PORT:-1521}
  service_name: ${ERP_DB_SERVICE}
  user: ${ERP_DB_USER}
  password: ${ERP_DB_PASSWORD}
  pool_min: 1
  pool_max: 5
  readonly: true
  connect_timeout: 15
  command_timeout: 120      # Oracle 쿼리는 시간이 걸릴 수 있음

groupware_db:
  type: mssql               # 그룹웨어가 MSSQL 기반인 경우
  host: ${GW_DB_HOST}
  port: ${GW_DB_PORT:-1433}
  database: ${GW_DB_NAME}
  user: ${GW_DB_USER}
  password: ${GW_DB_PASSWORD}
  readonly: true
```

```python
# sql-runner/src/config/poc_connections.py
# POC 전용 DB 연결 등록

POC_CONNECTIONS = {
    "audit_db": {
        "alias": "감사 DB",
        "description": "감사 이력, 지출 내역, 법인카드 사용 데이터",
        "allowed_schemas": ["public", "audit"],
        "allowed_tables": [
            "approval_history",
            "expenditure",
            "corp_card_usage",
            "business_trip",
            "attendance",
            "overtime",
            "audit_threshold",
            "allowed_mcc",
            "allowed_regions",
        ]
    },
    "erp_db": {
        "alias": "ERP DB",
        "description": "인사, 예산, 발주, 계약 마스터 데이터",
        "allowed_schemas": ["HR", "FIN", "CTR"],
        "allowed_tables": [
            "EMP_INFO",
            "DEPT_INFO",
            "BUDGET_MASTER",
            "PURCHASE_ORDER",
            "CONTRACT_MASTER",
        ]
    }
}
```

---

### TASK-SQL-02 감사 집계 쿼리 최적화

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 |
| **예상 공수** | 2일 |
| **담당** | 데이터엔지니어 |

```python
# sql-runner/src/audit/audit_queries.py
# 감사 분석에 자주 쓰이는 사전 정의 쿼리 (MCP 도구에서 호출)

AUDIT_QUERY_TEMPLATES = {
    
    # AUD-ACC-01: 분할 지출 탐지 (3일 내 동일인 499,999원 이하 3건 이상)
    "split_payment_detection": """
        WITH daily_exp AS (
            SELECT 
                emp_id,
                dept_cd,
                DATE(approved_at) AS exp_date,
                SUM(amount) AS daily_total,
                COUNT(*) AS tx_count
            FROM approval_history
            WHERE approved_at >= :start_date
              AND approved_at < :end_date
              AND amount < 500000
              AND status = 'APPROVED'
            GROUP BY emp_id, dept_cd, DATE(approved_at)
        ),
        rolling AS (
            SELECT
                emp_id,
                dept_cd,
                exp_date,
                SUM(tx_count) OVER (
                    PARTITION BY emp_id 
                    ORDER BY exp_date 
                    ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
                ) AS rolling_3day_count,
                SUM(daily_total) OVER (
                    PARTITION BY emp_id 
                    ORDER BY exp_date 
                    ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
                ) AS rolling_3day_total
            FROM daily_exp
        )
        SELECT 
            emp_id,
            dept_cd,
            exp_date,
            rolling_3day_count,
            rolling_3day_total,
            ROUND(rolling_3day_total::numeric / rolling_3day_count, 0) AS avg_amount
        FROM rolling
        WHERE rolling_3day_count >= 3
          AND rolling_3day_total >= 500000
        ORDER BY rolling_3day_total DESC
    """,
    
    # AUD-ACC-04: 법인카드 출장지 불일치 탐지
    "corp_card_location_mismatch": """
        SELECT 
            c.emp_id,
            c.dept_cd,
            c.used_at,
            c.merchant_city,
            b.dest_city,
            c.amount,
            c.merchant_name,
            ABS(EXTRACT(EPOCH FROM (c.used_at - b.trip_start)) / 3600) AS hours_diff
        FROM corp_card_usage c
        JOIN business_trip b ON c.emp_id = b.emp_id
            AND c.used_at BETWEEN b.trip_start AND b.trip_end
        WHERE c.used_at >= :start_date
          AND c.merchant_city IS NOT NULL
          AND b.dest_city IS NOT NULL
          AND c.merchant_city != b.dest_city
          AND c.amount > 10000
        ORDER BY c.amount DESC
    """,
    
    # AUD-ACC-07: 심야 고액 법인카드 사용
    "late_night_corp_card": """
        SELECT 
            emp_id,
            dept_cd,
            used_at,
            merchant_name,
            merchant_category,
            amount,
            EXTRACT(HOUR FROM used_at) AS hour_of_day
        FROM corp_card_usage
        WHERE used_at >= :start_date
          AND EXTRACT(HOUR FROM used_at) >= 22
          AND amount > 100000
          AND merchant_category NOT IN (
              SELECT mcc_code FROM allowed_mcc WHERE is_allowed = true
          )
        ORDER BY amount DESC
    """,
    
    # AUD-GEN-01: 부서별 월간 지출 추이
    "dept_monthly_expenditure": """
        SELECT 
            dept_cd,
            TO_CHAR(approved_at, 'YYYY-MM') AS year_month,
            COUNT(*) AS tx_count,
            SUM(amount) AS total_amount,
            AVG(amount) AS avg_amount,
            MAX(amount) AS max_amount
        FROM approval_history
        WHERE approved_at >= :start_date
          AND status = 'APPROVED'
        GROUP BY dept_cd, TO_CHAR(approved_at, 'YYYY-MM')
        ORDER BY dept_cd, year_month
    """,
}

class AuditQueryExecutor:
    """감사 전용 쿼리 실행기 — 사전 정의 쿼리만 허용"""
    
    def __init__(self, db_client):
        self.db = db_client
    
    async def run_audit_query(
        self, 
        query_key: str,
        params: dict,
        tenant_id: str
    ) -> list[dict]:
        """사전 정의된 감사 쿼리 실행"""
        if query_key not in AUDIT_QUERY_TEMPLATES:
            raise ValueError(f"알 수 없는 감사 쿼리: {query_key}")
        
        query = AUDIT_QUERY_TEMPLATES[query_key]
        # 파라미터 바인딩으로 SQL 인젝션 방지
        return await self.db.execute(
            query,
            params={"tenant_id": tenant_id, **params}
        )
```

---

### TASK-SQL-03 쿼리 결과 스트리밍 (대용량 감사 데이터)

| 항목 | 내용 |
|------|------|
| **우선순위** | P1 |
| **예상 공수** | 2일 |
| **담당** | 백엔드 중급 |

```python
# sql-runner/src/routes/stream.py
# 대용량 감사 데이터 스트리밍 API

from fastapi import APIRouter
from fastapi.responses import StreamingResponse
import json

router = APIRouter(prefix="/stream")

@router.post("/query")
async def stream_query_results(request: StreamQueryRequest):
    """
    대용량 쿼리 결과를 JSONL 스트리밍으로 반환.
    감사 데이터 집계 시 수만 건 결과를 청크로 전송.
    """
    async def generate():
        async for row in db_client.stream_execute(
            query=request.query,
            params=request.params,
            chunk_size=100  # 100건씩 청크
        ):
            yield json.dumps(row, ensure_ascii=False, default=str) + "\n"
    
    return StreamingResponse(
        generate(),
        media_type="application/x-ndjson",
        headers={"X-Stream-Type": "audit-query-results"}
    )
```

---

### TASK-SQL-04 쿼리 실행 감사 로깅

| 항목 | 내용 |
|------|------|
| **우선순위** | P1 |
| **예상 공수** | 1일 |
| **담당** | 백엔드 중급 |

```python
# sql-runner/src/middleware/audit_log.py
# 모든 쿼리 실행을 로깅 (감사 추적 + 보안)

from datetime import datetime
import hashlib

async def log_query_execution(
    query: str,
    params: dict,
    emp_cd: str,
    tenant_id: str,
    execution_time_ms: int,
    row_count: int,
):
    """
    쿼리 실행 이력을 SQL Execution Log에 저장.
    개인정보가 포함될 수 있는 쿼리는 해시 처리.
    """
    query_hash = hashlib.sha256(query.encode()).hexdigest()[:16]
    
    await db.execute("""
        INSERT INTO sql_execution_log (
            query_hash, emp_cd, tenant_id,
            executed_at, execution_time_ms, row_count,
            query_preview
        ) VALUES (
            :query_hash, :emp_cd, :tenant_id,
            :executed_at, :execution_time_ms, :row_count,
            :query_preview
        )
    """, {
        "query_hash": query_hash,
        "emp_cd": emp_cd,
        "tenant_id": tenant_id,
        "executed_at": datetime.utcnow(),
        "execution_time_ms": execution_time_ms,
        "row_count": row_count,
        "query_preview": query[:200],  # 처음 200자만 저장
    })
```

---

### TASK-SQL-05 감사 분석 배치 API

| 항목 | 내용 |
|------|------|
| **우선순위** | P1 |
| **예상 공수** | 2일 |
| **담당** | 데이터엔지니어 |

```python
# sql-runner/src/routes/batch.py
# audit-anomaly 서비스가 호출하는 배치 분석 API

@router.post("/internal/audit/batch-analyze")
async def run_batch_audit_analysis(request: BatchAuditRequest):
    """
    1일치 감사 데이터 수집 및 집계.
    audit-anomaly 서비스가 매일 07:00에 호출.
    """
    target_date = request.target_date  # e.g., "2026-04-12"
    
    results = {}
    
    # 병렬 쿼리 실행 (asyncio.gather)
    tasks = [
        executor.run_audit_query("split_payment_detection", {
            "start_date": f"{target_date} 00:00:00",
            "end_date": f"{target_date} 23:59:59"
        }, request.tenant_id),
        executor.run_audit_query("corp_card_location_mismatch", {
            "start_date": f"{target_date} 00:00:00"
        }, request.tenant_id),
        executor.run_audit_query("late_night_corp_card", {
            "start_date": f"{target_date} 00:00:00"
        }, request.tenant_id),
    ]
    
    (
        split_payments,
        location_mismatches,
        late_night_usage
    ) = await asyncio.gather(*tasks)
    
    return {
        "target_date": target_date,
        "analysis_results": {
            "split_payment": split_payments,
            "location_mismatch": location_mismatches,
            "late_night": late_night_usage,
        },
        "summary": {
            "total_anomalies": (
                len(split_payments) + 
                len(location_mismatches) + 
                len(late_night_usage)
            )
        }
    }
```

---

## 완료 체크리스트

```
□ TASK-SQL-01: 감사 DB / ERP DB / 그룹웨어 DB 연결 설정 추가
□ TASK-SQL-01: connections.yaml 환경변수 .env.poc 파일 추가
□ TASK-SQL-02: 감사 집계 쿼리 4종 구현 (분할지출, 출장불일치, 심야, 부서추이)
□ TASK-SQL-02: AuditQueryExecutor 클래스 구현
□ TASK-SQL-03: JSONL 스트리밍 API 구현 (100건 청크)
□ TASK-SQL-04: 쿼리 실행 감사 로깅 미들웨어 구현
□ TASK-SQL-05: 배치 분석 API 구현 (audit-anomaly 연동)
□ Read-Only 보장 검증 (UPDATE/DELETE/INSERT 차단 확인)
□ 감사 DB 연결 테스트 (실제 DB 또는 Mock 데이터)
□ 복잡한 JOIN 쿼리 성능 테스트 (1만 건 이상)
```
