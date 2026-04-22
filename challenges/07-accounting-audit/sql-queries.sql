-- ============================================================
-- 과제 7 회계 이상 탐지 — SQL 쿼리 모음
-- 대상 DB: ERP 회계 DB (MariaDB/Oracle/Tibero 공통 SQL)
-- ============================================================

-- ------------------------------------------------------------
-- 1. 전일 지출 데이터 로드 (배치 시작)
-- ------------------------------------------------------------
SELECT
    e.EXP_ID,
    e.EMP_CD,
    emp.EMP_NM,
    emp.DEPT_CD,
    dept.DEPT_NM,
    e.CLAIM_TYPE,
    e.AMOUNT,
    e.SUBMITTED_AT,
    e.STATUS,
    e.BDG_ACCOUNT_CD,
    e.APPROVER_COUNT,
    HOUR(e.SUBMITTED_AT) AS submitted_hour,
    DAYOFWEEK(e.SUBMITTED_AT) AS day_of_week,
    DATEDIFF(e.SUBMITTED_AT,
        (SELECT MAX(SUBMITTED_AT) FROM ACC_EXPENSE WHERE EMP_CD = e.EMP_CD AND EXP_ID < e.EXP_ID)
    ) AS days_since_last_claim
FROM ACC_EXPENSE e
INNER JOIN SYS_EMPLOYEE emp ON e.EMP_CD = emp.EMP_CD
INNER JOIN SYS_DEPT dept ON emp.DEPT_CD = dept.DEPT_CD
WHERE DATE(e.SUBMITTED_AT) = DATE_SUB(CURDATE(), INTERVAL 1 DAY)
  AND e.STATUS IN ('APPROVED', 'PAID');

-- ------------------------------------------------------------
-- 2. Rule A — 중복 청구 탐지
-- ------------------------------------------------------------
SELECT
    e1.EXP_ID AS primary_exp_id,
    e2.EXP_ID AS duplicate_exp_id,
    e1.EMP_CD,
    emp.EMP_NM,
    emp.DEPT_CD,
    e1.CLAIM_TYPE,
    e1.AMOUNT,
    e1.SUBMITTED_AT AS primary_date,
    e2.SUBMITTED_AT AS duplicate_date,
    ABS(DATEDIFF(e1.SUBMITTED_AT, e2.SUBMITTED_AT)) AS days_diff
FROM ACC_EXPENSE e1
INNER JOIN ACC_EXPENSE e2
    ON e1.EMP_CD = e2.EMP_CD
    AND e1.CLAIM_TYPE = e2.CLAIM_TYPE
    AND e1.AMOUNT = e2.AMOUNT
    AND e1.EXP_ID < e2.EXP_ID
    AND ABS(DATEDIFF(e1.SUBMITTED_AT, e2.SUBMITTED_AT)) <= 30
INNER JOIN SYS_EMPLOYEE emp ON e1.EMP_CD = emp.EMP_CD
WHERE e1.SUBMITTED_AT >= DATE_SUB(NOW(), INTERVAL 30 DAY)
  AND e1.STATUS IN ('APPROVED', 'PAID')
  AND e2.STATUS IN ('APPROVED', 'PAID')
ORDER BY e1.SUBMITTED_AT DESC;

-- ------------------------------------------------------------
-- 3. Rule B — 쪼개기 결제 탐지
-- ------------------------------------------------------------
SELECT
    e.EMP_CD,
    emp.EMP_NM,
    emp.DEPT_CD,
    COUNT(*) AS split_count,
    SUM(e.AMOUNT) AS total_amount,
    MIN(e.SUBMITTED_AT) AS first_date,
    MAX(e.SUBMITTED_AT) AS last_date,
    GROUP_CONCAT(e.EXP_ID ORDER BY e.SUBMITTED_AT) AS exp_ids,
    GROUP_CONCAT(e.AMOUNT ORDER BY e.SUBMITTED_AT) AS amounts
FROM ACC_EXPENSE e
INNER JOIN SYS_EMPLOYEE emp ON e.EMP_CD = emp.EMP_CD
WHERE e.SUBMITTED_AT >= DATE_SUB(NOW(), INTERVAL 7 DAY)
  AND e.CLAIM_TYPE = '물품구매'
  AND e.STATUS IN ('APPROVED', 'PAID')
