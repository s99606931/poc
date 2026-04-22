-- 과제 2 ERP-그룹웨어 동기화 — DB 스키마

-- ERP 측 뷰
CREATE OR REPLACE VIEW V_ALLI_HCM_EMPLOYEE_FULL AS
SELECT
    h.EMP_CD AS emp_cd,
    h.EMP_NM AS emp_nm,
    hf.DEPT_CD AS dept_cd,
    d.DEPT_NM AS dept_nm,
    hf.POSITION_CD AS position_cd,
    cd1.CODE_NM AS position_nm,
    h.EMAIL AS email,
    h.PHONE AS phone,
    h.JOIN_DATE AS join_date,
    CASE WHEN h.RETIRE_DATE IS NULL THEN 'Y' ELSE 'N' END AS active_yn,
    GREATEST(h.LAST_MODIFIED, hf.LAST_MODIFIED) AS last_modified
FROM HRI_HR_MST h
LEFT JOIN HRI_HFFC_INFO hf ON h.EMP_CD = hf.EMP_CD AND hf.RECENT_DTA_AT = 'Y'
LEFT JOIN SYS_DEPT d ON hf.DEPT_CD = d.DEPT_CD
LEFT JOIN SYS_COMCD_DTS cd1 ON cd1.CODE = hf.POSITION_CD AND cd1.CATEGORY = 'POSITION';

-- 조직도 뷰 (재귀)
CREATE OR REPLACE VIEW V_ALLI_HCM_ORG_CHART AS
SELECT
    d.DEPT_CD AS dept_cd,
    d.DEPT_NM AS dept_nm,
    d.PARENT_DEPT_CD AS parent_cd,
    d.DEPT_LEVEL AS level,
    d.SORT_ORDER AS sort_order,
    d.ACTIVE_YN AS active_yn
FROM SYS_DEPT d
ORDER BY d.DEPT_LEVEL, d.SORT_ORDER;

-- 사원코드 매핑 (ERP ↔ 그룹웨어)
CREATE TABLE IF NOT EXISTS EMP_CD_MAPPING (
    erp_emp_cd          VARCHAR(50)     PRIMARY KEY,
    gw_emp_cd           VARCHAR(50)     NOT NULL UNIQUE,
    tenant_id           VARCHAR(100)    NOT NULL,
    created_at          DATETIME        DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME        DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- 동기화 이력 (alli-audit.audit_logs 재사용 or 별도 테이블)
CREATE TABLE IF NOT EXISTS SYNC_HISTORY (
    sync_id             VARCHAR(50)     PRIMARY KEY,   -- "SYNC-20260421-001"
    sync_type           VARCHAR(30)     NOT NULL,      -- EMPLOYEE | ORG_CHART
    triggered_by        VARCHAR(30),                    -- SCHEDULER | MANUAL
    total_records       INT,
    success_count       INT,
    failed_count        INT,
    duration_ms         INT,
    started_at          DATETIME,
    completed_at        DATETIME,
    error_summary       TEXT,
    tenant_id           VARCHAR(100)    NOT NULL
);

CREATE TABLE IF NOT EXISTS SYNC_RECORD_DETAIL (
    id                  BIGINT AUTO_INCREMENT PRIMARY KEY,
    sync_id             VARCHAR(50)     NOT NULL,
    erp_emp_cd          VARCHAR(50),
    gw_emp_cd           VARCHAR(50),
    action              VARCHAR(20),                    -- INSERT | UPDATE | DELETE
    status              VARCHAR(20),                    -- SUCCESS | FAILED | SKIPPED
    changed_fields_json JSON,
    error_message       TEXT,
    FOREIGN KEY (sync_id) REFERENCES SYNC_HISTORY(sync_id)
);
CREATE INDEX idx_sync_emp ON SYNC_RECORD_DETAIL(erp_emp_cd);
