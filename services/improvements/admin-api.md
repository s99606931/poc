# admin-api 서비스 개선 태스크 (POC 대응)

> **서비스**: `projects/10_alli-work/apps/admin-api`
> **현재 포트**: 4000
> **기술**: NestJS 11 + TypeORM + ts-rest
> **POC 역할**: 규정 관리 API (POC 2) + 감사 이상 탐지 API (POC 3) + 알림 발송 (POC 3)
> **작성일**: 2026-04-21

> **📌 POC 확장 범위 요약**
>
> 기존 구조 위에 4개 신규 NestJS 모듈 추가:
> | 모듈 | 관련 과제 | 주요 API | 설계 문서 |
> |------|---------|---------|---------|
> | `audit` | 과제 7/9 (감사/대시보드) | GET /audit/anomalies, /audit/dashboard | [challenges/09](../challenges/09-alert-dashboard.md) |
> | `notify` | 과제 9 (알림) | POST /notify/send, GET /notify/stream (SSE) | [services/new/notify-service.md](../new/notify-service.md) |
> | `regulation` | 과제 6 (규정 관리) | POST /regulations/upload | [challenges/06](../challenges/06-knowledge-base.md) |
> | `compliance` | 과제 5 (문서 적합성) | POST /compliance/check | [services/new/doc-compliance.md](../new/doc-compliance.md) |
>
> **재사용 패키지**: `packages/alli-audit` (NestJS 감사 엔티티/서비스/인터셉터)

---

## 현재 상태

```
✅ 기본 CRUD API 구조 (ts-rest 계약 기반)
✅ TypeORM 엔티티/마이그레이션 패턴
✅ JWT 인증 Guard
✅ DTO 검증
❌ 규정 문서 관리 API 없음
❌ 감사 이상 탐지 결과 API 없음
❌ 리스크 스코어 조회/집계 API 없음
❌ doc-compliance 서비스 프록시 없음
```

---

## 개선 태스크

### TASK-API-01 규정 문서 관리 API

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 |
| **예상 공수** | 3일 |
| **담당** | 백엔드 중급 |

#### ts-rest 계약 정의

```typescript
// packages/api-contracts/src/regulations.contract.ts

const regulationContract = c.router({
  list: {
    method: 'GET',
    path: '/regulations',
    query: z.object({
      category: z.enum(['hr', 'finance', 'general', 'security']).optional(),
      is_active: z.boolean().optional(),
      page: z.number().default(1),
      limit: z.number().default(20),
    }),
    responses: { 200: RegulationListSchema },
  },
  
  upload: {
    method: 'POST',
    path: '/regulations/upload',
    body: c.type<FormData>(),  // 파일 업로드 (공공기관 표준 형식 전체 허용)
    responses: {
      201: z.object({ doc_id: z.string(), status: z.string(), chunk_count: z.number() }),
      400: z.object({ message: z.string() }),
      415: z.object({ message: z.string(), supported_formats: z.array(z.string()) }),
    },
  },
  
  getDetail: {
    method: 'GET',
    path: '/regulations/:docId',
    responses: { 200: RegulationDetailSchema, 404: ErrorSchema },
  },
  
  deactivate: {
    method: 'PATCH',
    path: '/regulations/:docId/deactivate',
    body: z.object({ replaced_by: z.string().optional() }),
    responses: { 200: z.object({ success: z.boolean() }) },
  },
  
  checkCompliance: {
    method: 'POST',
    path: '/regulations/compliance/check',
    body: c.type<FormData>(),  // 점검할 문서 파일
    responses: {
      200: ComplianceResultSchema,
      422: ErrorSchema,
    },
  },
})
```

#### 공공기관 문서 형식 허용 목록 (NestJS FileMimeTypeFilter)

