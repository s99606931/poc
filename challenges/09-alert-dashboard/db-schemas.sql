-- ============================================================
-- 과제 9 알림+대시보드 — DB 스키마
-- alli-audit.audit_logs 확장 + audit_receipts 신규
-- ============================================================

-- ------------------------------------------------------------
-- 1. audit_logs (기존 alli-audit 엔티티)
-- ------------------------------------------------------------
-- category 값에 'audit_anomaly', 'manual', 'system' 추가
-- 기존 엔티티 재사용, 추가 마이그레이션 불필요

-- ------------------------------------------------------------
-- 2. audit_receipts (신규) — 수신자별 읽음 상태
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_receipts (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    audit_log_id        UUID NOT NULL REFERENCES audit_logs(id) ON DELETE CASCADE,
    tenant_id           VARCHAR(100) NOT NULL,
    emp_cd              VARCHAR(50) NOT NULL,
    channel             VARCHAR(20) NOT NULL,     -- sse | email | webhook
    sent_at             TIMESTAMPTZ,
    send_status         VARCHAR(20) DEFAULT 'pending',  -- pending | sent | failed
    error_message       TEXT,
    is_read             BOOLEAN DEFAULT FALSE,
    read_at             TIMESTAMPTZ,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_receipts_emp_unread ON audit_receipts(emp_cd, is_read, created_at DESC);
CREATE INDEX idx_receipts_audit ON audit_receipts(audit_log_id);

-- ------------------------------------------------------------
-- 3. notify_rules — 부서별 알림 규칙
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notify_rules (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           VARCHAR(100) NOT NULL,
    dept_cd             VARCHAR(50),                    -- NULL=전사 기본
    threshold_red       NUMERIC(4,2) DEFAULT 0.15,
    threshold_orange    NUMERIC(4,2) DEFAULT 0.08,
    threshold_yellow    NUMERIC(4,2) DEFAULT 0.03,
    recipients_red      JSONB DEFAULT '[]'::jsonb,
    recipients_orange   JSONB DEFAULT '[]'::jsonb,
    recipients_yellow   JSONB DEFAULT '[]'::jsonb,
    channels_red        JSONB DEFAULT '["email","sse","webhook"]'::jsonb,
    channels_orange     JSONB DEFAULT '["email","sse"]'::jsonb,
    channels_yellow     JSONB DEFAULT '["sse"]'::jsonb,
    debounce_hours      INTEGER DEFAULT 24,
    is_active           BOOLEAN DEFAULT TRUE,
    updated_by          VARCHAR(50),
    updated_at          TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (tenant_id, dept_cd)
);

-- 기본 규칙 (전사)
INSERT INTO notify_rules (tenant_id, dept_cd, recipients_red, recipients_orange) VALUES
('tenant-001', NULL,
 '["audit-team@agency.go.kr"]',
 '["audit-team@agency.go.kr"]');

-- ------------------------------------------------------------
-- 4. 집계 뷰 — 대시보드용
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_audit_dashboard_stats AS
SELECT
    tenant_id,
    DATE_TRUNC('month', created_at) AS month,
    COUNT(*) FILTER (WHERE severity = 'RED')    AS red_count,
    COUNT(*) FILTER (WHERE severity = 'ORANGE') AS orange_count,
    COUNT(*) FILTER (WHERE severity = 'YELLOW') AS yellow_count,
    COUNT(*) FILTER (WHERE severity = 'GREEN')  AS green_count,
    COUNT(*) AS total
FROM audit_logs
WHERE category = 'audit_anomaly'
GROUP BY tenant_id, DATE_TRUNC('month', created_at);

-- ------------------------------------------------------------
-- 5. 부서별 주간 리스크 스코어 (히트맵용)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_audit_risk_heatmap AS
SELECT
    tenant_id,
    payload->>'deptCode' AS dept_cd,
    DATE_TRUNC('week', created_at) AS week,
    COUNT(*) FILTER (WHERE severity = 'RED')    * 10 +
    COUNT(*) FILTER (WHERE severity = 'ORANGE') *  5 +
    COUNT(*) FILTER (WHERE severity = 'YELLOW') *  2 AS risk_score_raw,
    CASE
        WHEN COUNT(*) FILTER (WHERE severity = 'RED')    * 10 +
             COUNT(*) FILTER (WHERE severity = 'ORANGE') *  5 +
             COUNT(*) FILTER (WHERE severity = 'YELLOW') *  2 >= 50 THEN 'RED'
        WHEN COUNT(*) FILTER (WHERE severity = 'RED')    * 10 +
             COUNT(*) FILTER (WHERE severity = 'ORANGE') *  5 +
             COUNT(*) FILTER (WHERE severity = 'YELLOW') *  2 >= 20 THEN 'ORANGE'
        WHEN COUNT(*) FILTER (WHERE severity = 'RED')    * 10 +
             COUNT(*) FILTER (WHERE severity = 'ORANGE') *  5 +
             COUNT(*) FILTER (WHERE severity = 'YELLOW') *  2 >= 5  THEN 'YELLOW'
        ELSE 'GREEN'
    END AS grade
FROM audit_logs
WHERE category = 'audit_anomaly'
GROUP BY tenant_id, payload->>'deptCode', DATE_TRUNC('week', created_at);
