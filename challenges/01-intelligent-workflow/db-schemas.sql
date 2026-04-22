-- ============================================================
-- 과제 1 전자결재 자동 기안 — DB 스키마
-- ============================================================

-- ------------------------------------------------------------
-- ERP 측 뷰
-- ------------------------------------------------------------

-- 1.1 예산 잔액
CREATE OR REPLACE VIEW V_ALLI_BDG_BALANCE AS
SELECT
    b.BDG_ACCOUNT_CD AS budget_account_cd,
    b.BDG_ACCOUNT_NM AS budget_account_nm,
    b.DEPT_CD AS dept_cd,
    b.FISCAL_YEAR AS fiscal_year,
    b.TOTAL_ALLOCATED AS total_allocated,
    NVL(u.USED_AMOUNT, 0) AS used_amount,
    (b.TOTAL_ALLOCATED - NVL(u.USED_AMOUNT, 0)) AS balance,
    CASE WHEN b.TOTAL_ALLOCATED > 0
         THEN (b.TOTAL_ALLOCATED - NVL(u.USED_AMOUNT, 0)) / b.TOTAL_ALLOCATED
         ELSE 0 END AS balance_ratio
FROM BDG_ACCOUNT b
LEFT JOIN (
    SELECT BDG_ACCOUNT_CD, SUM(AMOUNT) AS USED_AMOUNT
    FROM ACC_EXPENSE
    WHERE STATUS IN ('APPROVED', 'PAID')
    GROUP BY BDG_ACCOUNT_CD
) u ON b.BDG_ACCOUNT_CD = u.BDG_ACCOUNT_CD
WHERE b.ACTIVE_YN = 'Y';

-- 1.2 지출 한도 (규정 기반)
CREATE OR REPLACE VIEW V_ALLI_ACC_EXPENSE_LIMIT AS
SELECT
    l.DOC_TYPE AS doc_type,
    l.POSITION_CD AS position_cd,
    l.PER_TRIP_LIMIT AS per_trip_limit,
    l.MONTHLY_LIMIT AS monthly_limit,
    l.ANNUAL_LIMIT AS annual_limit,
    l.RULE_REFERENCE AS rule_reference
FROM ACC_EXPENSE_LIMIT l
WHERE l.EFFECTIVE_FROM <= SYSDATE
  AND (l.EFFECTIVE_TO IS NULL OR l.EFFECTIVE_TO >= SYSDATE);

-- 1.3 지출 이력
CREATE OR REPLACE VIEW V_ALLI_ACC_EXPENSE_HIST AS
SELECT
    e.EXP_ID AS exp_id,
    e.REQUESTER_EMP_CD AS emp_cd,
    e.DOC_TYPE AS doc_type,
    e.SUBMITTED_AT AS submitted_date,
    e.TITLE AS title,
    e.AMOUNT AS amount,
    e.DESTINATION AS destination,
    e.DURATION_DAYS AS duration_days,
    e.STATUS AS status,
    e.BDG_ACCOUNT_CD AS budget_account_cd
FROM ACC_EXPENSE e
WHERE e.SUBMITTED_AT >= ADD_MONTHS(SYSDATE, -12);

-- ------------------------------------------------------------
-- 그룹웨어 측 테이블 (기존 과제 3 DB-schemas.sql 확장)
-- ------------------------------------------------------------

-- 2.1 결재 양식 마스터
CREATE TABLE IF NOT EXISTS GW_DOC_TEMPLATE (
    template_id         VARCHAR(50)     PRIMARY KEY,  -- "TPL-TRIP-V3"
    doc_type            VARCHAR(50)     NOT NULL,
    template_version    VARCHAR(20)     NOT NULL,
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    legal_basis         TEXT,
    template_url        VARCHAR(1000),
    fields_json         JSON            NOT NULL,      -- 필드 정의
    tenant_id           VARCHAR(100)    NOT NULL,
    created_at          DATETIME        DEFAULT CURRENT_TIMESTAMP
);

-- 2.2 결재선 규칙
CREATE TABLE IF NOT EXISTS GW_APPROVAL_RULE (
    rule_id             VARCHAR(50)     PRIMARY KEY,   -- "TRIP_RULE_2026_V3"
    doc_type            VARCHAR(50)     NOT NULL,
    dept_cd             VARCHAR(50),                    -- NULL=전사 적용
    amount_from         BIGINT          NOT NULL DEFAULT 0,
    amount_to           BIGINT,                         -- NULL=한도 없음
    approval_steps_json JSON            NOT NULL,       -- [{step, role, position_cd}, ...]
    rule_description    VARCHAR(1000),
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    tenant_id           VARCHAR(100)    NOT NULL
);

-- 샘플 규칙
INSERT INTO GW_APPROVAL_RULE VALUES
('TRIP_RULE_2026_V3', 'TRIP', NULL, 0, 100000,
 '[{"step":1,"role":"팀장","position_cd":"P03"}]',
 '출장비 10만원 이하: 팀장 단일 결재',
 '2026-01-01', NULL, 'tenant-001'),

('TRIP_RULE_2026_V3_MID', 'TRIP', NULL, 100001, 500000,
 '[{"step":1,"role":"팀장","position_cd":"P03"},{"step":2,"role":"부서장","position_cd":"P02"},{"step":3,"role":"전결","position_cd":"P01"}]',
 '출장비 10~50만원: 3단계 결재',
 '2026-01-01', NULL, 'tenant-001'),

('TRIP_RULE_2026_V3_HIGH', 'TRIP', NULL, 500001, NULL,
 '[{"step":1,"role":"팀장"},{"step":2,"role":"부서장"},{"step":3,"role":"국장"},{"step":4,"role":"원장"}]',
 '출장비 50만원 초과: 4단계 결재',
 '2026-01-01', NULL, 'tenant-001');

-- 2.3 GW_APPROVAL, GW_APPROVAL_LINE은 과제 3의 스키마 재사용
-- ../03-personal-assistant/db-schemas.sql 참조