```typescript
// admin-api/src/regulations/filters/file-format.filter.ts

/**
 * @description 공공기관 표준 문서 형식 허용 MIME 타입 목록
 * 한컴오피스 / Microsoft Office / 공통 형식 / 이미지(스캔)
 */
export const PUBLIC_DOCUMENT_MIME_TYPES = [
  // ── 한컴오피스 계열 ─────────────────────────────
  'application/x-hwp',                    // HWP (대부분의 브라우저)
  'application/hwp',                      // HWP (일부 브라우저)
  'application/vnd.hancom.hwp',           // HWP (표준 MIME)
  'application/vnd.hancom.hwpx',          // HWPX
  'application/vnd.hancom.cell',          // 한셀 (.cell)
  'application/vnd.hancom.show',          // 한쇼 (.show)
  // ── Microsoft Office 계열 ───────────────────────
  'application/msword',                   // DOC (구버전 Word)
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document', // DOCX
  'application/vnd.ms-excel',             // XLS (구버전 Excel)
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',      // XLSX
  'application/vnd.ms-powerpoint',        // PPT (구버전 PowerPoint)
  'application/vnd.openxmlformats-officedocument.presentationml.presentation', // PPTX
  // ── 공통 형식 ────────────────────────────────────
  'application/pdf',                      // PDF
  'text/plain',                           // TXT
  'application/rtf',                      // RTF
  // ── 이미지/스캔 문서 ─────────────────────────────
  'image/jpeg',                           // JPG/JPEG
  'image/png',                            // PNG
  'image/tiff',                           // TIF/TIFF (스캔 문서)
] as const;

// 허용 확장자 (MIME 타입 인식 실패 시 확장자 기반 검증 폴백)
export const PUBLIC_DOCUMENT_EXTENSIONS = [
  '.hwp', '.hwpx', '.cell', '.show',
  '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
  '.pdf', '.txt', '.rtf',
  '.jpg', '.jpeg', '.png', '.tif', '.tiff',
] as const;

// 최대 파일 크기: 100MB
export const MAX_FILE_SIZE = 100 * 1024 * 1024;

// NestJS FileInterceptor 적용
@Post('upload')
@UseInterceptors(FileInterceptor('file', {
  limits: { fileSize: MAX_FILE_SIZE },
  fileFilter: (req, file, callback) => {
    const ext = path.extname(file.originalname).toLowerCase();
    const mimeAllowed = PUBLIC_DOCUMENT_MIME_TYPES.includes(file.mimetype as any);
    const extAllowed  = PUBLIC_DOCUMENT_EXTENSIONS.includes(ext as any);

    // HWP는 브라우저마다 MIME 타입이 달라 확장자 기반 폴백 필수
    if (mimeAllowed || extAllowed) {
      callback(null, true);
    } else {
      callback(
        new UnsupportedMediaTypeException(
          `지원하지 않는 파일 형식입니다. 지원 형식: HWP, HWPX, Cell, Show, PDF, ` +
          `Word(doc/docx), Excel(xls/xlsx), PowerPoint(ppt/pptx), TXT, RTF, ` +
          `이미지(jpg/png/tiff)`
        ),
        false
      );
    }
  },
}))
async uploadRegulation(@UploadedFile() file: Express.Multer.File) { ... }
```

#### NestJS 모듈 구현

```typescript
// admin-api/src/regulations/regulations.module.ts
// admin-api/src/regulations/regulations.controller.ts
// admin-api/src/regulations/regulations.service.ts
// admin-api/src/regulations/entities/regulation.entity.ts

@Entity('poc_regulations')
export class RegulationEntity {
  @PrimaryGeneratedColumn('uuid')
  id: string;

  @Column({ name: 'doc_id', unique: true })
  docId: string;

  @Column({ name: 'regulation_name' })
  regulationName: string;

  @Column({ name: 'category' })
  category: string;

  @Column({ name: 'version' })
  version: string;

  @Column({ name: 'effective_date', type: 'date' })
  effectiveDate: Date;

  @Column({ name: 'chunk_count', default: 0 })
  chunkCount: number;

  @Column({ name: 'is_active', default: true })
  isActive: boolean;

  @Column({ name: 'tenant_id' })
  tenantId: string;

  @CreateDateColumn({ name: 'created_at' })
  createdAt: Date;
}
```

---

### TASK-API-02 감사 이상 탐지 결과 API

| 항목 | 내용 |
|------|------|
| **우선순위** | P1 (POC 3) |
| **예상 공수** | 3일 |
| **담당** | 백엔드 중급 |

