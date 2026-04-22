# 불일치 탐지 알고리즘 (diff_detect)

## 1. 필드별 비교 규칙

```python
SYNC_FIELDS = [
    # 기본
    {"field": "emp_nm", "required": True, "case_sensitive": False},
    {"field": "dept_cd", "required": True},
    {"field": "position_cd", "required": True},
    # 연락처
    {"field": "email", "required": False, "normalize": "lowercase"},
    {"field": "phone", "required": False, "normalize": "digits_only"},
    # 상태
    {"field": "active_yn", "required": True},
]

def normalize_value(field_config, value):
    if value is None:
        return None
    if field_config.get("normalize") == "lowercase":
        return value.lower()
    if field_config.get("normalize") == "digits_only":
        return re.sub(r"\D", "", value)
    return value

def detect_changes(erp_emp, gw_emp):
    changes = {}
    for field_config in SYNC_FIELDS:
        field = field_config["field"]
        erp_val = normalize_value(field_config, erp_emp.get(field))
        gw_val = normalize_value(field_config, gw_emp.get(field)) if gw_emp else None
        if erp_val != gw_val:
            changes[field] = {"old": gw_val, "new": erp_val}
    return changes
```

## 2. 액션 결정

```
ERP 존재 + 그룹웨어 없음           → INSERT
ERP 존재 + 그룹웨어 존재 + 변경    → UPDATE
ERP 없음/비활성 + 그룹웨어 있음    → DELETE (또는 deactivate)
ERP 존재 + 그룹웨어 존재 + 동일    → SKIP
```

## 3. 충돌 해결 (단방향 기준)

ERP 우선:
- ERP 값으로 덮어쓰기
- 그룹웨어 원본 값은 SYNC_RECORD_DETAIL.changed_fields_json에 old 값으로 보관

## 4. 대량 변경 감지 알림

```python
if len(changes) > LARGE_CHANGE_THRESHOLD:  # 예: 50건 초과
    await alert_service.send(
        severity="ORANGE",
        title=f"대량 인사 변경 감지: {len(changes)}건",
        body="30분 이내 50건 이상 변경 — 수동 승인 필요 여부 확인"
    )
    if config.REQUIRE_MANUAL_APPROVAL_FOR_LARGE_CHANGES:
        return {"status": "AWAITING_APPROVAL"}
```

## 5. 재시도 로직

```
실패 (Network/Timeout) → exponential backoff (1s, 2s, 4s) 3회
실패 (Validation)     → 즉시 실패 처리, 다음 건 계속
실패 (Business)        → SKIP 처리, 관리자 알림
```
