# 고객 협의 자료 — 인덱스

> **기준일**: 2026-04-22
> **대상**: 고객사 미팅 진행 및 합의 자료

---

## 📋 문서 목록

| 문서 | 용도 | 대상 |
|------|------|------|
| [checklist.md](checklist.md) | 착수 전 44개 필수 확인 항목 (인프라/법/보안/데이터) | 고객사 + PM |
| [meeting-guide.md](meeting-guide.md) | 고객 미팅 의제 + 확인 항목 + 백데이터 링크 | 고객사 미팅 |

## 관련 의사결정 문서

| 문서 | 위치 |
|------|------|
| 과제별 73 결정 포인트 | [../challenges/decisions.md](../challenges/decisions.md) |
| 사전 요건 (ERP/그룹웨어/감사) | [../04-prerequisites.md](../04-prerequisites.md) |
| 예산 상세 | [../03-budget.md](../03-budget.md) |

---

## 고객 미팅 진행 흐름

```mermaid
%%{init: {'theme': 'dark', 'themeVariables': {'primaryColor': '#1d4ed8', 'primaryTextColor': '#f8fafc', 'primaryBorderColor': '#3b82f6', 'lineColor': '#94a3b8', 'secondaryColor': '#1e293b', 'tertiaryColor': '#0f172a'}}}%%
graph LR
    S["킥오프<br/>(D-14)"] --> M1["1차 미팅<br/>체크리스트 44 합의"]
    M1 --> M2["2차 미팅<br/>과제별 결정 포인트 73"]
    M2 --> M3["3차 미팅<br/>최종 합의 + 계약 부록"]
    M3 --> K["개발 착수<br/>(W1)"]

    style K fill:#059669,stroke:#047857,color:#fff
```
