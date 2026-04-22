# 과제 2 ERP-그룹웨어 동기화 — 구현 아키텍처

> **연관**: [test-scenarios.md](test-scenarios.md) | **상태**: 🔴 P0-1 Write 권한 필수

---

## 1. 컴포넌트 계층

```
Scheduler: APScheduler (30분 cron) — ai-assistant 내부
Graph:     sync_graph (신규) — fetch_erp → fetch_gw → diff → sync_execute → log
MCP Read:  erp-mcp.{get_hr_info, get_org_structure}
MCP Write: groupware-mcp.{sync_erp_to_groupware, update_org_chart} 🔴
Storage:   alli-audit (sync_history 카테고리)
Mapping:   EMP_CD_MAPPING 테이블 (ERP ↔ GW)
```

## 2. SyncState 스키마

```python
class SyncState(TypedDict):
    sync_id: str                   # "SYNC-20260421-001"
    sync_type: str                 # EMPLOYEE | ORG_CHART
    triggered_by: str              # SCHEDULER | MANUAL

    # Phase 1: Fetch
    erp_data: list                 # ERP 인사 전체
    gw_data: list                  # 그룹웨어 인사 전체
    fetch_errors: dict

    # Phase 2: Diff
    changes: list                  # [{emp_cd, action, changed_fields}]
    changes_summary: dict          # {insert:N, update:M, delete:K}

    # Phase 3: Sync
    sync_results: list             # [{emp_cd, status, error}]
    success_count: int
    failed_count: int

    # Phase 4: Alert
    large_change_detected: bool    # 대량 변경 감지 (예: 50건+)
    awaiting_approval: bool        # 수동 승인 대기
```

## 3. 그래프 구성

```python
def build_sync_graph():
    g = StateGraph(SyncState)
    g.add_node("fetch_erp_hr",    fetch_erp_node)
    g.add_node("fetch_gw_hr",     fetch_gw_node)
    g.add_node("diff_detect",     diff_detect_node)
    g.add_node("large_change_check", large_change_check_node)
    g.add_node("sync_execute",    sync_execute_node)
    g.add_node("log_result",      log_result_node)

    g.set_entry_point("fetch_erp_hr")
    g.add_edge("fetch_erp_hr", "fetch_gw_hr")  # 순차 (ERP가 source of truth)
    g.add_edge("fetch_gw_hr", "diff_detect")

    g.add_conditional_edges(
        "diff_detect",
        route_on_change_size,
        {
            "normal":     "sync_execute",      # < 50건
            "large":      "large_change_check" # >= 50건 → 수동 승인
        }
    )
    g.add_edge("sync_execute", "log_result")
    g.add_edge("log_result", END)
    return g.compile()
```

## 4. Diff Detection 알고리즘

```python
async def diff_detect_node(state: SyncState) -> dict:
    erp_by_cd = {e["emp_cd"]: e for e in state["erp_data"]}
    gw_by_cd = {g["emp_cd"]: g for g in state["gw_data"]}

    changes = []

    # INSERT
    for emp_cd in erp_by_cd.keys() - gw_by_cd.keys():
        changes.append({
            "action": "INSERT",
            "emp_cd": emp_cd,
            "data": erp_by_cd[emp_cd],
        })

    # UPDATE
    for emp_cd in erp_by_cd.keys() & gw_by_cd.keys():
        changed = detect_field_changes(erp_by_cd[emp_cd], gw_by_cd[emp_cd])
        if changed:
            changes.append({
                "action": "UPDATE",
                "emp_cd": emp_cd,
                "changed_fields": changed,
            })

    # DELETE (퇴직 등)
    for emp_cd in gw_by_cd.keys() - erp_by_cd.keys():
        changes.append({"action": "DELETE", "emp_cd": emp_cd})

    return {
        "changes": changes,
        "changes_summary": {
            "insert": sum(1 for c in changes if c["action"] == "INSERT"),
            "update": sum(1 for c in changes if c["action"] == "UPDATE"),
            "delete": sum(1 for c in changes if c["action"] == "DELETE"),
        }
    }
```

## 5. 대량 변경 감지

```python
LARGE_CHANGE_THRESHOLD = 50

async def large_change_check_node(state: SyncState) -> dict:
    total = sum(state["changes_summary"].values())
    if total >= LARGE_CHANGE_THRESHOLD:
        # 관리자 알림
        await admin_api.send_notification({
            "severity": "ORANGE",
            "title": f"대량 인사 변경 감지 ({total}건)",
            "body": f"INSERT: {state['changes_summary']['insert']}, UPDATE: {...}",
            "payload": {"sync_id": state["sync_id"], "changes_preview": state["changes"][:5]}
        })

        if settings.REQUIRE_MANUAL_APPROVAL_FOR_LARGE_CHANGES:
            return {"awaiting_approval": True, "large_change_detected": True}
        # 기본: 경고만 + 계속 진행

    return {"large_change_detected": total >= LARGE_CHANGE_THRESHOLD}
```

## 6. 배치 동기화 실행

```python
async def sync_execute_node(state: SyncState) -> dict:
    batch_size = 100  # 그룹웨어 부하 관리
    results = []

    for i in range(0, len(state["changes"]), batch_size):
        batch = state["changes"][i:i+batch_size]
        batch_result = await groupware_mcp.call_tool("sync_erp_to_groupware", {
            "employees": batch,
            "mode": "UPSERT",
            "dry_run": False,
        })
        results.extend(batch_result["results"])

        # 배치 간 0.5초 대기
        await asyncio.sleep(0.5)

    return {
        "sync_results": results,
        "success_count": sum(1 for r in results if r["status"] == "SUCCESS"),
        "failed_count": sum(1 for r in results if r["status"] == "FAILED"),
    }
```

## 7. 성능 SLO

| SLI | SLO |
|-----|:---:|
| 동기화 주기 | 30분 |
| 100건 배치 처리 시간 | ≤ 2분 |
| 동기화 성공률 | ≥ 95% |
| 불일치 탐지 정확도 | ≥ 90% |
| 실시간 연동 지연 (이벤트) | ≤ 30초 |
