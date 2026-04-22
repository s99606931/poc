# chat-api 서비스 개선 태스크 (POC 대응)

> **서비스**: `projects/10_alli-work/apps/chat-api`
> **현재 포트**: 4002
> **기술**: NestJS 11 + SSE 스트리밍 + PostgreSQL
> **POC 역할**: 채팅 라우팅 중계 (POC 1, 2 공통) — 모드별 ai-assistant 라우팅
> **작성일**: 2026-04-21

> **📌 POC 확장 범위 요약**
> 핵심 작업: **chat_mode 라우팅** (erp_approval / personal_assistant / regulation_qa / general).
> SSE 패턴은 `admin-api notify 모듈`에서도 재사용.

---

## 현재 상태

```
✅ SSE 스트리밍 채팅 API
✅ 대화 이력 저장 (PostgreSQL)
✅ JWT 인증 연동
✅ ai-assistant 기본 라우팅
❌ 채팅 모드(chat_mode) 파라미터 미지원
❌ 규정 Q&A 모드 → ai-rag 직접 라우팅 없음
❌ 업무 자동화 모드 → 전용 시나리오 라우팅 없음
❌ 응답 타입 구분 (일반 텍스트 vs 구조화 데이터) 없음
❌ 채팅 세션 모드 저장 없음
```

---

## 개선 태스크

### TASK-CAPI-01 채팅 모드 파라미터 지원

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (chat-web 연동 필수) |
| **예상 공수** | 1일 |
| **담당** | 백엔드 중급 |

#### DTO 확장

```typescript
// chat-api/src/chat/dto/send-message.dto.ts

import { z } from 'zod'

export const ChatModeEnum = z.enum(['erp', 'regulation', 'general'])
export type ChatMode = z.infer<typeof ChatModeEnum>

export const SendMessageDtoSchema = z.object({
  message: z.string().min(1).max(4000),
  conversation_id: z.string().uuid(),
  chat_mode: ChatModeEnum.default('general'),  // 신규 필드
  // 선택적: 이전 컨텍스트 힌트
  context_hint: z.object({
    regulation_category: z.enum(['hr', 'finance', 'general', 'security']).optional(),
    emp_cd: z.string().optional(),
  }).optional(),
})

export type SendMessageDto = z.infer<typeof SendMessageDtoSchema>
```

#### 대화 세션 모드 저장

```typescript
// chat-api/src/chat/entities/conversation.entity.ts 수정

@Entity('conversations')
export class ConversationEntity {
  @PrimaryGeneratedColumn('uuid')
  id: string;

  @Column({ name: 'user_id' })
  userId: string;

  @Column({ name: 'chat_mode', default: 'general' })
  chatMode: string;  // 신규: 세션 모드 저장

  @Column({ name: 'tenant_id' })
  tenantId: string;

  @CreateDateColumn({ name: 'created_at' })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at' })
  updatedAt: Date;
}
```

---

### TASK-CAPI-02 모드별 ai-assistant 라우팅

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 |
| **예상 공수** | 2일 |
| **담당** | 백엔드 중급 |

