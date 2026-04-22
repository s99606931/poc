# 회계 이상 탐지 규칙 (4종)

## Rule A — duplicate_claim (중복 청구)

**정의**: 동일 직원이 동일 항목·동일 금액으로 30일 이내 중복 청구

**근거 규정**: 공무원 여비규정, 기관 지출규정

**감점**: HIGH 10점

**SQL**:
```sql
SELECT e1.EXP_ID, e1.EMP_CD, e1.CLAIM_TYPE, e1.AMOUNT, e1.SUBMITTED_AT,
       e2.EXP_ID AS duplicate_exp_id, e2.SUBMITTED_AT AS duplicate_date
FROM ACC_EXPENSE e1
INNER JOIN ACC_EXPENSE e2
  ON e1.EMP_CD = e2.EMP_CD
  AND e1.CLAIM_TYPE = e2.CLAIM_TYPE
  AND e1.AMOUNT = e2.AMOUNT
  AND e1.EXP_ID != e2.EXP_ID
  AND ABS(DATEDIFF(e1.SUBMITTED_AT, e2.SUBMITTED_AT)) <= 30
WHERE e1.SUBMITTED_AT >= DATE_SUB(NOW(), INTERVAL 30 DAY)
  AND e1.STATUS IN ('APPROVED', 'PAID')
  AND e2.STATUS IN ('APPROVED', 'PAID')
ORDER BY e1.SUBMITTED_AT DESC;
```

---

## Rule B — split_payment (쪼개기 결제)

**정의**: 결재 기준금액 회피 목적으로 7일 내 3건 이상 분할 청구 (합계 50만원+)

**감점**: HIGH 10점

**SQL**:
```sql
SELECT EMP_CD,
       COUNT(*) AS split_count,
       SUM(AMOUNT) AS total_amount,
       MIN(SUBMITTED_AT) AS first_date,
       MAX(SUBMITTED_AT) AS last_date,
       GROUP_CONCAT(EXP_ID) AS exp_ids
FROM ACC_EXPENSE
WHERE SUBMITTED_AT >= DATE_SUB(NOW(), INTERVAL 7 DAY)
  AND CLAIM_TYPE = '물품구매'
  AND STATUS IN ('APPROVED', 'PAID')
GROUP BY EMP_CD
HAVING COUNT(*) >= 3 AND SUM(AMOUNT) >= 500000;
```

---

## Rule C — amount_outlier (Z-Score 이상치)

**정의**: 동일 항목 유형 대비 Z-Score > 2.5 (통계적 이상 고액)

**감점**: MEDIUM 5점

**로직** (Pandas):
```python
import pandas as pd
from scipy.stats import zscore

def detect_amount_outliers(df: pd.DataFrame, threshold: float = 2.5):
    """
    df: columns=[exp_id, emp_cd, claim_type, amount, submitted_at]
    """
    df["z_score"] = df.groupby("claim_type")["amount"].transform(zscore)
    outliers = df[df["z_score"].abs() > threshold].copy()
    outliers["severity"] = outliers["z_score"].apply(
        lambda z: "HIGH" if abs(z) > 4 else "MEDIUM"
    )
    return outliers[["exp_id", "emp_cd", "claim_type", "amount", "z_score", "severity"]]
```

---

## Rule D — Isolation Forest (비지도 ML)

**정의**: 다차원 특징으로 학습 후 이상 패턴 탐지 (규칙 미포함 복합 이상)

**특징 (features)**:
```python
FEATURES = [
    "amount",                       # 금액
    "hour_of_day",                  # 제출 시각
    "day_of_week",                  # 요일
    "days_since_last_claim",        # 전 청구 경과일
    "amount_z_score_by_type",       # 유형별 Z-Score
    "approver_count",               # 결재자 수
    "same_day_claims_count",        # 같은 날 청구 건수
]
```

**감점**: MEDIUM 5점 (isolation_score 기반)

**구현**:
```python
from sklearn.ensemble import IsolationForest
import joblib

class AnomalyDetector:
    def __init__(self, contamination=0.05):
        self.model = IsolationForest(
            contamination=contamination,
            random_state=42,
            n_estimators=100,
            max_samples='auto',
        )

    def train(self, df: pd.DataFrame):
        """최근 6개월 데이터로 학습"""
        X = df[FEATURES].fillna(0)
        self.model.fit(X)
        joblib.dump(self.model, "/data/model/if_audit_model.pkl")

    def predict(self, df: pd.DataFrame):
        X = df[FEATURES].fillna(0)
        df["is_anomaly"] = self.model.predict(X) == -1
        df["anomaly_score"] = self.model.decision_function(X)
        return df[df["is_anomaly"]].sort_values("anomaly_score")
```

---

## Rule 조합 실행 시퀀스

```python
async def run_detection_batch():
    # 1. 전일 데이터 조회
    df = await load_yesterday_expenses()

    # 2. 각 규칙 실행
    rule_a = await detect_duplicate_claim(df)
    rule_b = await detect_split_payment(df)
    rule_c = detect_amount_outliers(df)
    rule_d = await isolation_forest_detector.predict(df)

    # 3. 통합 + 리스크 스코어 산정
    all_anomalies = combine(rule_a, rule_b, rule_c, rule_d)
    all_anomalies["risk_score"] = all_anomalies.apply(calc_risk_score, axis=1)

    # 4. 자연어 설명 생성 (ai-assistant)
    for anomaly in all_anomalies:
        anomaly["explanation"] = await ai_assistant.explain(anomaly)

    # 5. alli-audit 저장 (admin-api 경유)
    await admin_api.save_anomalies(all_anomalies)

    # 6. 임계치 도달 시 알림
    for anomaly in all_anomalies:
        if anomaly["severity"] == "HIGH":
            await admin_api.send_notification(anomaly)
```
