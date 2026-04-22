-- ============================================================
-- 과제 3 개인비서 — DB 스키마 (ERP/그룹웨어 조회 대상)
-- 작성일: 2026-04-21
-- 대상 DB: MariaDB / Oracle / Tibero / MSSQL (ERP 벤더에 따라 변형)
-- ============================================================

-- ============================================================
-- [Section 1] ERP 측 뷰 (V_ALLI_*)
-- 호출 경로: erp-mcp → sql-runner → ERP DB
-- ============================================================

-- ------------------------------------------------------------
-- 1.1 V_ALLI_HCM_DEADLINE — 인사 마감 업무
-- 원본 테이블: HRI_HR_MST, HRI_EVAL_TARGET, HRI_TRAIN_APPLY 등
-- 조회 대상: 개인별 마감 임박 인사 업무 (정기평가/교육신청/출장정산 등)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW V_ALLI_HCM_DEADLINE AS
SELECT
    CONCAT('HCM-', e.EVAL_TYPE, '-', e.EVAL_PERIOD, '-', LPAD(ROWNUM, 3, '0')) AS task_id,
    'HCM' AS category,
    CASE e.EVAL_TYPE
        WHEN 'EVAL' THEN '정기평가'
        WHEN 'TRAIN' THEN '교육신청'
        WHEN 'TRIP' THEN '출장정산'
    END AS subcategory,
    e.TITLE AS title,
    e.DESCRIPTION AS description,
    e.DEADLINE AS deadline,
    CASE
        WHEN e.PRIORITY = 'H' THEN 'HIGH'
        WHEN e.PRIORITY = 'M' THEN 'MEDIUM'
        ELSE 'LOW'
    END AS importance,
    e.EMP_CD AS emp_cd,
    h.DEPT_CD AS department_cd,
    e.URL AS related_url,
    CASE WHEN e.SUBMIT_YN = 'Y' THEN TRUE ELSE FALSE END AS submitted
FROM HRI_EVAL_TARGET e
INNER JOIN HRI_HR_MST h ON e.EMP_CD = h.EMP_CD
WHERE e.ACTIVE_YN = 'Y'
  AND e.DEADLINE >= SYSDATE;
-- Oracle 기준. MariaDB는 ROWNUM → ROW_NUMBER() OVER (...) 필요

-- ------------------------------------------------------------
-- 1.2 V_ALLI_ACC_CLOSING — 회계 마감 업무
-- 원본 테이블: ACC_CLOSE_TASK, ACC_JOURNAL 등
-- 조회 대상: 월결산/분기결산/연결산 마감
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW V_ALLI_ACC_CLOSING AS
SELECT
    CONCAT('ACC-CLOSE-', c.CLOSE_PERIOD, '-', LPAD(c.SEQ, 3, '0')) AS task_id,
    'ACC' AS category,
    CASE c.CLOSE_TYPE
        WHEN 'M' THEN '월결산'
        WHEN 'Q' THEN '분기결산'
        WHEN 'Y' THEN '연결산'
    END AS subcategory,
    c.TITLE AS title,
    c.DESCRIPTION AS description,
    c.DEADLINE AS deadline,
    'HIGH' AS importance,
    c.RESPONSIBLE_EMP_CD AS responsible_emp_cd,
    c.DEPT_CD AS department_cd,
    CONCAT('http://erp.agency.go.kr/acc/close/', c.CLOSE_PERIOD) AS related_url,
    CASE WHEN c.CLOSED_YN = 'Y' THEN TRUE ELSE FALSE END AS closed_yn
FROM ACC_CLOSE_TASK c
WHERE c.ACTIVE_YN = 'Y'
  AND c.DEADLINE >= SYSDATE;

