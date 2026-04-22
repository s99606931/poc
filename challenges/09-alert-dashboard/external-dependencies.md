# 과제 9 알림+대시보드 — 외부 의존성

## 1. SMTP 서버 (D9-08)

```env
SMTP_HOST=mail.agency.go.kr
SMTP_PORT=587
SMTP_TLS=true
SMTP_USER=noreply@agency.go.kr
SMTP_PASSWORD=<password>
SMTP_FROM=alli-system@agency.go.kr
```

## 2. 메신저 Webhook (D9-07)

| 메신저 | Webhook URL |
|--------|------------|
| 카카오워크 | `https://hook.kakaowork.com/...` |
| 슬랙 | `https://hooks.slack.com/...` |
| MS Teams | `https://outlook.office.com/webhook/...` |
| 잔디 | `https://wh.jandi.com/...` |

## 3. 고객 제공 필요

```
□ SMTP 접속 정보 (TLS 587 포트 개방)
□ 메신저 Webhook URL (벤더 1종 이상)
□ 알림 수신자 목록 (감사팀 이메일)
□ 기관 로고 이미지 (이메일 헤더용)
□ 알림 문구 검토 승인
□ 알림 임계값 부서별 조정 권한 범위
```

## 4. 리스크

| 리스크 | 대응 |
|--------|------|
| SMTP 미제공 | SSE + Webhook만 사용 |
| 메신저 Webhook 미지원 | 이메일 대체 |
| SSE 연결 불안정 | 재연결 + 미수신 알림 요약 발송 |
| 알림 과다 발송 | 24시간 디바운싱 + 요약 발송 |
