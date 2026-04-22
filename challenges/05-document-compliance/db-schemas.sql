-- 과제 5 문서 적합성 — 저장 스키마
-- 기존 alli-audit 엔티티 재사용 + 확장

-- ============================================================
-- audit_logs 테이블에 compliance_check 카테고리로 저장
-- packages/alli-audit/src/audit.entity.ts에 category='compliance_check' 추가
-- ============================================================

-- 추가 테이블: 점검 상세 항목
CREATE TABLE IF NOT EXISTS compliance_violations (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    audit_log_id        UUID NOT NULL REFERENCES audit_logs(id) ON DELETE CASCADE,
    regulation_name     VARCHAR(500) NOT NULL,
    article_no          VARCHAR(200),
    violation_detail    TEXT NOT NULL,
    violation_type      VARCHAR(100),          -- 필수항목_누락 | 금액_불일치 등
    severity            VARCHAR(20) NOT NULL,  -- HIGH | MEDIUM | LOW
    confidence          NUMERIC(4,2),           -- 0.00~1.00
    location            VARCHAR(500),           -- "2페이지 상단"
    suggestion          TEXT,
    penalty             INTEGER,                -- 감점
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_compliance_violations_audit ON compliance_violations(audit_log_id);

-- 샘플 저장
-- audit_logs에는 메타 (점수/등급/파일명 등) 저장
-- INSERT INTO audit_logs (
--   tenant_id, category, severity, title, body,
--   payload, targets, created_at
-- ) VALUES (
--   'tenant-001', 'compliance_check', 'MEDIUM',
--   '품의서 점검 결과 (80점, B)',
--   '위반 1건 탐지 (금액_불일치)',
--   '{"checkId":"chk-20260421-142301-abc","docType":"품의서","score":80,"grade":"B","fileInfo":{...}}',
--   '{}',
--   '2026-04-21T14:23:08+09:00'
-- );
