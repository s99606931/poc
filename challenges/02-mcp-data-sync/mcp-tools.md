# 과제 2 동기화 MCP 도구

## erp-mcp

### `get_hr_info(emp_cd=None, dept_cd=None, changed_since=None)`

```json
{
  "total_count": 245,
  "employees": [
    {
      "emp_cd": "EMP20240315",
      "emp_nm": "홍길동",
      "dept_cd": "D010201",
      "dept_nm": "회계부",
      "position_cd": "P05",
      "position_nm": "주임",
      "email": "hong@agency.go.kr",
      "phone": "010-0000-0000",
      "join_date": "2024-03-15",
      "active_yn": "Y",
      "last_modified": "2026-04-20T14:22:00+09:00"
    }
  ],
  "delta_changes": 12
}
```

### `get_org_structure(root_dept_cd=null)`

```json
{
  "root": {
    "dept_cd": "D010000",
    "dept_nm": "본원",
    "children": [
      {
        "dept_cd": "D010200",
        "dept_nm": "재무과",
        "parent_cd": "D010000",
        "children": [
          {"dept_cd": "D010201", "dept_nm": "회계부", "parent_cd": "D010200", "children": []},
          {"dept_cd": "D010202", "dept_nm": "예산부", "parent_cd": "D010200", "children": []}
        ]
      }
    ]
  }
}
```

---

## groupware-mcp

### `get_hr_info(emp_cd=None)` — 그룹웨어 측 인사 조회

### `sync_erp_to_groupware(employees: list, mode="UPSERT", dry_run=False)` — Write

```python
@mcp.tool
async def sync_erp_to_groupware(
    employees: list[EmployeeDelta],
    mode: str = "UPSERT",           # UPSERT | INSERT | UPDATE | DELETE
    dry_run: bool = False,
) -> SyncResult:
    """ERP 인사 데이터를 그룹웨어에 반영 (배치 100건 제한)"""
```

### `update_org_chart(org_changes: list)` — Write

---

## 응답 샘플 (sync_erp_to_groupware)

```json
{
  "sync_id": "SYNC-20260421-001",
  "mode": "UPSERT",
  "dry_run": false,
  "total_requested": 12,
  "success_count": 11,
  "failed_count": 1,
  "results": [
    {"emp_cd": "EMP20240315", "action": "UPDATE", "status": "SUCCESS", "changed_fields": ["dept_cd", "position_cd"]},
    {"emp_cd": "EMP20241010", "action": "INSERT", "status": "SUCCESS"},
    {"emp_cd": "EMP20180205", "action": "DELETE", "status": "FAILED", "error": "그룹웨어에 결재 이력 존재 — 비활성화로 처리 필요"}
  ],
  "duration_ms": 1840,
  "synced_at": "2026-04-21T10:30:00+09:00"
}
```