-- ------------------------------------------------------------
-- 1.3 V_ALLI_BDG_SUBMIT — 예산 제출 마감
-- 원본 테이블: BDG_REQUEST, BDG_SETTLEMENT
-- 조회 대상: 예산요구서/예산정산 제출 마감
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW V_ALLI_BDG_SUBMIT AS
SELECT
    CONCAT('BDG-', b.BDG_TYPE, '-', b.BDG_PERIOD, '-', LPAD(b.SEQ, 3, '0')) AS task_id,
    'BDG' AS category,
    CASE b.BDG_TYPE
        WHEN 'REQ' THEN '예산요구서'
        WHEN 'STL' THEN '예산정산'
    END AS subcategory,
    b.TITLE AS title,
    b.DESCRIPTION AS description,
    b.DEADLINE AS deadline,
    'MEDIUM' AS importance,
    b.SUBMITTER_EMP_CD AS submitter_emp_cd,
    b.DEPT_CD AS department_cd,
    CONCAT('http://erp.agency.go.kr/bdg/', LOWER(b.BDG_TYPE), '/', b.BDG_PERIOD) AS related_url,
    CASE WHEN b.SUBMIT_YN = 'Y' THEN TRUE ELSE FALSE END AS submitted
FROM BDG_REQUEST b
WHERE b.ACTIVE_YN = 'Y'
  AND b.DEADLINE >= SYSDATE;

-- ------------------------------------------------------------
-- 1.4 V_ALLI_ACC_PENDING_EXPENSE — 미결재 지출 결의서
-- 원본 테이블: ACC_EXPENSE, ACC_APPROVAL_LINE
-- 조회 대상: 본인이 제출한 지출 건 중 상급자 결재 대기 중인 것
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW V_ALLI_ACC_PENDING_EXPENSE AS
SELECT
    CONCAT('EXP-', TO_CHAR(e.SUBMITTED_AT, 'YYYYMMDD'), '-', LPAD(e.EXP_SEQ, 3, '0')) AS item_id,
    'EXPENSE' AS category,
    e.TITLE AS title,
    e.AMOUNT AS amount,
    e.SUBMITTED_AT AS submitted_at,
    ROUND((SYSDATE - e.SUBMITTED_AT), 1) AS waiting_days,
    e.REQUESTER_EMP_CD AS emp_cd,
    al.APPROVER_EMP_CD AS current_approver_emp_cd,
    al.STEP AS current_step,
    e.STATUS AS status,
    CONCAT('http://erp.agency.go.kr/acc/expense/', e.EXP_ID) AS erp_url
FROM ACC_EXPENSE e
INNER JOIN ACC_APPROVAL_LINE al ON e.EXP_ID = al.EXP_ID
WHERE al.STATUS = 'PENDING'
  AND al.STEP = (
      SELECT MIN(STEP) FROM ACC_APPROVAL_LINE
      WHERE EXP_ID = e.EXP_ID AND STATUS = 'PENDING'
  )
  AND e.STATUS IN ('PENDING', 'REVIEWING');

-- ------------------------------------------------------------
-- 1.5 V_ALLI_HCM_PENDING_LEAVE — 미결재 휴가 신청
-- 원본 테이블: HCM_LEAVE_REQUEST, HCM_APPROVAL_LINE
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW V_ALLI_HCM_PENDING_LEAVE AS
SELECT
    CONCAT('LV-', TO_CHAR(l.SUBMITTED_AT, 'YYYYMMDD'), '-', LPAD(l.LV_SEQ, 3, '0')) AS item_id,
    'LEAVE' AS category,
    l.TITLE AS title,
    NULL AS amount,
    l.SUBMITTED_AT AS submitted_at,
    ROUND((SYSDATE - l.SUBMITTED_AT), 1) AS waiting_days,
    l.REQUESTER_EMP_CD AS emp_cd,
    al.APPROVER_EMP_CD AS current_approver_emp_cd,
    al.STEP AS current_step,
    l.STATUS AS status,
    CONCAT('http://erp.agency.go.kr/hcm/leave/', l.LV_ID) AS erp_url
