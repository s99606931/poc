# 과제 3 개인비서 — LLM 프롬프트 템플릿

> **대상 LLM**: gemma-4-31B-it-AWQ (vllm-vision :6012)
> **파일 위치**: `apps/ai-assistant/src/prompts/modes/personal_assistant.py`

---

## 1. 시스템 프롬프트

```python
PERSONAL_ASSISTANT_SYSTEM = """당신은 대한민국 행정기관 담당자를 위한 업무 비서 AI입니다.
담당자의 오늘 할 일을 아이젠하워 매트릭스(Eisenhower Matrix)에 따라
긴급도·중요도로 분류하고 우선순위를 정렬하여 실행 순서를 제안합니다.

[원칙]
1. 규정 마감(월결산·예산제출)은 놓치면 부서 전체에 영향 → 우선순위 최상위
2. 회의·면담은 시간 고정 업무 → 해당 시간대에 수행
3. 결재 재촉은 중요도 낮음 → 짧은 시간 투입 (메신저 1건)
4. 선택 행사는 Q4 → 시간 여유 시만 참석

[점수 산정]
- urgency (긴급도 1~10): days_remaining 이 적을수록 높음 (오늘=10)
- importance (중요도 1~10): HIGH=10 / MEDIUM=6 / LOW=3
- total_score = urgency × importance

[Quadrant]
- Q1 (긴급·중요): urgency≥7 AND importance≥7 → "즉시 실행"
- Q2 (비긴급·중요): urgency<7 AND importance≥7 → "계획적으로"
- Q3 (긴급·비중요): urgency≥7 AND importance<7 → "위임 or 빠르게"
- Q4 (비긴급·비중요): 나머지 → "여유 시 or 제거"

[출력 형식]
반드시 JSON 객체로 응답하고 추가 텍스트 금지.
개인정보(타인의 전체 이름)는 원본 그대로 전달된 마스킹을 유지.
"""
```

---

## 2. 사용자 프롬프트 템플릿

### 2.1 analyze_priority_node 입력

```python
ANALYZE_PRIORITY_USER_TEMPLATE = """다음은 {emp_name}({dept_nm} {position})님의 {date} 업무 데이터입니다.
아이젠하워 매트릭스로 우선순위를 정렬해주세요.

## 1. ERP 마감 업무 ({len_deadline}건)
{deadline_tasks_summary}

## 2. ERP 미결재 항목 ({len_pending}건)
{pending_items_summary}

## 3. 그룹웨어 오늘 일정 ({len_schedules}건)
{schedules_summary}

## 4. 결재 대기 (본인이 결재자) ({len_approvals}건)
{approvals_summary}

## 현재 시간
{current_time}

## 출력 JSON 형식
{{
  "priorities": [
    {{
      "task_id": "...",          // task_id 또는 item_id 또는 schedule_id 또는 approval_id
      "task_title": "...",
      "source": "deadline|pending|schedule|approval",
      "urgency_score": 0~10,
      "importance_score": 0~10,
      "total_score": 0~100,
      "quadrant": "Q1|Q2|Q3|Q4",
      "quadrant_label": "긴급·중요|...",
      "reason": "1문장 근거"
    }}
  ]
}}

모든 업무를 누락 없이 포함하고, total_score 내림차순 정렬.
"""
```

### 2.2 generate_guide_node 입력

```python
GENERATE_GUIDE_SYSTEM = PERSONAL_ASSISTANT_SYSTEM + """

[가이드 작성 원칙]
1. 2~3문장 요약으로 시작 (가장 중요한 1~2건 언급)
2. 시간 순서(오늘 일과)로 실행 순서 제안
3. 긴급 연락 액션(결재 재촉 등)은 별도 표시
4. 선택 업무는 "여유 시" 명확히 구분
"""

GENERATE_GUIDE_USER_TEMPLATE = """다음은 우선순위 분석 결과입니다.
{priorities_json}

이를 바탕으로 {emp_name}님께 드릴 업무 가이드를 JSON 형식으로 생성해주세요.

## 현재 시간
{current_time}

## 출력 JSON 형식
{{
  "summary": "2~3문장 요약",
  "current_time": "{current_time}",
  "matrix": {{
    "q1_urgent_important": [
      {{"id": "...", "time": "10:00~11:00 또는 D-0 18:00", "title": "...", "category": "...", "link": "..."}}
    ],
    "q2_important_not_urgent": [...],
    "q3_urgent_not_important": [...],
    "q4_not_urgent_not_important": [...]
  }},
  "recommended_action_sequence": [
    "① [HH:MM~HH:MM] 행동 서술",
    "② ...",
    "... (5개 이내)"
  ],
  "follow_ups": [
    {{"label": "월결산 시작", "action": "open_url", "value": "URL"}},
    {{"label": "과장님께 결재 재촉", "action": "send_message", "value": {{"to": "emp_cd", "template": "..."}}}},
    {{"label": "선택 일정 불참 응답", "action": "gw_decline", "value": "schedule_id"}}
  ]
}}

personal_assistant_card 이벤트로 SSE 전송될 예정.
"""
```

---

## 3. Few-shot 예시 (행정 도메인 특화)

```python
FEW_SHOT_EXAMPLES = [
    {
        "role": "user",
        "content": "[요약] 오늘 4월 월결산 마감(18:00). 회계부 회의 10:00~11:00. 출장비 결재 3일 대기 중."
    },
    {
        "role": "assistant",
        "content": """{
  "priorities": [
    {"task_id": "ACC-CLOSE-202604-001", "urgency_score": 10, "importance_score": 10, "total_score": 100, "quadrant": "Q1", "reason": "오늘 18:00 마감 + 부서 전체 업무"},
    {"task_id": "GW-SCH-20260421-042", "urgency_score": 9, "importance_score": 8, "total_score": 72, "quadrant": "Q1", "reason": "시간 고정 + 월결산 연계"},
    {"task_id": "EXP-20260418-001", "urgency_score": 6, "importance_score": 4, "total_score": 24, "quadrant": "Q3", "reason": "결재 재촉은 빠르게 처리"}
  ]
}"""
    }
]
```

