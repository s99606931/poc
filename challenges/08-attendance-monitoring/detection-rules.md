# 복무 이상 탐지 규칙 (3종)

## Rule E — travel_card_mismatch (출장-법인카드 불일치)

**정의**: 출장 기간 중 출장지 외 지역에서 법인카드 사용

**탐지 기준** (D8-02 고객 결정):
- A. 시/구 단위 엄격 매칭
- B. 광역시/도 단위 매칭 ⭐ 권장
- C. 반경 50km 이내

**SQL**:
```sql
SELECT
    t.TRAVEL_ID,
    t.EMP_CD,
    emp.EMP_NM,
    t.DESTINATION,
    t.START_DATE,
    t.END_DATE,
    c.CARD_USAGE_ID,
    c.USAGE_LOCATION,
    c.USAGE_DATETIME,
    c.AMOUNT,
    c.MCC_CODE
FROM HCM_TRAVEL t
INNER JOIN SYS_EMPLOYEE emp ON t.EMP_CD = emp.EMP_CD
INNER JOIN CORP_CARD_USAGE c
    ON t.EMP_CD = c.EMP_CD
    AND DATE(c.USAGE_DATETIME) BETWEEN DATE(t.START_DATE) AND DATE(t.END_DATE)
WHERE t.START_DATE >= DATE_SUB(NOW(), INTERVAL 30 DAY)
  AND NOT (
      -- 광역시/도 단위 매칭 (D8-02 B 권장)
      SUBSTRING(t.DESTINATION, 1, 2) = SUBSTRING(c.USAGE_LOCATION, 1, 2)
      OR c.USAGE_LOCATION LIKE CONCAT(t.DESTINATION, '%')
      OR t.DESTINATION LIKE CONCAT(c.USAGE_LOCATION, '%')
  )
ORDER BY t.START_DATE DESC;
```

**감점**: HIGH 10점

---

## Rule F — overtime_pattern (초과근무 이상 패턴)

**정의**: 주 15시간 이상 초과근무 연속 or 특정 직원 집중

**SQL**:
```sql
-- 주간 집계
SELECT
    EMP_CD,
    YEAR(WORK_DATE) AS year,
    WEEK(WORK_DATE) AS week,
    SUM(OVERTIME_HOURS) AS weekly_overtime,
    COUNT(DISTINCT WORK_DATE) AS overtime_days
FROM HCM_OVERTIME
WHERE WORK_DATE >= DATE_SUB(NOW(), INTERVAL 60 DAY)
  AND APPROVED_YN = 'Y'
GROUP BY EMP_CD, YEAR(WORK_DATE), WEEK(WORK_DATE)
HAVING weekly_overtime >= 15;

-- 연속 주 탐지
SELECT
    EMP_CD,
    MIN(week) AS from_week,
    MAX(week) AS to_week,
    COUNT(*) AS consecutive_weeks,
    SUM(weekly_overtime) AS total_overtime
FROM (
    -- 위 쿼리 결과
) weekly
GROUP BY EMP_CD
HAVING consecutive_weeks >= 3 AND total_overtime >= 60;
```

**감점**: MEDIUM 5점 (주 15h × 3주 이상)

---

## Rule G — attendance_anomaly (근태 이상)

**유형**:
1. 자정 이후 출근 (정기 야간 근무자 제외)
2. 휴가 미신청 + 미출근 (무단 결근)
3. 주말 연속 출근

**SQL (유형 1 — 자정 이후 출근)**:
```sql
SELECT
    a.EMP_CD,
    emp.EMP_NM,
    emp.DEPT_CD,
    a.CHECKIN_TIME,
    a.WORK_DATE,
    emp.POSITION_CD
FROM HCM_ATTENDANCE a
INNER JOIN SYS_EMPLOYEE emp ON a.EMP_CD = emp.EMP_CD
LEFT JOIN HCM_NIGHT_WORKER_WHITELIST nw ON a.EMP_CD = nw.EMP_CD
WHERE a.WORK_DATE >= DATE_SUB(NOW(), INTERVAL 30 DAY)
  AND TIME(a.CHECKIN_TIME) BETWEEN '00:00:00' AND '05:59:59'
  AND nw.EMP_CD IS NULL   -- 야간 근무자 화이트리스트 제외
ORDER BY a.CHECKIN_TIME;
```

**SQL (유형 2 — 무단 결근)**:
```sql
SELECT
    emp.EMP_CD,
    emp.EMP_NM,
    emp.DEPT_CD,
    ws.WORK_DATE
FROM (
    -- 기대 근무일 (주중, 공휴일 제외)
    SELECT EMP_CD, WORK_DATE
    FROM HCM_EMPLOYEE_WORK_SCHEDULE
    WHERE WORK_DATE BETWEEN DATE_SUB(NOW(), INTERVAL 30 DAY) AND NOW()
) ws
INNER JOIN SYS_EMPLOYEE emp ON ws.EMP_CD = emp.EMP_CD
LEFT JOIN HCM_ATTENDANCE a
    ON ws.EMP_CD = a.EMP_CD AND DATE(ws.WORK_DATE) = DATE(a.WORK_DATE)
LEFT JOIN HCM_LEAVE l
    ON ws.EMP_CD = l.EMP_CD
    AND DATE(ws.WORK_DATE) BETWEEN l.START_DATE AND l.END_DATE
    AND l.APPROVED_YN = 'Y'
WHERE a.CHECKIN_TIME IS NULL     -- 출근 안 함
  AND l.LEAVE_ID IS NULL          -- 휴가 신청 없음
  AND ws.WORK_DATE NOT IN (SELECT HOLIDAY_DATE FROM SYS_HOLIDAY)
ORDER BY ws.WORK_DATE DESC;
```

**감점**: LOW 2점 (일반) / MEDIUM 5점 (3건 이상 누적)

---

## 통합 리스크 스코어

```python
COMPLIANCE_RULE_WEIGHTS = {
    "travel_card_mismatch":   10,  # HIGH
    "overtime_pattern":        5,  # MEDIUM
    "attendance_anomaly":      2,  # LOW
}

# 과제 7 회계 + 과제 8 복무 통합
TOTAL_RULE_WEIGHTS = {
    **ACCOUNTING_RULE_WEIGHTS,  # 과제 7
    **COMPLIANCE_RULE_WEIGHTS,
}
```