```typescript
// admin-api/src/audit/audit.contract.ts

const auditContract = c.router({
  // 이상 탐지 목록 조회
  listAnomalies: {
    method: 'GET',
    path: '/audit/anomalies',
    query: z.object({
      risk_level: z.enum(['RED', 'ORANGE', 'YELLOW', 'GREEN']).optional(),
      rule_id: z.string().optional(),
      dept_cd: z.string().optional(),
      start_date: z.string().optional(),
      end_date: z.string().optional(),
      status: z.enum(['OPEN', 'REVIEWED', 'CLOSED']).optional(),
      page: z.number().default(1),
      limit: z.number().default(20),
    }),
    responses: { 200: AnomalyListSchema },
  },
  
  // 이상 탐지 상세 + AI 설명
  getAnomaly: {
    method: 'GET',
    path: '/audit/anomalies/:anomalyId',
    responses: { 200: AnomalyDetailSchema },
  },
  
  // 이상 탐지 처리 상태 업데이트
  updateAnomalyStatus: {
    method: 'PATCH',
    path: '/audit/anomalies/:anomalyId/status',
    body: z.object({
      status: z.enum(['REVIEWED', 'CLOSED']),
      reviewer_comment: z.string().optional(),
    }),
    responses: { 200: z.object({ success: z.boolean() }) },
  },
  
  // 부서별 리스크 스코어
  getRiskScores: {
    method: 'GET',
    path: '/audit/risk-scores',
    query: z.object({
      year: z.number(),
      month: z.number(),
    }),
    responses: { 200: RiskScoreListSchema },
  },
  
  // 감사 대시보드 KPI
  getDashboardKPIs: {
    method: 'GET',
    path: '/audit/dashboard',
    responses: { 200: DashboardKPISchema },
  },
})
```

#### DB 엔티티 (audit-anomaly 결과 저장)

```typescript
@Entity('audit_anomaly_results')
export class AuditAnomalyEntity {
  @PrimaryGeneratedColumn('uuid')
  id: string;

  @Column({ name: 'rule_id' })         // AUD-ACC-01 등
  ruleId: string;

  @Column({ name: 'rule_name' })
  ruleName: string;

  @Column({ name: 'emp_id' })
  empId: string;

  @Column({ name: 'dept_cd' })
  deptCd: string;

  @Column({ name: 'risk_level' })      // RED/ORANGE/YELLOW/GREEN
  riskLevel: string;

  @Column({ name: 'risk_score', type: 'decimal', precision: 5, scale: 4 })
  riskScore: number;

  @Column({ name: 'evidence', type: 'json' })
  evidence: object;                    // 이상 탐지 근거 데이터

  @Column({ name: 'ai_explanation', type: 'text', nullable: true })
  aiExplanation: string;

  @Column({ name: 'status', default: 'OPEN' })
  status: string;

  @Column({ name: 'reviewer_comment', type: 'text', nullable: true })
  reviewerComment: string;

  @CreateDateColumn({ name: 'detected_at' })
  detectedAt: Date;

  @Column({ name: 'tenant_id' })
  tenantId: string;
}
```

---

### TASK-API-03 DB 마이그레이션 생성

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 |
| **예상 공수** | 1일 |

```bash
# 마이그레이션 생성
pnpm --filter admin-api typeorm migration:generate src/migrations/AddPocTables

# 생성될 마이그레이션:
# - poc_regulations 테이블
# - audit_anomaly_results 테이블
# - audit_risk_scores 테이블
```

---

## 완료 체크리스트

```
□ TASK-API-01: 규정 관리 API (ts-rest 계약 + 컨트롤러 + 서비스 + 엔티티)
□ TASK-API-02: 감사 이상 탐지 API (계약 + 엔티티 + 서비스)
□ TASK-API-03: DB 마이그레이션 실행 (poc_regulations, audit_anomaly_results)
□ admin-api → ai-rag 서비스 HTTP 클라이언트 구현 (규정 업로드 프록시)
□ admin-api → doc-compliance 서비스 HTTP 클라이언트 (문서 점검 프록시)
□ pnpm typecheck:all 통과 확인
□ Swagger UI에서 신규 API 문서 확인
□ admin-web E2E 연동 테스트
```