FROM HCM_LEAVE_REQUEST l
INNER JOIN HCM_APPROVAL_LINE al ON l.LV_ID = al.LV_ID
WHERE al.STATUS = 'PENDING'
  AND al.STEP = (
      SELECT MIN(STEP) FROM HCM_APPROVAL_LINE
      WHERE LV_ID = l.LV_ID AND STATUS = 'PENDING'
  )
  AND l.STATUS IN ('PENDING', 'REVIEWING');

-- ============================================================
-- [Section 2] 그룹웨어 측 테이블 (GW_*)
-- 호출 경로: groupware-mcp → 그룹웨어 DB (DB Direct 모드)
-- REST API 모드 사용 시 이 섹션 생략 가능
-- ============================================================

-- ------------------------------------------------------------
-- 2.1 GW_SCHEDULE — 일정 마스터
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS GW_SCHEDULE (
    schedule_id         VARCHAR(50)     PRIMARY KEY,    -- "GW-SCH-20260421-042"
    category            VARCHAR(20)     NOT NULL,       -- MEETING | BUSINESS_TRIP | REPORT | PERSONAL | TRAINING
    title               VARCHAR(500)    NOT NULL,
    description         TEXT,
    start_dt            DATETIME        NOT NULL,
    end_dt              DATETIME        NOT NULL,
    is_all_day          CHAR(1)         NOT NULL DEFAULT 'N',
    location            VARCHAR(500),
    online_url          VARCHAR(1000),
    organizer_emp_cd    VARCHAR(50)     NOT NULL,
    importance          VARCHAR(10)     NOT NULL DEFAULT 'MEDIUM',  -- HIGH | MEDIUM | LOW
    status              VARCHAR(20)     NOT NULL DEFAULT 'CONFIRMED',  -- CONFIRMED | TENTATIVE | CANCELLED
    created_at          DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    tenant_id           VARCHAR(100)    NOT NULL
);
CREATE INDEX idx_gw_schedule_organizer ON GW_SCHEDULE(organizer_emp_cd, start_dt);
CREATE INDEX idx_gw_schedule_period ON GW_SCHEDULE(start_dt, end_dt, status);
CREATE INDEX idx_gw_schedule_tenant ON GW_SCHEDULE(tenant_id, start_dt);

-- ------------------------------------------------------------
-- 2.2 GW_SCHEDULE_ATTENDEE — 참석자
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS GW_SCHEDULE_ATTENDEE (
    id                  BIGINT          AUTO_INCREMENT PRIMARY KEY,
    schedule_id         VARCHAR(50)     NOT NULL,
    emp_cd              VARCHAR(50)     NOT NULL,
    rsvp_status         VARCHAR(20)     NOT NULL DEFAULT 'PENDING',  -- ACCEPTED | TENTATIVE | DECLINED | PENDING
    responded_at        DATETIME,
    FOREIGN KEY (schedule_id) REFERENCES GW_SCHEDULE(schedule_id) ON DELETE CASCADE,
    UNIQUE KEY uk_schedule_emp (schedule_id, emp_cd)
);
CREATE INDEX idx_gw_attendee_emp ON GW_SCHEDULE_ATTENDEE(emp_cd, rsvp_status);

