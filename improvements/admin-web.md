# admin-web 서비스 개선 태스크 (POC 대응)

> **서비스**: `projects/10_alli-work/apps/admin-web`
> **현재 포트**: 3001
> **기술**: Next.js 15 App Router + TanStack Query + Zustand
> **POC 역할**: 규정 관리 UI (POC 2) + 감사 대시보드 (POC 3)
> **작성일**: 2026-04-21

> **📌 POC 확장 범위 요약**
>
> 기존 30+ 페이지 (`(admin)/dashboard`, `(admin)/activities/audits`, `(admin)/documents` 등) 확장 + **신규 2개 페이지만** 추가:
>
> | 페이지 | 유형 | 관련 과제 |
> |--------|:---:|---------|
> | `(admin)/dashboard/page.tsx` | 기존 확장 (KPI 카드 추가) | 과제 9 |
> | `(admin)/activities/audits/page.tsx` | 기존 확장 (이상 탐지 목록) | 과제 7/8/9 |
> | `(admin)/documents/page.tsx` | 기존 확장 (규정 관리 + 적합성 점검) | 과제 5/6 |
> | `(admin)/audit/risk-score/page.tsx` | **신규** (부서별 리스크 히트맵) | 과제 9 |
> | `(admin)/audit/alerts/page.tsx` | **신규** (알림 이력 + 규칙 설정) | 과제 9 |
> | `(admin)/chat/page.tsx` | 기존 확장 (결재 기안 카드) | 과제 1/3 |

---

## 현재 상태

```
✅ 기본 관리 대시보드 구조
✅ DataTable 컴포넌트 (TanStack Table)
✅ 디자인 시스템 (brand-500, 다크모드 지원)
✅ Intent 관리 페이지 (18개 테이블)
❌ 규정 문서 관리 페이지 없음
❌ 문서 적합성 점검 UI 없음
❌ 감사 리스크 대시보드 없음
❌ 이상 탐지 결과 목록/상세 없음
❌ 실시간 알림 UI 없음
```

---

## 개선 태스크

### TASK-WEB-01 규정 문서 관리 페이지

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (POC 2 필수) |
| **예상 공수** | 3일 |
| **담당** | 프론트엔드 중급 |

#### 페이지 경로 및 구조

```
/admin/regulations              → 규정 목록 (DataTable)
/admin/regulations/upload       → 규정 문서 업로드
/admin/regulations/[id]         → 규정 상세 (조항 목록)
/admin/regulations/compliance   → 문서 적합성 점검
```

#### 규정 목록 페이지 구현

```tsx
// app/(admin)/regulations/page.tsx
export default function RegulationsPage() {
  return (
    <div className="flex h-full flex-col">
      <PageBreadcrumb pageTitle="규정 문서 관리" />
      <div className="flex flex-col flex-nowrap gap-3">
        {/* 필터 + 액션 */}
        <div className="flex flex-row items-end justify-between">
          <div className="flex flex-row flex-wrap-reverse gap-3">
            <Select /* 카테고리 필터: 인사/회계/행정 */ />
            <Input /* 검색 */ aria-label="규정명 검색" />
          </div>
          <div className="flex flex-row gap-0.5">
            <Button variant="ghost" className="size-8" onClick={() => void refetch()}>
              <RefreshCwIcon className={isRefetching ? 'animate-spin' : ''} aria-hidden="true" />
            </Button>
            <Button onClick={() => router.push('/admin/regulations/upload')}>
              규정 추가
            </Button>
          </div>
        </div>
        
        {/* 규정 테이블 */}
        <DataTable table={table} columns={regulationColumns} showRowNumber />
        <DataTablePagination table={table} />
      </div>
    </div>
  )
}

// 컬럼 정의
const regulationColumns: ColumnDef<Regulation>[] = [
  { accessorKey: 'regulation_name', header: '규정명' },
  { accessorKey: 'category', header: '분류',
    cell: ({ row }) => <CategoryBadge category={row.original.category} /> },
  { accessorKey: 'version', header: '버전' },
  { accessorKey: 'effective_date', header: '시행일',
    cell: ({ row }) => formatDate(row.original.effective_date) },
  { accessorKey: 'chunk_count', header: '조항 수' },
  { accessorKey: 'is_active', header: '상태',
    cell: ({ row }) => (
      <Badge color={row.original.is_active ? 'success' : 'error'}>
        {row.original.is_active ? '활성' : '비활성'}
      </Badge>
    )
  },
  { id: 'actions', header: () => <span className="sr-only">작업</span> }
]
```

#### 지원 문서 형식 (공공기관 표준)