GROUP BY e.EMP_CD, emp.EMP_NM, emp.DEPT_CD
HAVING COUNT(*) >= 3 AND SUM(e.AMOUNT) >= 500000
ORDER BY total_amount DESC;

-- ------------------------------------------------------------
-- 4. Rule C 보조 — 유형별 금액 통계 (Z-Score 계산용)
-- ------------------------------------------------------------
SELECT
    CLAIM_TYPE,
    AVG(AMOUNT) AS mean_amount,
    STDDEV(AMOUNT) AS stddev_amount,
    COUNT(*) AS sample_count,
    MIN(AMOUNT) AS min_amount,
    MAX(AMOUNT) AS max_amount
FROM ACC_EXPENSE
WHERE SUBMITTED_AT >= DATE_SUB(NOW(), INTERVAL 180 DAY)  -- 최근 6개월 기준선
  AND STATUS IN ('APPROVED', 'PAID')
GROUP BY CLAIM_TYPE;

-- ------------------------------------------------------------
-- 5. Isolation Forest 학습용 데이터 (6개월)
-- ------------------------------------------------------------
SELECT
    e.EXP_ID,
    e.EMP_CD,
    e.CLAIM_TYPE,
    e.AMOUNT,
    HOUR(e.SUBMITTED_AT) AS hour_of_day,
    DAYOFWEEK(e.SUBMITTED_AT) AS day_of_week,
    (
        SELECT COUNT(*) FROM ACC_EXPENSE
        WHERE EMP_CD = e.EMP_CD AND DATE(SUBMITTED_AT) = DATE(e.SUBMITTED_AT)
    ) AS same_day_claims_count,
    e.APPROVER_COUNT,
    COALESCE(
        (e.AMOUNT - stats.mean_amount) / NULLIF(stats.stddev_amount, 0),
        0
    ) AS amount_z_score_by_type
FROM ACC_EXPENSE e
INNER JOIN (
    SELECT CLAIM_TYPE, AVG(AMOUNT) AS mean_amount, STDDEV(AMOUNT) AS stddev_amount
    FROM ACC_EXPENSE
    WHERE SUBMITTED_AT >= DATE_SUB(NOW(), INTERVAL 180 DAY)
      AND STATUS IN ('APPROVED', 'PAID')
    GROUP BY CLAIM_TYPE
) stats ON e.CLAIM_TYPE = stats.CLAIM_TYPE
WHERE e.SUBMITTED_AT >= DATE_SUB(NOW(), INTERVAL 180 DAY)
  AND e.STATUS IN ('APPROVED', 'PAID');

-- ------------------------------------------------------------
-- 6. 부서별 리스크 스코어 집계 (대시보드용)
-- ------------------------------------------------------------
-- PostgreSQL alli-audit 테이블 기준
SELECT
    payload->>'dept_cd' AS dept_cd,
    payload->>'dept_nm' AS dept_nm,
    COUNT(*) FILTER (WHERE severity = 'HIGH') AS high_count,
    COUNT(*) FILTER (WHERE severity = 'MEDIUM') AS medium_count,
    COUNT(*) FILTER (WHERE severity = 'LOW') AS low_count,
    (
        COUNT(*) FILTER (WHERE severity = 'HIGH') * 10 +
        COUNT(*) FILTER (WHERE severity = 'MEDIUM') * 5 +
        COUNT(*) FILTER (WHERE severity = 'LOW') * 2
    ) AS risk_score_raw,
    (
        COUNT(*) FILTER (WHERE severity = 'HIGH') * 10 +
        COUNT(*) FILTER (WHERE severity = 'MEDIUM') * 5 +
        COUNT(*) FILTER (WHERE severity = 'LOW') * 2
    )::float / NULLIF(
        (SELECT COUNT(*) FROM acc_expense_count_by_dept WHERE dept_cd = audit_logs.payload->>'dept_cd'),
        0
    ) AS risk_score_ratio
FROM audit_logs
WHERE category = 'audit_anomaly'
  AND created_at >= NOW() - INTERVAL '30 days'
GROUP BY payload->>'dept_cd', payload->>'dept_nm'
ORDER BY risk_score_raw DESC;
