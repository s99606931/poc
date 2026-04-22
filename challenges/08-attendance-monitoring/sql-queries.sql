-- ============================================================
-- 과제 8 복무 모니터링 — SQL 쿼리
-- 대상: ERP HCM DB + 법인카드 DB
-- ============================================================

-- ------------------------------------------------------------
-- 1. 출장 기록 (30일)
-- ------------------------------------------------------------
SELECT t.TRAVEL_ID, t.EMP_CD, t.DESTINATION, t.START_DATE, t.END_DATE,
       t.PURPOSE, t.BUSINESS_AMOUNT, t.STATUS
FROM HCM_TRAVEL t
WHERE t.START_DATE >= DATE_SUB(NOW(), INTERVAL 30 DAY)
  AND t.STATUS = 'APPROVED';

-- ------------------------------------------------------------
-- 2. 법인카드 사용 내역 (30일)
-- ------------------------------------------------------------
SELECT c.CARD_USAGE_ID, c.EMP_CD, c.CARD_NO, c.USAGE_DATETIME,
       c.AMOUNT, c.MERCHANT_NM, c.USAGE_LOCATION,
       c.MCC_CODE, c.MCC_NM, c.RECEIPT_ATTACHED_YN
FROM CORP_CARD_USAGE c
WHERE c.USAGE_DATETIME >= DATE_SUB(NOW(), INTERVAL 30 DAY);

-- ------------------------------------------------------------
-- 3. 출장 ↔ 법인카드 교차 (출장지 ≠ 카드 사용지)
-- ------------------------------------------------------------
SELECT t.TRAVEL_ID, t.EMP_CD, emp.EMP_NM, emp.DEPT_CD, dept.DEPT_NM,
       t.DESTINATION, t.START_DATE, t.END_DATE,
       c.CARD_USAGE_ID, c.USAGE_LOCATION, c.USAGE_DATETIME,
       c.AMOUNT, c.MERCHANT_NM, c.MCC_NM
FROM HCM_TRAVEL t
INNER JOIN SYS_EMPLOYEE emp ON t.EMP_CD = emp.EMP_CD
INNER JOIN SYS_DEPT dept ON emp.DEPT_CD = dept.DEPT_CD
INNER JOIN CORP_CARD_USAGE c
    ON t.EMP_CD = c.EMP_CD
    AND DATE(c.USAGE_DATETIME) BETWEEN DATE(t.START_DATE) AND DATE(t.END_DATE)
WHERE t.START_DATE >= DATE_SUB(NOW(), INTERVAL 30 DAY)
  AND t.STATUS = 'APPROVED'
  AND NOT (SUBSTRING(t.DESTINATION, 1, 2) = SUBSTRING(c.USAGE_LOCATION, 1, 2))
ORDER BY t.START_DATE DESC;

-- ------------------------------------------------------------
-- 4. 초과근무 주간 집계
-- ------------------------------------------------------------
SELECT
    o.EMP_CD, emp.EMP_NM, emp.DEPT_CD,
    YEAR(o.WORK_DATE) AS year,
    WEEK(o.WORK_DATE, 1) AS week,
    MIN(o.WORK_DATE) AS week_start,
    MAX(o.WORK_DATE) AS week_end,
    SUM(o.OVERTIME_HOURS) AS weekly_overtime,
    COUNT(DISTINCT o.WORK_DATE) AS overtime_days
FROM HCM_OVERTIME o
INNER JOIN SYS_EMPLOYEE emp ON o.EMP_CD = emp.EMP_CD
WHERE o.WORK_DATE >= DATE_SUB(NOW(), INTERVAL 60 DAY)
  AND o.APPROVED_YN = 'Y'
GROUP BY o.EMP_CD, emp.EMP_NM, emp.DEPT_CD, YEAR(o.WORK_DATE), WEEK(o.WORK_DATE, 1)
HAVING weekly_overtime >= 15;

-- ------------------------------------------------------------
-- 5. 부서별 초과근무 집중도
-- ------------------------------------------------------------
SELECT
    dept.DEPT_CD,
    dept.DEPT_NM,
    COUNT(DISTINCT o.EMP_CD) AS over_emp_count,
    COUNT(DISTINCT emp.EMP_CD) AS total_emp_count,
    (COUNT(DISTINCT o.EMP_CD) * 1.0 / COUNT(DISTINCT emp.EMP_CD)) AS concentration_ratio,
    AVG(o.weekly_overtime) AS avg_weekly_overtime
FROM (
    -- 주간 집계 subquery
) o
RIGHT JOIN SYS_EMPLOYEE emp ON o.EMP_CD = emp.EMP_CD
INNER JOIN SYS_DEPT dept ON emp.DEPT_CD = dept.DEPT_CD
GROUP BY dept.DEPT_CD, dept.DEPT_NM
HAVING concentration_ratio >= 0.30;   -- 부서 내 30% 이상

-- ------------------------------------------------------------
-- 6. 자정 이후 출근
-- ------------------------------------------------------------
SELECT a.EMP_CD, emp.EMP_NM, emp.DEPT_CD, emp.POSITION_CD,
       a.CHECKIN_TIME, a.WORK_DATE,
       DAYNAME(a.WORK_DATE) AS weekday
FROM HCM_ATTENDANCE a
INNER JOIN SYS_EMPLOYEE emp ON a.EMP_CD = emp.EMP_CD
LEFT JOIN HCM_NIGHT_WORKER_WHITELIST nw ON a.EMP_CD = nw.EMP_CD
WHERE a.WORK_DATE >= DATE_SUB(NOW(), INTERVAL 30 DAY)
  AND TIME(a.CHECKIN_TIME) BETWEEN '00:00:00' AND '05:59:59'
  AND nw.EMP_CD IS NULL
ORDER BY a.CHECKIN_TIME DESC;
