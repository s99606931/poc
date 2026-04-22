# 과제 1 — 전자결재 자동 기안 구현 가이드

> **작성일**: 2026-04-21
> **과제 문서**: [../01-intelligent-workflow.md](../01-intelligent-workflow.md)
> **구현 기간**: 2.5주
> **재사용률**: 85%

---

## 1. 구현 개요

"출장비 청구 기안 작성해줘"와 같은 자연어 요청으로 AI가 결재 기안문 초안을 자동 생성하고 결재선 추천 + 규정 검증 후 그룹웨어에 등록(또는 초안 저장)하는 시나리오.

### 핵심 흐름

```
사용자 요청
  → classify_node (문서 유형 분류: 출장비/물품구매/초과근무)
  → parallel_fetch
      ├─ erp-mcp.get_expense_info (ERP 지출/예산)
      └─ groupware-mcp.get_approval_route (결재선 조회)
  → generate_draft (Gemma-4로 기안문 초안 생성)
  → evidence_assess (ai-rag로 결재 규정 적합성 검토)
  → register_draft (groupware-mcp로 초안 등록)
  → chat-web ApprovalDraftCard 렌더링
```

---

## 2. 외부 의존성

| 시스템 | 용도 | 필요 권한 |
|--------|------|---------|
| **ERP DB** | 지출 내역·예산 잔액 조회 | Read-Only |
| **그룹웨어** | 결재선 조회 + 기안 등록 | **Write 권한** 🔴 P0-1 |
| **ai-rag** | 결재 규정 (지출지침) 검색 | 기존 |
| **Gemma-4 31B** | 기안문 초안 생성 | 기존 |

**상세**: [external-dependencies.md](external-dependencies.md)

---

## 3. 폴더 구성

| 파일 | 내용 |
|------|------|
| [README.md](README.md) | 본 문서 |
| [external-dependencies.md](external-dependencies.md) | 외부 시스템 요건 |
| [erp-mcp-tools.md](erp-mcp-tools.md) | `get_expense_info` 신규 도구 |
| [groupware-mcp-tools.md](groupware-mcp-tools.md) | `get_approval_route`, `create_approval_draft`, `get_doc_template` |
| [db-schemas.sql](db-schemas.sql) | 결재선·양식·지출예산 뷰/테이블 |
| [api-samples.json](api-samples.json) | E2E 요청/응답 샘플 (출장비 시나리오) |
| [prompt-templates.md](prompt-templates.md) | 기안문 생성 프롬프트 + Few-shot |

---

## 4. 구현 체크리스트

### Phase 1 — ERP/Groupware MCP 도구 (D1, 4일)

```
[erp-mcp — 신규 도구 1종]
□ get_expense_info.py
  - 입력: emp_cd, doc_type (TRIP/PURCHASE/OVERTIME), amount, ref_period
  - 출력: { budget_balance, past_expenses[], expense_limit, required_docs }

[groupware-mcp — 신규 도구 4종]
□ get_approval_list (결재 대기 목록)
□ get_approval_detail (결재 상세)
□ create_approval_draft (기안 초안 등록)
□ get_approval_route (결재선 추천)
□ get_doc_template (양식 조회)
```

### Phase 2 — ai-assistant 결재기안 그래프 (D1, 5일)

```
[신규 그래프 — apps/ai-assistant/src/graph/graphs/approval_draft_graph.py]
□ classify_doc_type 노드 (재사용: classify_node)
□ parallel_fetch 노드 (erp + groupware 병렬)
□ generate_draft 노드 (Gemma-4 초안 생성)
□ validate_against_rag 노드 (규정 적합성)
□ register_or_save 노드 (groupware-mcp 호출)

[프롬프트 — apps/ai-assistant/src/prompts/modes/approval_draft.py]
□ 3종 Few-shot (출장비/물품구매/초과근무)
□ JSON 구조 응답 강제
```

### Phase 3 — chat-web UI (D2, 3일)

```
□ ApprovalDraftCard.tsx
  - 초안 본문 표시 (편집 가능)
  - 결재선 바 (승인자 이름/직급)
  - 첨부 지출 내역 요약
  - [수정·제출·취소] 버튼
```

---

## 5. 고객 결정 포인트 (7개)

[../15-per-challenge-decision-points.md#-과제-1--전자결재-자동-기안-및-분류](../15-per-challenge-decision-points.md)

핵심:
- D1-01 문서 유형 3종 vs 5종 vs 10종
- D1-02 자동/수동 등록 정책
- D1-03 결재선 추천 알고리즘

---

## 6. 관련 문서

- [../01-intelligent-workflow.md](../01-intelligent-workflow.md) — 원본 과제
- [../03-personal-assistant/](../03-personal-assistant/) — groupware-mcp 기본 도구 공유
- [../../design/groupware-mcp.md](../../design/groupware-mcp.md) — groupware-mcp 설계
