# erp-mcp 서비스 개선 태스크 (POC 대응)

> **서비스**: `projects/10_alli-work/apps/erp-mcp`
> **현재 포트**: 4010
> **기술**: FastAPI + LangGraph + FastMCP + JWT(ES256)
> **POC 역할**: ERP 데이터 연동 핵심 서비스 (POC 1, 3)
> **작성일**: 2026-04-21

> **📌 POC 확장 범위 요약**
> 기존 심화 구조 (agents/finders/resolvers/sql_processing/security) 유지.
> 핵심 작업: **POC용 MCP 도구 3종 추가** (get_deadline_tasks, get_expense_info, get_pending_items).
> 이 서비스는 `groupware-mcp` (신규)의 **복제 원본**.

---

## 현재 상태

```
✅ MCP HTTP 서버 구현 완료
✅ ERP DB 연동 (sql-runner 경유)
✅ LangGraph 자연어 → SQL 생성
✅ JWT ES256 인증 (emp_cd, dept_cd, tenant_id)
✅ ai-assistant 내부 라우터 (인증 없음)
❌ 그룹웨어 데이터 연동 없음
❌ 마감일/일정 조회 MCP 도구 미구현
❌ ERP 데이터 실시간 연동 (현재 배치 위주)
```

---

## 개선 태스크

### TASK-ERP-01 ERP 마감일 MCP 도구 추가

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (POC 1 개인 비서 기능 필수) |
| **예상 공수** | 2일 |
| **담당** | 백엔드 중급 |

#### 구현 내용

```python
# erp-mcp/src/tools/deadline_tools.py

@mcp_server.tool()
async def get_deadline_tasks(emp_cd: str, target_date: str) -> dict:
    """
    ERP에서 직원의 업무 마감일 목록 조회
    
    Args:
        emp_cd: 직원 사번
        target_date: 조회 기준일 (YYYY-MM-DD)
    
    Returns:
        마감 임박 업무 목록 (D-Day 순 정렬)
    """
    query = """
        SELECT 
            task_nm,
            deadline_date,
            DATEDIFF(deadline_date, :target_date) AS d_day,
            task_type,
            dept_cd
        FROM erp_deadline_tasks
        WHERE emp_cd = :emp_cd
          AND deadline_date BETWEEN :target_date AND DATE_ADD(:target_date, INTERVAL 7 DAY)
          AND status != 'COMPLETED'
        ORDER BY deadline_date ASC
    """
    result = await sql_runner.execute(query, {
        "emp_cd": emp_cd,
        "target_date": target_date
    })
    return {"deadlines": result, "count": len(result)}

@mcp_server.tool()
async def get_settlement_schedule() -> dict:
    """회계 결산 마감 일정 조회 (전사)"""
    # ... 결산, 지급, 예산 마감일 조회
```

#### 완료 기준
- `get_deadline_tasks` 호출 시 D-7 이내 마감 업무 반환
- ai-assistant에서 "이번 주 마감 업무" 질의 시 정상 응답

---

### TASK-ERP-02 ERP 지출/청구 데이터 조회 강화

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (POC 1 결재 기안, POC 3 감사 데이터) |
| **예상 공수** | 3일 |
| **담당** | 백엔드 중급 |

#### 구현 내용

```python
@mcp_server.tool()
async def get_expense_info(emp_cd: str, period: str = "month") -> dict:
    """직원의 지출 현황 조회 (결재 기안 시 활용)"""

@mcp_server.tool()  
async def get_dept_budget_status(dept_cd: str, year: int, month: int) -> dict:
    """부서별 예산 집행 현황 조회"""

@mcp_server.tool()
async def get_recent_approvals(emp_cd: str, status: str = "all") -> dict:
    """최근 결재 내역 조회 (대기/완료/반려)"""
```

#### 완료 기준
- 결재 기안 시 사용자의 최근 지출 내역 자동 참조
- 예산 잔액 조회로 기안 가능 금액 안내 가능

---

### TASK-ERP-03 감사 데이터 조회 MCP 도구 (POC 3 지원)

| 항목 | 내용 |
|------|------|
| **우선순위** | P1 (POC 3 감사 기능 지원) |
| **예상 공수** | 2일 |
| **담당** | 백엔드 중급 |

```python
@mcp_server.tool()
async def get_approval_history_for_audit(
    dept_cd: str,
    start_date: str,
    end_date: str,
    doc_type: Optional[str] = None
) -> dict:
    """감사 목적 결재내역 대량 조회 (audit-anomaly 서비스에서 호출)"""
    # Read-Only 감사 전용 쿼리
    # 개인정보 마스킹 (이름 → 사번만)

@mcp_server.tool()
async def get_corp_card_usage_for_audit(
    emp_cd: str,
    start_date: str,
    end_date: str
) -> dict:
    """감사 목적 법인카드 사용내역 조회"""
```

---

### TASK-ERP-04 grouopware-mcp 연동 준비 (인터페이스 표준화)

| 항목 | 내용 |
|------|------|
| **우선순위** | P1 |
| **예상 공수** | 1일 |
| **담당** | 백엔드 중급 |

```python
# erp-mcp와 groupware-mcp 간 공통 데이터 모델 정의
# packages/poc-common/src/models/

class EmployeeInfo(BaseModel):
    emp_cd: str
    emp_nm: str
    dept_cd: str
    dept_nm: str
    position: str

class ApprovalRoute(BaseModel):
    doc_type: str
    approvers: list[str]  # 결재선 순서
    
class TaskItem(BaseModel):
    task_id: str
    task_title: str
    deadline: date
    source: str  # "ERP" | "GROUPWARE"
    priority: int  # 우선순위 점수
```

---

### TASK-ERP-05 LangGraph 노드 최적화

| 항목 | 내용 |
|------|------|
| **우선순위** | P2 |
| **예상 공수** | 2일 |

- SQL 생성 프롬프트에 ERP 테이블 스키마 컨텍스트 추가
- 결재 관련 ERP 쿼리 템플릿 캐싱 (Redis)
- 병렬 MCP 도구 호출 최적화 (ai-assistant 연동)

---

## 완료 체크리스트

```
□ TASK-ERP-01: get_deadline_tasks 도구 구현 및 테스트
□ TASK-ERP-02: 지출/청구/예산 조회 도구 3종 구현
□ TASK-ERP-03: 감사 전용 대량 조회 도구 구현
□ TASK-ERP-04: 공통 데이터 모델 패키지 생성
□ TASK-ERP-05: LangGraph 노드 최적화 (P2)
□ Docker 컨테이너 재빌드 및 healthcheck 확인
□ ai-assistant 통합 테스트 (MCP 도구 호출 E2E)
```
