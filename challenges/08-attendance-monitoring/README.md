# 과제 8 — 복무 관리 모니터링 구현 가이드

> **작성일**: 2026-04-21 | **기간**: 2주 | **재사용률**: 70%
> **상태**: ⚠️ 시나리오 B에서 **2단계 연기** (🔴 P0-3 노조 협의 필수)

## 1. 개요

출장-법인카드 매칭, 주간 초과근무 패턴, 근태 이상 탐지. **audit-anomaly 서비스 공유** (과제 7과 동일).

🔴 **P0-3 노조 협의 미완료 시 절대 불가** — [상세](../15-per-challenge-decision-points.md#-d8-05-미진행-시-영향--과제-8-2단계-연기-필수-사유)

## 2. 폴더 구성

| 파일 | 내용 |
|------|------|
| README.md | 본 문서 |
| [external-dependencies.md](external-dependencies.md) | 🔴 노조 협의 + 법인카드 데이터 |
| [detection-rules.md](detection-rules.md) | 출장-카드 / 초과근무 / 근태 규칙 |
| [sql-queries.sql](sql-queries.sql) | ERP 근태 DB 쿼리 |
| [api-samples.json](api-samples.json) | 탐지 샘플 |

## 3. 재사용

audit-anomaly 서비스 (과제 7) + alli-audit 저장 + admin-web activities/audits