```typescript
// chat-api/src/chat/chat-routing.service.ts

import { Injectable } from '@nestjs/common'
import { HttpService } from '@nestjs/axios'
import { ConfigService } from '@nestjs/config'
import type { ChatMode } from './dto/send-message.dto'

interface RouteRequest {
  message: string
  conversation_id: string
  chat_mode: ChatMode
  emp_cd: string
  tenant_id: string
  context_hint?: Record<string, string>
}

@Injectable()
export class ChatRoutingService {
  constructor(
    private readonly http: HttpService,
    private readonly config: ConfigService,
  ) {}

  /**
   * 채팅 모드에 따라 적절한 AI 서비스로 라우팅
   * - regulation: ai-rag 직접 라우팅 (규정 Q&A 전용)
   * - erp: ai-assistant → erp_approval_graph 시나리오
   * - general: ai-assistant → 일반 그래프
   */
  async routeMessage(req: RouteRequest): Promise<AsyncIterable<string>> {
    const routeTarget = this.getRouteTarget(req.chat_mode)
    
    if (req.chat_mode === 'regulation') {
      return this.routeToRag(req)
    }
    
    return this.routeToAssistant(req, routeTarget)
  }

  private getRouteTarget(mode: ChatMode): string {
    const routes: Record<ChatMode, string> = {
      'erp':        'erp_approval_graph',
      'regulation': 'regulation_qa_graph',
      'general':    'general_chat_graph',
    }
    return routes[mode]
  }

  private async routeToRag(req: RouteRequest): Promise<AsyncIterable<string>> {
    // 규정 Q&A: ai-rag SSE 직접 스트리밍
    const ragUrl = this.config.get('AI_RAG_URL')  // http://ai-rag:4006
    const response = await this.http.axiosRef.post(
      `${ragUrl}/v1/rag/stream`,
      {
        question: req.message,
        partition: this.getRegulationPartition(req.context_hint),
        conversation_id: req.conversation_id,
        tenant_id: req.tenant_id,
        response_format: 'regulation_qa',  // 조항 구조화 응답 요청
      },
      {
        responseType: 'stream',
        headers: { 'Accept': 'text/event-stream' }
      }
    )
    return response.data
  }

  private async routeToAssistant(
    req: RouteRequest,
    scenario: string
  ): Promise<AsyncIterable<string>> {
    // ERP/General: ai-assistant SSE 스트리밍
    const assistantUrl = this.config.get('AI_ASSISTANT_URL')  // http://ai-assistant:4005
    const response = await this.http.axiosRef.post(
      `${assistantUrl}/v1/chat/stream`,
      {
        message: req.message,
        scenario: scenario,
        conversation_id: req.conversation_id,
        emp_cd: req.emp_cd,
        tenant_id: req.tenant_id,
      },
      {
        responseType: 'stream',
        headers: { 'Accept': 'text/event-stream' }
      }
    )
    return response.data
  }

  private getRegulationPartition(hint?: Record<string, string>): string {
    const categoryMap: Record<string, string> = {
      'hr':       'regulation_hr',
      'finance':  'regulation_finance',
      'general':  'regulation_general',
      'security': 'regulation_security',
    }
    return categoryMap[hint?.regulation_category ?? ''] ?? 'regulation_hr'
  }
}
```

---

### TASK-CAPI-03 구조화 응답 타입 처리 (SSE 이벤트 타입 확장)

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 |
| **예상 공수** | 2일 |
| **담당** | 백엔드 중급 |

```typescript
// chat-api/src/chat/sse-event.types.ts
// SSE 이벤트 타입 정의 — chat-web이 파싱하는 포맷

/**
 * SSE 이벤트 타입별 데이터 구조.
 * chat-web의 chatReducer가 이 타입에 따라 렌더링을 분기.
 */

// 일반 텍스트 스트리밍 (모든 모드 공통)
export type TextChunkEvent = {
  type: 'text_chunk'
  content: string
  is_final: boolean
}

// 규정 Q&A 전용: 근거 조항 패널
export type RegulationRefsEvent = {
  type: 'regulation_refs'
  refs: Array<{
    regulation_name: string
    article_no: number
    article_title: string
    content: string
    effective_date: string
  }>
}

// ERP 자동화 전용: 결재 기안 초안
export type ApprovalDraftEvent = {
  type: 'approval_draft'
  draft: {
    doc_type: string
    title: string
    content: string
    amount?: number
    approval_route: string[]
    draft_url?: string
  }
}

// 개인 비서 전용: 업무 우선순위 목록
export type TaskPriorityEvent = {
  type: 'task_priority'
  tasks: Array<{
    title: string
    deadline: string
    d_day: number
    urgency: 'urgent' | 'today' | 'scheduled'
    source: 'erp' | 'groupware'
  }>
}

// 오류 이벤트
export type ErrorEvent = {
  type: 'error'
  message: string
  code: string
}

// 완료 이벤트
export type DoneEvent = {
  type: 'done'
  conversation_id: string
  message_id: string
}

export type SSEEvent = 
  | TextChunkEvent 
  | RegulationRefsEvent 
  | ApprovalDraftEvent 
  | TaskPriorityEvent
  | ErrorEvent
  | DoneEvent
```

