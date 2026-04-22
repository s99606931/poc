# admin-api notify 모듈 스펙

## 1. 구조

```
apps/admin-api/src/module/notify/
├── notify.module.ts
├── notify.controller.ts
├── notify.service.ts
├── sse-gateway.ts
├── channels/
│   ├── email.channel.ts
│   ├── webhook.channel.ts
│   └── sse.channel.ts
├── formatters/
│   ├── kakaowork.formatter.ts
│   ├── slack.formatter.ts
│   └── teams.formatter.ts
└── templates/
    ├── audit-anomaly-red.hbs
    ├── audit-anomaly-orange.hbs
    └── base.hbs
```

## 2. REST API

| Method | 경로 | 인증 | 용도 |
|:------:|------|:---:|------|
| POST | `/notify/send` | API Key | audit-anomaly 호출 |
| GET | `/notify/stream` | JWT (SSE) | 실시간 알림 구독 |
| GET | `/notify/history` | JWT | 알림 이력 조회 |
| GET | `/notify/unread-count` | JWT | 미읽음 개수 |
| PATCH | `/notify/:id/read` | JWT | 단건 읽음 처리 |
| POST | `/notify/read-all` | JWT | 전체 읽음 |
| GET | `/notify/rules` | JWT | 알림 규칙 조회 |
| PUT | `/notify/rules/:dept_cd` | Admin JWT | 부서별 임계값 수정 |

## 3. POST /notify/send 요청

```typescript
interface SendNotificationDto {
  tenantId: string;
  category: 'audit_anomaly' | 'manual' | 'system';
  severity: 'RED' | 'ORANGE' | 'YELLOW' | 'GREEN';
  title: string;
  body: string;
  payload?: {
    ruleCode?: string;
    deptCode?: string;
    empCd?: string;
    riskScore?: number;
    anomalyId?: string;
  };
  targets: {
    sse?: boolean;
    email?: string[];
    webhook?: string[];   // 'kakaowork' | 'slack' | 'teams'
  };
}
```

## 4. 심각도별 발송 정책

| 등급 | SSE | 이메일 | Webhook | 팝업 | 디바운싱 |
|------|:---:|:---:|:------:|:---:|:------:|
| RED | ✅ | ✅ | ✅ | ✅ | 즉시 |
| ORANGE | ✅ | ✅ | — | — | 1시간 묶음 |
| YELLOW | ✅ | — | — | — | 6시간 묶음 |
| GREEN | 이력만 | — | — | — | — |

## 5. 디바운싱 로직

```typescript
async function shouldDebounce(event: NotifyEvent): Promise<boolean> {
  const key = `notify:debounce:${event.tenantId}:${event.payload?.ruleCode}:${event.payload?.empCd}`;
  const existed = await this.redis.get(key);
  if (existed && event.severity !== 'RED') {
    return true; // 중복 발송 억제
  }
  const ttl = event.severity === 'ORANGE' ? 3600 : 21600;
  await this.redis.setex(key, ttl, '1');
  return false;
}
```
