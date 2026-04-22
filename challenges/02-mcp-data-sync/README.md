# 과제 2 — ERP-그룹웨어 동기화 구현 가이드 (2단계 연기 권장)

> **작성일**: 2026-04-21
> **과제 문서**: [../02-mcp-data-sync.md](../02-mcp-data-sync.md)
> **구현 기간**: 2주
> **재사용률**: 75%
> **상태**: ⚠️ 시나리오 B에서 **2단계 연기** (본 사업 전환 시 구현)

---

## 1. 구현 개요

ERP 인사·조직 데이터와 그룹웨어 인사·조직 데이터를 주기적으로 동기화하여 불일치를 해소.

### 데이터 흐름

```
APScheduler (30분 주기) → sync_graph
  ├─ fetch_erp_hr (erp-mcp.get_hr_info)
  ├─ fetch_gw_hr (groupware-mcp.get_hr_info)
  ├─ diff_detect (비교 로직)
  ├─ sync_execute (groupware-mcp.sync_erp_to_groupware) ← Write!
  └─ log_result (alli-audit 저장)
```

---

## 2. 외부 의존성

| 시스템 | Read | Write |
|--------|:---:|:---:|
| ERP DB | ✅ | — |
| 그룹웨어 | ✅ | **🔴 필수 (P0-1)** |

🔴 **P0-1 그룹웨어 Write 권한 없으면 과제 2 불가** — [상세](../15-per-challenge-decision-points.md#-d2-06-미확정-시-영향--과제-2-전체-불가-사유)

---

## 3. 폴더 구성

| 파일 | 내용 |
|------|------|
| [README.md](README.md) | 본 문서 |
| [external-dependencies.md](external-dependencies.md) | 외부 시스템 요건 + Write 권한 상세 |
| [mcp-tools.md](mcp-tools.md) | erp-mcp + groupware-mcp 도구 |
| [db-schemas.sql](db-schemas.sql) | 인사/조직 데이터 매핑 테이블 |
| [api-samples.json](api-samples.json) | 동기화 시나리오 샘플 |
| [diff-detection-logic.md](diff-detection-logic.md) | 불일치 탐지 알고리즘 |

---

## 4. 구현 체크리스트

```
[erp-mcp 확장]
□ get_hr_info (인사 정보 조회)
□ get_org_structure (조직도 조회)

[groupware-mcp 신규]
□ get_hr_info (그룹웨어 측 인사)
□ sync_erp_to_groupware (Write!)
□ update_org_chart (Write!)

[ai-assistant — sync_graph]
□ fetch 병렬 (erp + gw)
□ diff_detect (필드별 비교)
□ sync_execute (배치 단위 100건)
□ log_result (alli-audit)

[admin-api 확장]
□ 동기화 이력 조회 API
□ 수동 트리거 API
```

## 5. 관련 문서

- [../02-mcp-data-sync.md](../02-mcp-data-sync.md) — 원본 과제
- [../01-intelligent-workflow/](../01-intelligent-workflow/) — groupware-mcp 기본 도구 공유