> **공공기관 업무에서 사용되는 전체 문서 형식을 지원한다.**
> 형식별 파서 연동은 [ai-rag.md TASK-RAG-04](./ai-rag.md#task-rag-04-공공기관-문서-형식-파서-통합) 참조.

| 분류 | 확장자 | 형식명 | 파서 방식 | 우선순위 |
|------|--------|--------|---------|:-------:|
| **한컴오피스** | `.hwp` | 한글 문서 (5.x) | hwp5lib + LibreOffice 폴백 | P0 |
| | `.hwpx` | 한글 문서 (XML) | zipfile + XML 직접 파싱 | P0 |
| | `.cell` | 한셀 스프레드시트 | LibreOffice 변환 | P1 |
| | `.show` | 한쇼 프레젠테이션 | LibreOffice 변환 | P1 |
| **Microsoft Office** | `.docx` | Word (현행) | python-docx | P0 |
| | `.doc` | Word (구버전) | LibreOffice 변환 | P0 |
| | `.xlsx` | Excel (현행) | openpyxl | P1 |
| | `.xls` | Excel (구버전) | LibreOffice 변환 | P1 |
| | `.pptx` | PowerPoint (현행) | python-pptx | P1 |
| | `.ppt` | PowerPoint (구버전) | LibreOffice 변환 | P1 |
| **공통 형식** | `.pdf` | PDF 문서 | pdfplumber / PyMuPDF | P0 |
| | `.txt` | 일반 텍스트 | 직접 읽기 | P0 |
| | `.rtf` | 서식 텍스트 | LibreOffice 변환 | P2 |
| **이미지/스캔** | `.jpg` `.jpeg` | JPEG 이미지 | PaddleOCR | P1 |
| | `.png` | PNG 이미지 | PaddleOCR | P1 |
| | `.tif` `.tiff` | TIFF 스캔 문서 | PaddleOCR | P1 |

#### 규정 업로드 페이지

```tsx
// app/(admin)/regulations/upload/page.tsx

// ─── 공공기관 표준 문서 허용 형식 ─────────────────────────────────
const PUBLIC_DOC_ACCEPT = {
  // 한컴오피스 계열
  'application/x-hwp':                    ['.hwp'],
  'application/hwp':                      ['.hwp'],
  'application/vnd.hancom.hwp':           ['.hwp'],
  'application/vnd.hancom.hwpx':          ['.hwpx'],
  'application/vnd.hancom.cell':          ['.cell'],
  'application/vnd.hancom.show':          ['.show'],
  // Microsoft Office 계열
  'application/msword':                   ['.doc'],
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': ['.docx'],
  'application/vnd.ms-excel':             ['.xls'],
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': ['.xlsx'],
  'application/vnd.ms-powerpoint':        ['.ppt'],
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': ['.pptx'],
  // 공통 형식
  'application/pdf':                      ['.pdf'],
  'text/plain':                           ['.txt'],
  'application/rtf':                      ['.rtf'],
  // 이미지/스캔
  'image/jpeg':                           ['.jpg', '.jpeg'],
  'image/png':                            ['.png'],
  'image/tiff':                           ['.tif', '.tiff'],
}

// 파일 크기 제한
const MAX_FILE_SIZE_MB = 100  // 100MB (대용량 HWP 대응)

// 업로드 진행 상태 — 형식별 처리 단계 표시
const getUploadSteps = (fileName: string) => {
  const ext = fileName.split('.').pop()?.toLowerCase()
  const steps = [{ id: 'upload', label: '파일 업로드' }]

  if (['hwp', 'hwpx', 'cell', 'show', 'doc', 'xls', 'ppt', 'rtf'].includes(ext ?? '')) {
    steps.push({ id: 'convert', label: '문서 변환 (텍스트 추출)' })
  }
  if (['jpg', 'jpeg', 'png', 'tif', 'tiff'].includes(ext ?? '')) {
    steps.push({ id: 'ocr', label: 'OCR 텍스트 인식' })
  }
  steps.push(
    { id: 'chunk', label: '청킹 처리' },
    { id: 'embed', label: '임베딩 생성' },
    { id: 'done',  label: '완료' }
  )
  return steps
}

// FileDropzone 구성
<FileDropzone
  accept={PUBLIC_DOC_ACCEPT}
  maxSize={MAX_FILE_SIZE_MB * 1024 * 1024}
  onDrop={handleFileUpload}
  aria-label="공공기관 표준 문서를 드래그하거나 클릭하여 선택하세요"
/>

// 지원 형식 안내 텍스트 (접근성: 텍스트로도 명시)
<p className="text-sm text-gray-500 dark:text-gray-400">
  지원 형식: HWP, HWPX, Cell, Show, PDF, Word(doc/docx),
  Excel(xls/xlsx), PowerPoint(ppt/pptx), TXT, RTF, 이미지(jpg/png/tiff)
  <br />
  최대 크기: 100MB
</p>

// 메타데이터 입력 (기존 유지)
// - 규정명, 카테고리, 시행일, 버전
// - 개정 시 이전 버전 선택 옵션
```

---

### TASK-WEB-02 문서 적합성 점검 UI

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (POC 2 핵심) |
| **예상 공수** | 3일 |
| **담당** | 프론트엔드 중급 |

```tsx
// app/(admin)/regulations/compliance/page.tsx

export default function CompliancePage() {
  return (
    <div className="flex h-full flex-col">
      <PageBreadcrumb pageTitle="문서 적합성 점검" />
      
      {/* 파일 업로드 영역 — 공공기관 표준 형식 전체 허용 */}
      <ComponentCard title="점검할 문서 업로드">
        <FileDropzone
          accept={PUBLIC_DOC_ACCEPT}  {/* 공통 상수 재사용 */}
          maxSize={100 * 1024 * 1024}
          onDrop={handleFileUpload}
          aria-label="점검할 문서를 드래그하거나 클릭하여 선택하세요 (HWP, PDF, Word, Excel 등)"
        />
      </ComponentCard>
      
      {/* 점검 결과 */}
      {result && (
        <ComponentCard title="점검 결과">
          {/* 준수율 게이지 */}
          <ComplianceScoreGauge score={result.compliance_score} />
          
          {/* 위반 항목 목록 */}
          <ComplianceViolationList violations={result.violations} />
          
          {/* 수정 가이드 */}
          <ComplianceSuggestions suggestions={result.suggestions} />
        </ComponentCard>
      )}
    </div>
  )
}

// 준수율 시각화 (색상 + 텍스트 병행 — WCAG 1.4.1 준수)
function ComplianceScoreGauge({ score }: { score: number }) {
  const level = score >= 90 ? '우수' : score >= 70 ? '보통' : '미흡'
  const color = score >= 90 ? 'success' : score >= 70 ? 'warning' : 'error'
  return (
    <div className="flex items-center gap-3">
      <div className="text-4xl font-bold">{score}점</div>
      <Badge color={color}>{level}</Badge>  {/* 색상 + 텍스트 */}
    </div>
  )
}
```

---

### TASK-WEB-03 감사 리스크 대시보드

| 항목 | 내용 |
|------|------|
| **우선순위** | P1 (POC 3 핵심) |
| **예상 공수** | 4일 |
| **담당** | 프론트엔드 중급 |

#### 페이지 경로

```
/admin/audit                    → 감사 메인 대시보드
/admin/audit/anomalies          → 이상 탐지 목록
/admin/audit/anomalies/[id]     → 이상 탐지 상세
/admin/audit/risk-score         → 부서별 리스크 스코어
/admin/audit/alerts             → 알림 이력
```

#### 감사 대시보드 구현

```tsx
// app/(admin)/audit/page.tsx

// KPI 카드 (상단)
const auditKPIs = [
  { title: '오늘 탐지 건수', value: anomalyCount, color: 'error' },
  { title: 'RED 등급 건수', value: redCount, color: 'error' },
  { title: '미처리 이상 건', value: pendingCount, color: 'warning' },
  { title: '이번 달 처리율', value: `${resolvedRate}%`, color: 'success' },
]

// 부서별 리스크 히트맵
// 주간 이상 탐지 추이 차트 (라인)
// 위험 등급별 현황 (도넛)
// 최근 이상 탐지 목록 (DataTable, 상위 10건)
```

#### 이상 탐지 목록 페이지

```tsx
// 컬럼: 탐지일시, 부서, 직원번호, 이상유형, 금액/시간, 위험등급, 상태
// 위험등급 Badge:
//   RED    → <Badge color="error">위험</Badge>
//   ORANGE → <Badge color="warning">주의</Badge>  
//   YELLOW → <Badge color="warning">관찰</Badge>
//   GREEN  → <Badge color="success">정상</Badge>
// 필터: 위험등급 / 이상유형 / 부서 / 기간
// 클릭 → 상세 페이지 (AI 설명 + 관련 규정 + 처리 이력)
```

---

### TASK-WEB-04 실시간 알림 UI

| 항목 | 내용 |
|------|------|
| **우선순위** | P1 |
| **예상 공수** | 2일 |

```tsx
// 헤더 알림 벨 아이콘 + 드롭다운
// notify-service SSE 연결로 실시간 알림 수신

function AuditAlertBell() {
  const { alerts, unreadCount } = useAuditAlerts()  // SSE 훅
  
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" className="relative size-8" aria-label={`감사 알림 ${unreadCount}건`}>
          <BellIcon aria-hidden="true" />
          {unreadCount > 0 && (
            <span className="absolute -top-1 -right-1 size-4 rounded-full bg-error-500 text-xs text-white flex items-center justify-center">
              {unreadCount}
            </span>
          )}
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent>
        {alerts.map(alert => <AlertItem key={alert.id} alert={alert} />)}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
```

---

## 완료 체크리스트

```
□ TASK-WEB-01: 규정 목록/업로드/상세 페이지 3종 구현
□ TASK-WEB-02: 문서 적합성 점검 페이지 구현 (파일업로드 + 결과표시)
□ TASK-WEB-03: 감사 대시보드 4종 페이지 구현
□ TASK-WEB-04: 실시간 알림 UI (SSE 연동)
□ 다크모드 전환 테스트 (모든 신규 페이지)
□ WCAG 2.2 AA 접근성 체크리스트 적용
□ 모바일 반응형 레이아웃 확인 (1024px 이하)
□ DataTable 페이지네이션 동작 확인
```
