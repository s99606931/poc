# chat-web 서비스 개선 태스크 (POC 대응)

> **서비스**: `projects/10_alli-work/apps/chat-web`
> **현재 포트**: 3000
> **기술**: Next.js 15 + RxJS + SSE 스트리밍
> **POC 역할**: 규정 Q&A 채팅 UI (POC 2) + 업무 자동화 챗봇 UI (POC 1)
> **작성일**: 2026-04-21

> **📌 POC 확장 범위 요약**
> 기존 단일 `page.tsx` 유지, slot 패턴으로 신규 카드 컴포넌트 3종 추가:
> - `ApprovalDraftCard` (과제 1 결재 기안)
> - `RegulationCitationPanel` (과제 4 규정 근거 조항)
> - `PersonalTaskCard` (과제 3 업무 리마인드)

---

## 현재 상태

```
✅ 범용 채팅 인터페이스 (SSE 스트리밍)
✅ 채팅 이력 관리
✅ 마크다운 렌더링
❌ 규정 Q&A 모드 (출처 조항 패널 없음)
❌ ERP 업무 자동화 전용 UI 없음
❌ 결재 기안 미리보기 UI 없음
❌ 업무 우선순위 카드 UI 없음
```

---

## 개선 태스크

### TASK-CWEB-01 규정 Q&A 전용 모드

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (POC 2 핵심) |
| **예상 공수** | 3일 |
| **담당** | 프론트엔드 중급 |

#### 채팅 모드 선택 UI

```tsx
// app/(chat)/page.tsx — 채팅 시작 시 모드 선택

const CHAT_MODES = [
  {
    id: 'erp',
    title: '업무 자동화',
    description: '결재 기안, 업무 리마인드, 일정 관리',
    icon: <ClipboardListIcon aria-hidden="true" />,
  },
  {
    id: 'regulation',
    title: '규정 Q&A',
    description: '인사/복무/회계 규정 자연어 검색',
    icon: <BookOpenIcon aria-hidden="true" />,
  },
  {
    id: 'general',
    title: '일반 대화',
    description: '범용 AI 어시스턴트',
    icon: <MessageSquareIcon aria-hidden="true" />,
  },
]

function ChatModeSelector({ onSelect }: { onSelect: (mode: string) => void }) {
  return (
    <div role="list" aria-label="채팅 모드 선택">
      {CHAT_MODES.map(mode => (
        <div
          key={mode.id}
          role="listitem"
        >
          <button
            className="w-full text-left p-4 rounded-lg border border-gray-200 dark:border-gray-700 hover:border-brand-500 focus-visible:ring-2 focus-visible:ring-brand-500"
            onClick={() => onSelect(mode.id)}
            aria-label={`${mode.title} 모드 선택: ${mode.description}`}
          >
            <div className="flex items-center gap-3">
              {mode.icon}
              <div>
                <p className="font-medium">{mode.title}</p>
                <p className="text-sm text-gray-500 dark:text-gray-400">{mode.description}</p>
              </div>
            </div>
          </button>
        </div>
      ))}
    </div>
  )
}
```

#### 규정 Q&A 전용 채팅 UI

```tsx
// components/chat/RegulationChatMessage.tsx

interface RegulationAnswer {
  answer: string
  regulation_refs: Array<{
    regulation_name: string
    article_no: number
    article_title: string
    content: string
  }>
  additional_notes?: string
}

function RegulationChatMessage({ message }: { message: RegulationAnswer }) {
  return (
    <div className="space-y-3">
      {/* 핵심 답변 */}
      <div className="prose dark:prose-invert max-w-none">
        <ReactMarkdown>{message.answer}</ReactMarkdown>
      </div>
      
      {/* 근거 조항 패널 — 색상 + 아이콘 병행 (WCAG 1.4.1) */}
      {message.regulation_refs.length > 0 && (
        <div className="rounded-lg border border-brand-200 dark:border-brand-800 bg-brand-50 dark:bg-brand-950 p-3">
          <p className="text-sm font-medium text-brand-700 dark:text-brand-300 flex items-center gap-1.5">
            <BookOpenIcon className="size-4" aria-hidden="true" />
            근거 조항
          </p>
          <ul className="mt-2 space-y-1" aria-label="근거 규정 조항 목록">
            {message.regulation_refs.map((ref, i) => (
              <li key={i} className="text-sm">
                <span className="font-medium">{ref.regulation_name}</span>
                {' '}제{ref.article_no}조({ref.article_title})
                <p className="text-gray-600 dark:text-gray-400 text-xs mt-0.5 pl-3">{ref.content}</p>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
```

---

### TASK-CWEB-02 업무 자동화 전용 UI 컴포넌트

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (POC 1 핵심) |
| **예상 공수** | 3일 |
| **담당** | 프론트엔드 중급 |

#### 결재 기안 미리보기 카드

