# admin-web 대시보드 페이지 상세

## 1. /admin/dashboard (기존 확장)

### 추가 카드

```tsx
<div className="grid grid-cols-4 gap-4">
  <KpiCard
    title="금월 감사 이상 탐지"
    value={stats.totalAnomalies}
    delta={`${stats.trendPercent}%`}
    color="brand-500"
  />
  <KpiCard
    title="RED 등급"
    value={stats.redCount}
    color="error-500"
    onClick={() => router.push('/admin/activities/audits?severity=RED')}
  />
  <KpiCard
    title="ORANGE 등급"
    value={stats.orangeCount}
    color="warning-500"
  />
  <KpiCard
    title="미결재 건 (전사)"
    value={stats.pendingCount}
    color="gray-500"
  />
</div>

<RecentAnomaliesTable items={stats.recentAnomalies} />
<MonthlyTrendChart data={stats.monthlyTrend} />
```

**API**: `GET /admin-api/audit/stats`

---

## 2. /admin/activities/audits (기존 확장)

### DataTable 컬럼

| 컬럼 | 설명 |
|------|------|
| 탐지일 | 2026-04-21 07:02 |
| 등급 | Badge (RED/ORANGE/YELLOW) |
| 규칙 | AUD-ACC-B-SPLIT-PAYMENT |
| 부서 | 조달과 |
| 대상 직원 | 박*수 (마스킹) |
| 금액 | 1,230,000원 |
| 상태 | DETECTED / REVIEWING / CONFIRMED / FALSE_POSITIVE |
| 액션 | [상세] [검토] [처리] |

### 필터

```tsx
<FilterBar>
  <DateRangePicker from={filters.from} to={filters.to} />
  <Select options={["전체", "RED", "ORANGE", "YELLOW"]} />
  <Select options={["전체", "AUD-ACC-*", "AUD-HCM-*"]} />
  <DeptSelect />
  <StatusSelect />
</FilterBar>
```

### 상세 모달

- 탐지 상세 (근거 데이터 JSON)
- AI 설명 (ai-assistant 생성 자연어)
- 관련 규정 조항 (Milvus 검색)
- 처리 이력 타임라인
- [화이트리스트 등록] [FALSE POSITIVE 표시] 버튼

---

## 3. /admin/audit/risk-score (신규)

### 히트맵 (Recharts)

```tsx
<Heatmap
  xAxis={["2026-W10", "W11", ..., "W16"]}    // 최근 6주
  yAxis={["재무과", "회계부", "조달과", "인사부", ...]}  // 부서
  values={riskMatrix}                           // dept × week → score
  colorScale={{
    green: "#12b76a",
    yellow: "#f79009",
    orange: "#f04438",
    red: "#be123c",
  }}
  onCellClick={(dept, week) => router.push(`/admin/activities/audits?dept=${dept}&week=${week}`)}
/>
```

### API

```
GET /admin-api/audit/risk-heatmap?from=2026-03-01&to=2026-04-21
→ {
    departments: [...],
    weeks: [...],
    matrix: [[...]]  // [dept_idx][week_idx] = { score, grade }
  }
```

---

## 4. /admin/audit/alerts (신규)

### 이력 탭

```tsx
<Tabs>
  <Tab label="알림 이력">
    <NotifyHistoryTable
      columns={["발송일", "수신자", "채널", "제목", "심각도", "읽음"]}
      data={history}
    />
  </Tab>
  <Tab label="알림 규칙">
    <RuleSettingsForm
      ruleRows={[
        {dept_cd, threshold_red, threshold_orange, recipients: [email, kakao]}
      ]}
      onSave={updateRules}
    />
  </Tab>
</Tabs>
```

### 알림 규칙 설정

- 부서별 임계값 조정 (D9-03)
- 수신자 목록 관리
- 채널 on/off
- 디바운싱 시간 설정
