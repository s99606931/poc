# 과제 9 — 사전 알림 + 감사 대시보드 구현 가이드

> **작성일**: 2026-04-21 | **기간**: 3주 | **재사용률**: 75%

## 1. 개요

- **알림**: admin-api 내 notify 모듈로 구현 (SSE + 이메일 + Webhook)
- **대시보드**: admin-web 기존 페이지 확장 + 신규 2페이지
- **이력**: alli-audit 패키지 재사용

## 2. 폴더 구성

| 파일 | 내용 |
|------|------|
| README.md | 본 문서 |
| [external-dependencies.md](external-dependencies.md) | SMTP + Webhook |
| [notify-module-spec.md](notify-module-spec.md) | admin-api notify 모듈 |
| [dashboard-pages.md](dashboard-pages.md) | admin-web 5개 페이지 구성 |
| [api-samples.json](api-samples.json) | 알림 + 대시보드 API |
| [db-schemas.sql](db-schemas.sql) | alli-audit + notify_history |

## 3. 페이지 구성

| 페이지 | 유형 | 과제 |
|--------|:---:|------|
| /admin/dashboard (확장) | 기존 | KPI 카드 추가 |
| /admin/activities/audits (확장) | 기존 | 이상 탐지 목록 |
| /admin/documents (확장) | 기존 | 규정 관리 + 적합성 |
| /admin/audit/risk-score | **신규** | 부서별 히트맵 |
| /admin/audit/alerts | **신규** | 알림 이력 + 규칙 설정 |
