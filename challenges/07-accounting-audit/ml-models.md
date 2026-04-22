# ML 모델 (Z-Score + Isolation Forest)

## 1. Z-Score 이상치 탐지

```python
# apps/audit-anomaly/src/detectors/amount_outlier.py
import pandas as pd
from scipy.stats import zscore

class AmountOutlierDetector:
    """Rule C — 유형별 Z-Score 이상치"""

    def __init__(self, threshold: float = 2.5):
        self.threshold = threshold

    def detect(self, df: pd.DataFrame) -> pd.DataFrame:
        # 유형별 그룹 내 Z-Score
        df = df.copy()
        df["z_score"] = df.groupby("CLAIM_TYPE")["AMOUNT"].transform(
            lambda x: zscore(x, ddof=0, nan_policy='omit')
        )

        outliers = df[df["z_score"].abs() > self.threshold].copy()
        outliers["severity"] = outliers["z_score"].apply(
            lambda z: "HIGH" if abs(z) > 4 else "MEDIUM"
        )
        outliers["rule_code"] = "AUD-ACC-C-ZSCORE"
        outliers["reason"] = outliers.apply(
            lambda r: f"{r['CLAIM_TYPE']} 평균 대비 {r['z_score']:.2f}σ 편차",
            axis=1
        )
        return outliers
```

## 2. Isolation Forest

```python
# apps/audit-anomaly/src/detectors/isolation_forest.py
import pandas as pd
import joblib
from sklearn.ensemble import IsolationForest
from pathlib import Path

FEATURES = [
    "AMOUNT",
    "hour_of_day",
    "day_of_week",
    "days_since_last_claim",
    "amount_z_score_by_type",
    "APPROVER_COUNT",
    "same_day_claims_count",
]

MODEL_PATH = Path("/data/model/if_audit_model.pkl")

class IsolationForestDetector:
    """Rule D — 비지도 ML 탐지"""

    def __init__(self, contamination: float = 0.05):
        self.contamination = contamination
        self.model = None

    def load(self):
        if MODEL_PATH.exists():
            self.model = joblib.load(MODEL_PATH)
        else:
            raise FileNotFoundError("모델 학습 먼저 실행")

    def train(self, df: pd.DataFrame):
        """월 1회 학습 (최근 6개월)"""
        X = df[FEATURES].fillna(0)
        self.model = IsolationForest(
            contamination=self.contamination,
            random_state=42,
            n_estimators=100,
            max_samples='auto',
            n_jobs=-1,
        )
        self.model.fit(X)
        joblib.dump(self.model, MODEL_PATH)
        return {"trained_samples": len(X), "model_path": str(MODEL_PATH)}

    def detect(self, df: pd.DataFrame) -> pd.DataFrame:
        """전일 데이터에 대해 이상치 탐지"""
        if self.model is None:
            self.load()
        X = df[FEATURES].fillna(0)

        df = df.copy()
        df["is_anomaly"] = (self.model.predict(X) == -1)
        df["anomaly_score"] = self.model.decision_function(X)

        anomalies = df[df["is_anomaly"]].copy()
        anomalies["severity"] = anomalies["anomaly_score"].apply(
            lambda s: "HIGH" if s < -0.3 else "MEDIUM" if s < -0.1 else "LOW"
        )
        anomalies["rule_code"] = "AUD-ACC-D-ISOLATION-FOREST"
        anomalies["reason"] = anomalies.apply(
            lambda r: f"비정상 패턴 (anomaly_score={r['anomaly_score']:.3f})", axis=1
        )
        return anomalies
```

## 3. 학습 스케줄

```python
# apps/audit-anomaly/src/scheduler/training.py
from apscheduler.schedulers.asyncio import AsyncIOScheduler

scheduler = AsyncIOScheduler()

@scheduler.scheduled_job("cron", day=1, hour=2, minute=0)  # 매월 1일 02:00
async def monthly_retrain():
    """최근 6개월 데이터로 Isolation Forest 재학습"""
    df = await load_training_data(months=6)
    detector = IsolationForestDetector(contamination=0.05)
    result = detector.train(df)
    logger.info(f"모델 재학습 완료: {result}")
```

## 4. 성능 목표

| 지표 | 목표 |
|------|:---:|
| Precision (정밀도) | ≥ 70% |
| Recall (재현율) | ≥ 80% |
| 오탐율 | ≤ 20% |
| 모델 추론 속도 | ≤ 100ms/1000건 |
| 학습 시간 | ≤ 10분 (6개월 데이터) |

## 5. 화이트리스트 (오탐 감소)

```python
WHITELIST_RULES = [
    # 정기 거래 (월말 결재 등)
    {"emp_cd": "*", "claim_type": "월급여", "reason": "정기 급여 집행"},
    # 고액 거래지만 사전 승인된 건
    {"emp_cd": "*", "pre_approved": True, "reason": "사전 승인"},
]

async def apply_whitelist(anomalies: pd.DataFrame):
    for rule in WHITELIST_RULES:
        mask = True
        for key, val in rule.items():
            if key == "reason": continue
            if val == "*": continue
            mask &= (anomalies[key] == val)
        anomalies = anomalies[~mask]
    return anomalies
```
