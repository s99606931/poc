# 과제 7 — 지능형 회계 감사 구현 가이드

> **작성일**: 2026-04-21 | **기간**: 4.5주 | **재사용률**: 70%
> **과제 문서**: [../07-accounting-audit.md](../07-accounting-audit.md)

## 1. 개요

ERP 결재/지출 데이터에서 이상 거래 패턴을 탐지 (중복 청구, 분할 지출, Z-Score, Isolation Forest) → alli-audit 저장 → 대시보드 표시.

**서비스**: audit-anomaly (신규 Port 4012, Python + FastAPI + Scikit-learn + APScheduler)

## 2. 폴더 구성

| 파일 | 내용 |
|------|------|
| README.md | 본 문서 |
| [external-dependencies.md](external-dependencies.md) | ERP 감사 DB 접근 |
| [detection-rules.md](detection-rules.md) | 4종 탐지 규칙 상세 |
| [sql-queries.sql](sql-queries.sql) | **탐지 SQL 쿼리** |
| [ml-models.md](ml-models.md) | Z-Score, Isolation Forest 구현 |
| [risk-scoring.md](risk-scoring.md) | 리스크 스코어 산정 |
| [api-samples.json](api-samples.json) | 탐지 → 저장 E2E 샘플 |
| [db-schemas.sql](db-schemas.sql) | alli-audit 확장 + audit_anomaly 테이블 |

## 3. 고객 결정 포인트 (10개 — 가장 많음)

[../15-per-challenge-decision-points.md#-과제-7--지능형-회계-감사-이상-결제-패턴-탐지](../15-per-challenge-decision-points.md)

핵심: D7-03 탐지 임계값, D7-05 처리 프로세스, D7-09 개인정보