```typescript
// chat-api/src/chat/chat.controller.ts (SSE 응답 처리)

@Post('stream')
@UseGuards(JwtAuthGuard)
async streamMessage(
  @Body() dto: SendMessageDto,
  @Req() req: AuthenticatedRequest,
  @Res() res: Response,
): Promise<void> {
  // SSE 헤더 설정
  res.setHeader('Content-Type', 'text/event-stream')
  res.setHeader('Cache-Control', 'no-cache')
  res.setHeader('Connection', 'keep-alive')
  res.setHeader('X-Accel-Buffering', 'no')  // Nginx 버퍼링 비활성화

  // 세션 모드 업데이트
  await this.chatService.updateConversationMode(
    dto.conversation_id,
    dto.chat_mode,
    req.user.tenantId
  )

  // 모드별 라우팅
  const stream = await this.routingService.routeMessage({
    message: dto.message,
    conversation_id: dto.conversation_id,
    chat_mode: dto.chat_mode,
    emp_cd: req.user.empCd,
    tenant_id: req.user.tenantId,
    context_hint: dto.context_hint,
  })

  // SSE 이벤트 스트리밍
  for await (const chunk of stream) {
    if (res.destroyed) break
    res.write(`data: ${JSON.stringify(chunk)}\n\n`)
  }

  res.write(`data: ${JSON.stringify({ type: 'done' })}\n\n`)
  res.end()
}
```

---

### TASK-CAPI-04 대화 이력에 모드 및 구조화 응답 저장

| 항목 | 내용 |
|------|------|
| **우선순위** | P1 |
| **예상 공수** | 1일 |
| **담당** | 백엔드 중급 |

```typescript
// chat-api/src/chat/entities/message.entity.ts 확장

@Entity('messages')
export class MessageEntity {
  @PrimaryGeneratedColumn('uuid')
  id: string;

  @Column({ name: 'conversation_id' })
  conversationId: string;

  @Column({ name: 'role' })
  role: 'user' | 'assistant';

  @Column({ name: 'content', type: 'text' })
  content: string;  // 텍스트 응답 (항상)

  @Column({ name: 'structured_data', type: 'jsonb', nullable: true })
  structuredData: object;  // 신규: regulation_refs / approval_draft / task_priority

  @Column({ name: 'chat_mode', default: 'general' })
  chatMode: string;  // 신규: 응답 시 사용된 모드

  @CreateDateColumn({ name: 'created_at' })
  createdAt: Date;
}
```

---

## 완료 체크리스트

```
□ TASK-CAPI-01: SendMessageDto에 chat_mode 필드 추가
□ TASK-CAPI-01: ConversationEntity에 chatMode 컬럼 추가 + 마이그레이션
□ TASK-CAPI-02: ChatRoutingService 구현 (3모드 분기)
□ TASK-CAPI-02: regulation 모드 → ai-rag SSE 프록시 동작 확인
□ TASK-CAPI-02: erp 모드 → ai-assistant erp_approval_graph 라우팅 확인
□ TASK-CAPI-03: SSE 이벤트 타입 5종 (text_chunk, regulation_refs, approval_draft, task_priority, done)
□ TASK-CAPI-04: MessageEntity에 structuredData + chatMode 컬럼 추가
□ pnpm typecheck:all 통과
□ chat-web ↔ chat-api ↔ ai-assistant E2E SSE 스트리밍 테스트
□ 규정 Q&A 모드: 조항 패널 포함 응답 E2E 테스트
□ SSE 연결 끊김 재연결 테스트 (chat-web RxJS 연동)
```
