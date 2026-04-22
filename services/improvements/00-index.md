# 기존 서비스 개선 내역 — 인덱스

> **기준일**: 2026-04-22
> **대상**: POC 진행 중 기존 9개 서비스에 추가/변경되는 내역

---

## 개선 대상 서비스 (10종)

### AI 서비스 (3종)

| 서비스 | 포트 | 주요 개선 | 설계 문서 |
|--------|:---:|---------|---------|
| ai-assistant | 4005 | POC 전용 LangGraph 4종 추가 (결재기안/개인비서/동기화/문서적합성) | [→](ai-assistant.md) |
| ai-rag | 4006 | 규정 파티션 5종 + 조 단위 청킹 + Q&A 이력 컬렉션 | [→](ai-rag.md) |
| ai-llm | 6001 | 행정 규정 전용 프롬프트 4종 + 한국어 최적화 | [→](ai-llm.md) |

### Backend 서비스 (4종)

| 서비스 | 포트 | 주요 개선 | 설계 문서 |
|--------|:---:|---------|---------|
| admin-api | 4000 | notify/regulation/compliance/audit 모듈 신규 | [→](admin-api.md) |
| chat-api | 4002 | 모드 라우팅 (erp_approval / regulation / personal) + SSE 이벤트 타입 | [→](chat-api.md) |
| erp-mcp | 4010 | MCP 도구 3종 신규 (`get_deadline_tasks`, `get_expense_info`, `get_pending_items`) | [→](erp-mcp.md) |
| sql-runner | 4004 | 감사 DB 커넥션 + 집계 쿼리 | [→](sql-runner.md) |

### Frontend 서비스 (2종)

| 서비스 | 포트 | 주요 개선 | 설계 문서 |
|--------|:---:|---------|---------|
| admin-web | 3001 | 감사 페이지 2개 신규 (`audit/risk-score`, `audit/alerts`) + 기존 페이지 확장 | [→](admin-web.md) |
| chat-web | 3000 | slot 3종 (`ApprovalDraftCard`, `RegulationCitationPanel`, `PersonalTaskCard`) + 모드 선택 UI | [→](chat-web.md) |

### 특화 파이프라인 (1종)

| 항목 | 대상 | 주요 내용 | 설계 문서 |
|------|------|---------|---------|
| HWP RAG 파이프라인 | ai-rag + ocr-service | 전사 HWP 문서(~3TB) Ubuntu 파싱 + RAG 인덱싱 방안 | [→](hwp-rag-pipeline.md) |

---

## 참조

- [../new/00-index.md](../new/00-index.md) — 신규 서비스 (groupware-mcp, audit-anomaly)
- [../../01-architecture.md](../../01-architecture.md) — 전체 아키텍처
- [../../challenges/](../../challenges/) — 9과제 상세 스펙