```tsx
// components/chat/ApprovalDraftCard.tsx
// AI가 생성한 결재 기안 초안을 카드 형태로 표시

interface ApprovalDraft {
  doc_type: string
  title: string
  content: string
  amount?: number
  approval_route: string[]
  draft_url?: string
}

function ApprovalDraftCard({ draft }: { draft: ApprovalDraft }) {
  return (
    <div className="rounded-lg border border-gray-200 dark:border-gray-700 p-4 space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="font-medium">{draft.title}</h3>
        <Badge color="warning">초안</Badge>
      </div>
      
      {/* 결재선 표시 */}
      <div aria-label="결재선">
        <p className="text-xs text-gray-500 mb-1">결재선</p>
        <div className="flex items-center gap-2">
          {draft.approval_route.map((approver, i) => (
            <React.Fragment key={i}>
              <span className="text-sm px-2 py-0.5 rounded bg-gray-100 dark:bg-gray-800">
                {approver}
              </span>
              {i < draft.approval_route.length - 1 && (
                <ArrowRightIcon className="size-3 text-gray-400" aria-hidden="true" />
              )}
            </React.Fragment>
          ))}
        </div>
      </div>
      
      {/* 기안 내용 미리보기 */}
      <div className="text-sm text-gray-600 dark:text-gray-400 line-clamp-3">
        {draft.content}
      </div>
      
      {/* 등록 버튼 */}
      <div className="flex gap-2">
        <Button size="sm" onClick={() => registerDraft(draft)}>
          그룹웨어에 등록
        </Button>
        <Button size="sm" variant="outline" onClick={() => editDraft(draft)}>
          수정 후 등록
        </Button>
      </div>
    </div>
  )
}
```

#### 업무 우선순위 카드

```tsx
// components/chat/TaskPriorityCard.tsx
// 개인 비서 응답: 오늘 할일 우선순위 카드

function TaskPriorityCard({ tasks }: { tasks: TaskItem[] }) {
  return (
    <div className="space-y-2" aria-label="오늘 업무 목록">
      {tasks.map((task, i) => (
        <div key={i} className={cn(
          "flex items-start gap-3 p-3 rounded-lg border",
          task.urgency === 'urgent' 
            ? "border-error-300 bg-error-50 dark:bg-error-950" 
            : "border-gray-200 dark:border-gray-700"
        )}>
          {/* 색상 + 아이콘 + 텍스트 모두 표시 (접근성) */}
          <div className={cn(
            "size-6 rounded-full flex items-center justify-center flex-shrink-0 text-xs font-bold text-white",
            task.urgency === 'urgent' ? 'bg-error-500' : 
            task.urgency === 'today' ? 'bg-warning-500' : 'bg-gray-400'
          )} aria-label={`우선순위 ${i + 1}`}>
            {i + 1}
          </div>
          <div className="flex-1 min-w-0">
            <p className="font-medium text-sm">{task.title}</p>
            <p className="text-xs text-gray-500 mt-0.5">
              마감: {formatDate(task.deadline)} ({task.d_day}일 남음)
            </p>
          </div>
          <Badge color={task.urgency === 'urgent' ? 'error' : task.urgency === 'today' ? 'warning' : 'light'}>
            {task.urgency === 'urgent' ? '긴급' : task.urgency === 'today' ? '오늘' : '예정'}
          </Badge>
        </div>
      ))}
    </div>
  )
}
```

---

### TASK-CWEB-03 채팅 라우팅 (모드별 백엔드 분기)

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 |
| **예상 공수** | 1일 |

```typescript
// chat-web에서 선택된 모드를 chat-api로 전달
// chat-api → ai-assistant 라우팅 시 intent 힌트 제공

interface ChatRequest {
  message: string
  chat_mode: 'erp' | 'regulation' | 'general'  // 신규
  conversation_id: string
}

// 메시지 전송 시 모드 포함
async function sendMessage(text: string) {
  const request: ChatRequest = {
    message: text,
    chat_mode: currentMode,  // 선택된 모드
    conversation_id: conversationId,
  }
  // SSE 스트리밍 요청
  const stream = await chatApiClient.streamMessage(request)
}
```

---

## 완료 체크리스트

```
□ TASK-CWEB-01: 채팅 모드 선택 UI 구현 (3종 모드)
□ TASK-CWEB-01: 규정 Q&A 답변 컴포넌트 (근거 조항 패널 포함)
□ TASK-CWEB-02: 결재 기안 미리보기 카드 컴포넌트
□ TASK-CWEB-02: 업무 우선순위 카드 컴포넌트
□ TASK-CWEB-03: 채팅 모드 → 백엔드 라우팅 연동
□ SSE 스트리밍 중 규정 조항 패널 점진적 표시 테스트
□ 접근성 체크 (모든 신규 컴포넌트)
□ 다크모드 동작 확인
```