-- ------------------------------------------------------------
-- 2.3 GW_APPROVAL — 결재 문서 마스터
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS GW_APPROVAL (
    approval_id         VARCHAR(50)     PRIMARY KEY,    -- "GW-APR-20260418-187"
    doc_type            VARCHAR(100)    NOT NULL,       -- "출장비 청구", "물품 구매" 등
    title               VARCHAR(500)    NOT NULL,
    requester_emp_cd    VARCHAR(50)     NOT NULL,
    submitted_at        DATETIME        NOT NULL,
    amount              DECIMAL(15,2),                   -- NULL 가능 (비지출 건)
    importance          VARCHAR(10)     NOT NULL DEFAULT 'MEDIUM',
    total_steps         INT             NOT NULL,
    current_step        INT             NOT NULL DEFAULT 1,
    final_status        VARCHAR(20)     NOT NULL DEFAULT 'IN_PROGRESS',  -- IN_PROGRESS | APPROVED | REJECTED | WITHDRAWN
    gw_url              VARCHAR(1000),
    tenant_id           VARCHAR(100)    NOT NULL,
    created_at          DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
CREATE INDEX idx_gw_approval_requester ON GW_APPROVAL(requester_emp_cd, final_status, submitted_at);
CREATE INDEX idx_gw_approval_pending ON GW_APPROVAL(final_status, submitted_at);

-- ------------------------------------------------------------
-- 2.4 GW_APPROVAL_LINE — 결재선 (단계별)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS GW_APPROVAL_LINE (
    id                  BIGINT          AUTO_INCREMENT PRIMARY KEY,
    approval_id         VARCHAR(50)     NOT NULL,
    step                INT             NOT NULL,          -- 1, 2, 3...
    approver_emp_cd     VARCHAR(50)     NOT NULL,
    status              VARCHAR(20)     NOT NULL DEFAULT 'PENDING',
                                                            -- PENDING | APPROVED | REJECTED | DELEGATED | SKIPPED
    acted_at            DATETIME,
    comment             TEXT,
    delegated_to        VARCHAR(50),
    FOREIGN KEY (approval_id) REFERENCES GW_APPROVAL(approval_id) ON DELETE CASCADE,
    UNIQUE KEY uk_approval_step (approval_id, step)
);
CREATE INDEX idx_gw_line_approver_pending ON GW_APPROVAL_LINE(approver_emp_cd, status);

-- ------------------------------------------------------------
-- 2.5 GW_EMPLOYEE — 사원 정보 (ERP HRI_HR_MST와 동기화)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS GW_EMPLOYEE (
    emp_cd              VARCHAR(50)     PRIMARY KEY,
    emp_nm              VARCHAR(100)    NOT NULL,
    dept_cd             VARCHAR(50)     NOT NULL,
    dept_nm             VARCHAR(200)    NOT NULL,
    position            VARCHAR(50),     -- 직급 (과장, 부장 등)
    email               VARCHAR(200),
    phone               VARCHAR(50),
    active_yn           CHAR(1)         NOT NULL DEFAULT 'Y',
    synced_from_erp_at  DATETIME,
    tenant_id           VARCHAR(100)    NOT NULL
);
CREATE INDEX idx_gw_employee_dept ON GW_EMPLOYEE(dept_cd, active_yn);

-- ============================================================
-- [Section 3] 샘플 데이터 INSERT (개발/테스트용)
-- ============================================================

-- 사원 정보 샘플
INSERT INTO GW_EMPLOYEE (emp_cd, emp_nm, dept_cd, dept_nm, position, email, active_yn, tenant_id) VALUES
('EMP20240315', '홍길동', 'D010201', '회계부', '주임', 'hong@agency.go.kr', 'Y', 'tenant-001'),
('EMP20200205', '김준수', 'D010201', '회계부', '과장', 'kim@agency.go.kr', 'Y', 'tenant-001'),
('EMP20150301', '박민수', 'D010201', '회계부', '부장', 'park@agency.go.kr', 'Y', 'tenant-001'),
('EMP20100101', '정현훈', 'D010200', '재무과', '국장', 'jung@agency.go.kr', 'Y', 'tenant-001'),
('EMP20220611', '이지영', 'D010201', '회계부', '대리', 'lee@agency.go.kr', 'Y', 'tenant-001');

-- 일정 샘플
INSERT INTO GW_SCHEDULE (
    schedule_id, category, title, description,
    start_dt, end_dt, is_all_day, location, organizer_emp_cd,
    importance, status, tenant_id
) VALUES
('GW-SCH-20260421-042', 'MEETING', '회계부 주간 업무 회의',
 '4월 월결산 진행 상황 공유 및 5월 예산 계획 논의',
 '2026-04-21 10:00:00', '2026-04-21 11:00:00', 'N', '본관 3층 회의실 A',
 'EMP20150301', 'HIGH', 'CONFIRMED', 'tenant-001'),

('GW-SCH-20260421-058', 'REPORT', '월결산 보고서 제출 마감',
 '2026-04 월결산 보고서 작성 후 회계부장 결재 필요',
 '2026-04-21 18:00:00', '2026-04-21 18:00:00', 'N', NULL,
 'SYSTEM', 'HIGH', 'CONFIRMED', 'tenant-001'),

('GW-SCH-20260421-073', 'TRAINING', '행정정보시스템 AI 도입 설명회 (선택)',
 '전 부서 대상 AI 활용 사례 공유',
 '2026-04-21 14:00:00', '2026-04-21 15:30:00', 'N', '대강당',
 'EMP20100101', 'LOW', 'CONFIRMED', 'tenant-001');

-- 참석자 샘플
INSERT INTO GW_SCHEDULE_ATTENDEE (schedule_id, emp_cd, rsvp_status) VALUES
('GW-SCH-20260421-042', 'EMP20240315', 'ACCEPTED'),
('GW-SCH-20260421-042', 'EMP20200205', 'ACCEPTED'),
('GW-SCH-20260421-042', 'EMP20220611', 'TENTATIVE'),
('GW-SCH-20260421-058', 'EMP20240315', 'ACCEPTED');

-- 결재 샘플
INSERT INTO GW_APPROVAL (
    approval_id, doc_type, title, requester_emp_cd,
    submitted_at, amount, importance, total_steps, current_step, final_status,
    gw_url, tenant_id
) VALUES
('GW-APR-20260418-187', '출장비 청구',
 '부산 출장비 청구 (2026-04-15 ~ 04-17)',
 'EMP20240315', '2026-04-18 14:30:00', 285000.00, 'MEDIUM', 3, 2, 'IN_PROGRESS',
 'http://gw.agency.go.kr/approval/GW-APR-20260418-187', 'tenant-001');

INSERT INTO GW_APPROVAL_LINE (approval_id, step, approver_emp_cd, status, acted_at, comment) VALUES
('GW-APR-20260418-187', 1, 'EMP20200205', 'APPROVED', '2026-04-19 09:00:00', '확인'),
('GW-APR-20260418-187', 2, 'EMP20150301', 'PENDING', NULL, NULL),
('GW-APR-20260418-187', 3, 'EMP20100101', 'PENDING', NULL, NULL);

-- ============================================================
-- [Section 4] 인덱스 성능 튜닝 가이드
-- ============================================================
-- 조회 패턴:
--   1. 특정 emp_cd의 향후 7일 일정 → idx_gw_schedule_organizer + idx_gw_attendee_emp
--   2. 결재자별 대기 결재 목록 → idx_gw_line_approver_pending + idx_gw_approval_pending
--   3. ERP 측: 인덱스 추가 가이드는 ERP DBA와 별도 협의
--      - HRI_EVAL_TARGET: (EMP_CD, DEADLINE, ACTIVE_YN)
--      - ACC_EXPENSE: (REQUESTER_EMP_CD, STATUS, SUBMITTED_AT)
--      - HCM_LEAVE_REQUEST: (REQUESTER_EMP_CD, STATUS, SUBMITTED_AT)

-- ============================================================
-- [Section 5] 운영 시 유지보수
-- ============================================================
-- * V_ALLI_* 뷰는 ERP DBA가 관리 (정기 스키마 변경 시 업데이트)
-- * GW_* 테이블은 그룹웨어 벤더 스키마 반영 (벤더 교체 시 재매핑)
-- * ERP-그룹웨어 사원코드 동기화 주기: 과제 2 (ERP-그룹웨어 동기화)에서 관리
-- * 마스킹: emp_nm은 API 응답 시 처리 (DB 원본은 보존)

-- ============================================================
-- 끝
-- ============================================================
