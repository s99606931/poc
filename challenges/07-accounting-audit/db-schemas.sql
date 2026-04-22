-- ============================================================
-- 과제 7 회계 이상 탐지 — 저장 스키마
-- 기존 alli-audit (audit_logs) 재사용 + audit_anomaly_detail 확장
-- ============================================================

-- ------------------------------------------------------------
-- 1. alli-audit.audit_logs 에 category='audit_anomaly' 저장
-- ------------------------------------------------------------
-- 메타는 audit_logs.payload (JSONB)에 저장:
--   {
--     "anomaly_id": "ANO-20260420-001",
--     "rule_code": "AUD-ACC-B-SPLIT-PAYMENT",
--     "emp_cd": "EMP20190215",
--     "dept_cd": "D020105",
--     "risk_score": 25,
--     ...
--   }

-- ------------------------------------------------------------
-- 2. audit_anomaly_detail — 탐지 상세 (신규 테이블)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_anomaly_detail (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    audit_log_id        UUID NOT NULL REFERENCES audit_logs(id) ON DELETE CASCADE,
    anomaly_id          VARCHAR(100) UNIQUE NOT NULL,   -- "ANO-20260420-001"
    rule_code           VARCHAR(100) NOT NULL,          -- AUD-ACC-A-DUPLICATE 등
    rule_category       VARCHAR(20) NOT NULL,           -- A | B | C | D

    -- 대상 정보
    emp_cd              VARCHAR(50) NOT NULL,
    dept_cd             VARCHAR(50),
    exp_ids             JSONB,                          -- 관련 EXP ID 배열

    -- 탐지 상세
    amount              BIGINT,
    occurrence_count    INT,
    detection_reason    TEXT,

    -- ML 점수 (선택)
    z_score             NUMERIC(6,3),
    anomaly_score       NUMERIC(6,4),
    confidence          NUMERIC(4,2),

    -- 심각도/점수
    severity            VARCHAR(10) NOT NULL,            -- HIGH | MEDIUM | LOW
    risk_score          INT NOT NULL,                    -- 2 | 5 | 10

    -- 처리 상태
    status              VARCHAR(20) NOT NULL DEFAULT 'DETECTED',
                                                          -- DETECTED | REVIEWING | CONFIRMED | FALSE_POSITIVE | CLOSED
    reviewed_by         VARCHAR(50),
    reviewed_at         TIMESTAMPTZ,
    resolution          TEXT,

    -- 화이트리스트
    whitelisted         BOOLEAN DEFAULT FALSE,
    whitelist_reason    TEXT,

    -- 메타
    detected_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    tenant_id           VARCHAR(100) NOT NULL
);

CREATE INDEX idx_anomaly_detail_emp ON audit_anomaly_detail(emp_cd, detected_at DESC);
CREATE INDEX idx_anomaly_detail_dept ON audit_anomaly_detail(dept_cd, severity);
CREATE INDEX idx_anomaly_detail_status ON audit_anomaly_detail(status, severity);
CREATE INDEX idx_anomaly_detail_rule ON audit_anomaly_detail(rule_code, detected_at DESC);

-- ------------------------------------------------------------
-- 3. audit_anomaly_whitelist — 화이트리스트
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_anomaly_whitelist (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    emp_cd              VARCHAR(50),                     -- NULL=전체 적용
    dept_cd             VARCHAR(50),
    claim_type          VARCHAR(100),
    rule_code           VARCHAR(100),
    reason              TEXT NOT NULL,

    effective_from      DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_to        DATE,                            -- 1년 자동 해제

    created_by          VARCHAR(50) NOT NULL,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    tenant_id           VARCHAR(100) NOT NULL
);

CREATE INDEX idx_whitelist_emp ON audit_anomaly_whitelist(emp_cd, effective_from, effective_to);

-- ------------------------------------------------------------
-- 4. audit_anomaly_rule_config — 탐지 규칙 설정
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_anomaly_rule_config (
    rule_code           VARCHAR(100) PRIMARY KEY,
    rule_name           VARCHAR(200) NOT NULL,
    rule_category       VARCHAR(20) NOT NULL,            -- A | B | C | D
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    threshold_config    JSONB NOT NULL,                  -- {"period_days":30, "min_amount":500000}
    severity            VARCHAR(10) NOT NULL,
    updated_by          VARCHAR(50),
    updated_at          TIMESTAMPTZ DEFAULT NOW(),
    tenant_id           VARCHAR(100) NOT NULL
);

-- 기본 규칙 데이터
INSERT INTO audit_anomaly_rule_config (rule_code, rule_name, rule_category, threshold_config, severity, tenant_id) VALUES
('AUD-ACC-A-DUPLICATE',       '중복 청구 탐지',      'A', '{"period_days":30}',                              'HIGH',   'tenant-001'),
('AUD-ACC-B-SPLIT-PAYMENT',   '분할 결제 탐지',      'B', '{"period_days":7,"min_count":3,"min_total":500000}', 'HIGH',   'tenant-001'),
('AUD-ACC-C-ZSCORE',          'Z-Score 이상치',      'C', '{"threshold":2.5,"lookback_days":180}',             'MEDIUM', 'tenant-001'),
('AUD-ACC-D-ISOLATION-FOREST', 'Isolation Forest ML', 'D', '{"contamination":0.05,"retrain_days":30}',           'MEDIUM', 'tenant-001');

-- ------------------------------------------------------------
-- 5. 감사 결과 조회 뷰
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_audit_anomaly_summary AS
SELECT
    d.dept_cd,
    d.dept_nm,
    DATE_TRUNC('month', a.detected_at) AS month,
    COUNT(*) FILTER (WHERE a.severity = 'HIGH')   AS high_count,
    COUNT(*) FILTER (WHERE a.severity = 'MEDIUM') AS medium_count,
    COUNT(*) FILTER (WHERE a.severity = 'LOW')    AS low_count,
    SUM(a.risk_score) AS total_risk_score,
    COUNT(*) FILTER (WHERE a.status = 'FALSE_POSITIVE') AS false_positive_count
FROM audit_anomaly_detail a
LEFT JOIN sys_dept d ON a.dept_cd = d.dept_cd
GROUP BY d.dept_cd, d.dept_nm, DATE_TRUNC('month', a.detected_at);