---

## 4. 데이터 요약 헬퍼 함수

```python
# apps/ai-assistant/src/graph/graphs/personal_assistant_graph.py

def _summarize_deadline_tasks(tasks: list) -> str:
    if not tasks:
        return "(없음)"
    lines = []
    for t in tasks:
        urgency = "🔴" if t["days_remaining"] == 0 else "🟡" if t["days_remaining"] <= 3 else "🟢"
        lines.append(
            f"- [{t['task_id']}] {urgency} {t['title']} "
            f"(마감: D-{t['days_remaining']}, 중요도: {t['importance']})"
        )
    return "\n".join(lines)

def _summarize_pending_items(items: list) -> str:
    if not items:
        return "(없음)"
    return "\n".join(
        f"- [{i['item_id']}] {i['title']} "
        f"(대기: {i['waiting_days']}일, 결재자: {i['current_approver']['emp_nm']} {i['current_approver']['position']})"
        for i in items
    )

def _summarize_schedules(schedules: list) -> str:
    if not schedules:
        return "(없음)"
    return "\n".join(
        f"- [{s['schedule_id']}] {s['start_dt'][11:16]}~{s['end_dt'][11:16]} "
        f"{s['title']} ({s['location'] or '장소 미정'}, 중요도: {s['importance']})"
        for s in schedules
    )

def _summarize_approvals(approvals: list) -> str:
    if not approvals:
        return "(없음 — 본인은 결재자가 아님)"
    return "\n".join(
        f"- [{a['approval_id']}] {a['title']} "
        f"(요청: {a['requester']['emp_nm']}, 대기: {a['waiting_hours']}시간)"
        for a in approvals
    )
```

---

## 5. 프롬프트 조립

```python
# personal_assistant_graph.py 내부

async def analyze_priority_node(state: PersonalAssistantState) -> dict:
    user_prompt = ANALYZE_PRIORITY_USER_TEMPLATE.format(
        emp_name=state.emp_name,
        dept_nm=state.dept_nm,
        position=state.position,
        date=state.date,
        current_time=state.current_time,
        len_deadline=len(state.deadline_tasks),
        len_pending=len(state.pending_items),
        len_schedules=len(state.schedules),
        len_approvals=len(state.approvals),
        deadline_tasks_summary=_summarize_deadline_tasks(state.deadline_tasks),
        pending_items_summary=_summarize_pending_items(state.pending_items),
        schedules_summary=_summarize_schedules(state.schedules),
        approvals_summary=_summarize_approvals(state.approvals),
    )

    response = await llm_client.chat_completions(
        model="coder",
        messages=[
            {"role": "system", "content": PERSONAL_ASSISTANT_SYSTEM},
            *FEW_SHOT_EXAMPLES,
            {"role": "user", "content": user_prompt},
        ],
        max_tokens=800,
        temperature=0.1,
        response_format={"type": "json_object"},
    )

    return {"priorities": response["priorities"]}
```

---

## 6. 규칙 기반 Fallback

LLM 타임아웃/에러 시 대체 로직:

```python
def rule_based_priority_fallback(state: PersonalAssistantState) -> list:
    """LLM 없이 단순 규칙으로 우선순위 산정"""
    all_tasks = []

    for t in state.deadline_tasks:
        urgency = max(0, 10 - t["days_remaining"] * 2)
        importance = {"HIGH": 10, "MEDIUM": 6, "LOW": 3}[t["importance"]]
        all_tasks.append({
            "task_id": t["task_id"],
            "task_title": t["title"],
            "source": "deadline",
            "urgency_score": urgency,
            "importance_score": importance,
            "total_score": urgency * importance,
            "quadrant": _assign_quadrant(urgency, importance),
            "reason": f"D-{t['days_remaining']} 마감",
        })

    for s in state.schedules:
        now = datetime.now()
        start = datetime.fromisoformat(s["start_dt"].replace("Z", "+00:00"))
        hours_until = (start - now).total_seconds() / 3600
        urgency = 10 if hours_until <= 2 else 8 if hours_until <= 8 else 5
        importance = {"HIGH": 10, "MEDIUM": 6, "LOW": 3}[s["importance"]]
        all_tasks.append({
            "task_id": s["schedule_id"],
            "task_title": s["title"],
            "source": "schedule",
            "urgency_score": urgency,
            "importance_score": importance,
            "total_score": urgency * importance,
            "quadrant": _assign_quadrant(urgency, importance),
            "reason": f"{hours_until:.0f}시간 후 시작",
        })

    # pending, approvals도 유사

    return sorted(all_tasks, key=lambda x: -x["total_score"])
```

---

## 7. 품질 평가 기준

| 지표 | 목표 | 측정 방법 |
|------|:---:|---------|
| 우선순위 정확도 | ≥ 80% | 전문가 20명 × 5시나리오 평가 |
| JSON 파싱 성공률 | 100% | response_format=json_object |
| 응답 시간 (LLM) | ≤ 2초 | E2E 측정 |
| 할루시네이션 | 0건 | task_id 원본 일치 검증 |

---

## 8. 관련 문서

- [README.md](README.md)
- [architecture.md](architecture.md) — 전체 구성도
- [api-samples.json](api-samples.json) — step 6 우선순위 분석 샘플
- [../../services/improvements/ai-llm.md](../../services/improvements/ai-llm.md) — 프롬프트 라이브러리 (TASK-LLM-01)
