# 리스크 스코어 산정

## 1. 기본 공식

```python
RULE_WEIGHTS = {
    "duplicate_claim":     10,  # HIGH
    "split_payment":       10,  # HIGH
    "amount_outlier":       5,  # MEDIUM
    "isolation_forest":     5,  # MEDIUM
}

def calc_individual_risk(anomalies_by_emp: dict) -> float:
    """개인별 리스크 스코어"""
    total = 0
    for rule, count in anomalies_by_emp.items():
        total += RULE_WEIGHTS[rule] * count
    return total

def calc_dept_risk_ratio(anomalies: list, total_expenses: int) -> float:
    """부서별 리스크 비율 (0~1)"""
    weighted_sum = sum(RULE_WEIGHTS[a["rule"]] for a in anomalies)
    return weighted_sum / (total_expenses * 10)  # max=1.0
```

## 2. 등급 기준

```python
RISK_GRADES = {
    "RED":    {"threshold_ratio": 0.15, "action": "즉시 감사 권고", "alert": True},
    "ORANGE": {"threshold_ratio": 0.08, "action": "주의 모니터링",   "alert": True},
    "YELLOW": {"threshold_ratio": 0.03, "action": "관찰",            "alert": False},
    "GREEN":  {"threshold_ratio": 0.00, "action": "정상",            "alert": False},
}

def assign_grade(ratio: float) -> str:
    for grade in ["RED", "ORANGE", "YELLOW", "GREEN"]:
        if ratio >= RISK_GRADES[grade]["threshold_ratio"]:
            return grade
    return "GREEN"
```

## 3. 부서별 히트맵 데이터

```json
{
  "generated_at": "2026-04-21T07:15:00+09:00",
  "period": {"from": "2026-03-22", "to": "2026-04-21"},
  "departments": [
    {
      "dept_cd": "D010201",
      "dept_nm": "회계부",
      "total_expenses_count": 450,
      "anomalies_count": 12,
      "high_count": 2,
      "medium_count": 7,
      "low_count": 3,
      "risk_score_raw": 55,
      "risk_ratio": 0.122,
      "grade": "ORANGE",
      "trend_vs_prev_month": "+15%"
    },
    {
      "dept_cd": "D020105",
      "dept_nm": "조달과",
      "total_expenses_count": 320,
      "anomalies_count": 8,
      "high_count": 3,
      "medium_count": 4,
      "low_count": 1,
      "risk_score_raw": 52,
      "risk_ratio": 0.163,
      "grade": "RED",
      "trend_vs_prev_month": "+45%"
    }
  ]
}
```

## 4. 알림 트리거

```python
async def evaluate_and_alert(anomaly: dict):
    dept_risk = await calc_dept_risk_ratio(
        dept_cd=anomaly["dept_cd"],
        period_days=30,
    )
    grade = assign_grade(dept_risk)

    if grade == "RED":
        # 즉시 발송 (이메일 + SSE + Webhook)
        await admin_api.send_notification({
            "severity": "RED",
            "title": f"[긴급] {anomaly['dept_nm']} 감사 이상 탐지 — {anomaly['rule_code']}",
            "body": anomaly["explanation"],
            "targets": {
                "sse": True,
                "email": await get_auditor_emails(anomaly["dept_cd"]),
                "webhook": ["kakaowork"],
            },
        })
    elif grade == "ORANGE":
        # 일배치 요약 (매일 08:00)
        await queue_orange_digest(anomaly)
```
