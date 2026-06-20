-- =====================================================================
-- CER 管理平台 — PostgreSQL Schema (v1)
-- 配套设计文档: docs/data-model.md
-- 设计要点: 分层 / 版本即快照(copy-on-write) / 批准即冻结 / 假设固化 / 输出物化
-- 样本: PRJ-24-000902644 · Charging Inlet-Gen2 GB Actuator · G4
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS cer;
SET search_path TO cer, public;

-- 枚举 ----------------------------------------------------------------
CREATE TYPE version_status   AS ENUM ('DRAFT','IN_REVIEW','APPROVED','REJECTED','SUPERSEDED');
CREATE TYPE gate_code        AS ENUM ('G1','G2','G3','G4','G5');
CREATE TYPE capex_category   AS ENUM ('DIE','MOLD','PACKING_MOLD','ASSY','OTHERS');
CREATE TYPE ownership_type   AS ENUM ('TE_ONETIME','CUSTOMER','TE_AMORTIZED');
CREATE TYPE bom_level        AS ENUM ('FG','BOM','RAW');
CREATE TYPE make_buy         AS ENUM ('MAKE','BUY');
CREATE TYPE sales_scenario   AS ENUM ('EXISTING','PROPOSED');
CREATE TYPE pnl_type         AS ENUM ('TE_PROJECT','CER','INCR_TE','INCR_CER');
CREATE TYPE metric_scope     AS ENUM ('OVERALL','INCREMENTAL');
CREATE TYPE check_status     AS ENUM ('OK','CHECK','NA');
CREATE TYPE approval_decision AS ENUM ('PENDING','APPROVED','REJECTED','RECALLED');
CREATE TYPE conversion_type  AS ENUM ('LABOR','OVERHEAD','DEPRECIATION','FREIGHT_DUTY','SUSTAINING_ENG','OTHER');

-- =====================================================================
-- L0  MASTER / REFERENCE
-- =====================================================================
CREATE TABLE currency (
  code            CHAR(3) PRIMARY KEY,            -- CNY / USD / EUR ...
  name            TEXT NOT NULL
);

CREATE TABLE fx_rate_set (
  id              BIGSERIAL PRIMARY KEY,
  label           TEXT NOT NULL,                  -- '>FY25 Budget'
  effective_date  DATE NOT NULL,
  base_ccy        CHAR(3) NOT NULL REFERENCES currency(code),  -- 报告币 USD
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE fx_rate (
  fx_rate_set_id  BIGINT NOT NULL REFERENCES fx_rate_set(id) ON DELETE CASCADE,
  quote_ccy       CHAR(3) NOT NULL REFERENCES currency(code),
  rate_to_base    NUMERIC(18,8) NOT NULL,         -- 1 quote = rate_to_base * base; CNY→USD 0.13808; USD→CNY 7.24218
  PRIMARY KEY (fx_rate_set_id, quote_ccy)
);

CREATE TABLE assumption_set (
  id                   BIGSERIAL PRIMARY KEY,
  budget_label         TEXT NOT NULL,             -- '>FY25 Budget'
  sga_pct              NUMERIC(9,6) NOT NULL,      -- 0.0227
  eng_expense_pct      NUMERIC(9,6) NOT NULL,      -- 0.0285
  ar_days              INT NOT NULL,               -- 97
  inv_days             INT NOT NULL,               -- 55
  ap_days              INT NOT NULL,               -- 70
  inbound_freight_pct  NUMERIC(9,6) NOT NULL,      -- 0.016
  outbound_ship_pct    NUMERIC(9,6) NOT NULL,      -- 0.010
  eng_hourly_rate      NUMERIC(12,4) NOT NULL,     -- 59.4
  material_purch_pct   NUMERIC(9,6) NOT NULL,      -- 0.8030
  wacc                 NUMERIC(9,6) NOT NULL,      -- 0.105
  tax_rate             NUMERIC(9,6) NOT NULL DEFAULT 0.25
);

CREATE TABLE labor_rate (
  assumption_set_id    BIGINT NOT NULL REFERENCES assumption_set(id) ON DELETE CASCADE,
  fiscal_year          INT NOT NULL,
  rate                 NUMERIC(12,4) NOT NULL,     -- 51.36 ...
  inflation_pct        NUMERIC(9,6) NOT NULL DEFAULT 0.045,
  PRIMARY KEY (assumption_set_id, fiscal_year)
);

CREATE TABLE overhead_rate (
  id              BIGSERIAL PRIMARY KEY,
  assumption_set_id BIGINT REFERENCES assumption_set(id),
  cost_center     TEXT NOT NULL,
  process         TEXT,
  hourly_rate     NUMERIC(12,4) NOT NULL,
  basis           TEXT
);

CREATE TABLE duty_rate (
  id              BIGSERIAL PRIMARY KEY,
  hs_code         TEXT,
  region          TEXT NOT NULL,
  rate            NUMERIC(9,6) NOT NULL
);

CREATE TABLE plant         ( id BIGSERIAL PRIMARY KEY, code TEXT UNIQUE NOT NULL, name TEXT, region TEXT );
CREATE TABLE product_line  ( id BIGSERIAL PRIMARY KEY, name TEXT UNIQUE NOT NULL );
CREATE TABLE customer      ( id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL );
CREATE TABLE oem           ( id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL );

CREATE TABLE part_master (
  id              BIGSERIAL PRIMARY KEY,
  part_no         TEXT UNIQUE NOT NULL,           -- 2483376-1
  description     TEXT,
  part_type       TEXT NOT NULL DEFAULT 'COMPONENT', -- FG / COMPONENT / RAW / TOOL
  uom             TEXT NOT NULL DEFAULT 'pcs'
);

CREATE TABLE material_master (
  id              BIGSERIAL PRIMARY KEY,
  material_no     TEXT UNIQUE,
  category        TEXT NOT NULL,                  -- Resin / Metal / Plating / Purchasing ...
  std_price       NUMERIC(18,6),
  currency        CHAR(3) REFERENCES currency(code)
);

CREATE TABLE gate_definition (
  gate            gate_code PRIMARY KEY,
  name            TEXT NOT NULL,
  capex_threshold NUMERIC(18,2),                  -- 触发该 gate 的投资门槛
  required_checks TEXT[]                          -- 该 gate 必须为 OK 的校验项
);

-- =====================================================================
-- L1  PROJECT
-- =====================================================================
CREATE TABLE project (
  id                  BIGSERIAL PRIMARY KEY,
  project_no          TEXT UNIQUE NOT NULL,       -- PRJ-24-000902644
  name                TEXT NOT NULL,              -- Charging Inlet-Gen 2 GB actuator-P
  project_type        TEXT,                       -- Type 0
  category            TEXT,                       -- NPI
  product_line_id     BIGINT REFERENCES product_line(id),
  plant_id            BIGINT REFERENCES plant(id),
  customer_id         BIGINT REFERENCES customer(id),
  oem_id              BIGINT REFERENCES oem(id),
  application         TEXT,                       -- Charging Inlet
  shipment_region     TEXT,                       -- CN
  life_years          INT,                        -- 5
  sop_date            DATE,                        -- 2026-03-30
  predecessor_no      TEXT,                        -- Sustaining 前序项目
  interco_transfer    BOOLEAN DEFAULT FALSE,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- L2  CER DOCUMENT  ★版本化核心★
-- =====================================================================
CREATE TABLE cer (
  id                  BIGSERIAL PRIMARY KEY,
  cer_no              TEXT UNIQUE NOT NULL,
  project_id          BIGINT NOT NULL REFERENCES project(id),
  title               TEXT,
  current_version_id  BIGINT,                     -- FK 在 cer_version 建后补
  overall_status      version_status NOT NULL DEFAULT 'DRAFT',
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE cer_version (
  id                  BIGSERIAL PRIMARY KEY,
  cer_id              BIGINT NOT NULL REFERENCES cer(id) ON DELETE CASCADE,
  version_no          TEXT NOT NULL,              -- 'v4.2'
  parent_version_id   BIGINT REFERENCES cer_version(id),
  gate                gate_code NOT NULL,
  status              version_status NOT NULL DEFAULT 'DRAFT',
  -- 假设固化 (P4): 同时存 id 与解析值, 保证历史可复现
  fx_rate_set_id      BIGINT REFERENCES fx_rate_set(id),
  assumption_set_id   BIGINT REFERENCES assumption_set(id),
  reporting_ccy       CHAR(3) REFERENCES currency(code) DEFAULT 'USD',
  fx_value            NUMERIC(18,8),              -- 7.24218 (USD→CNY) 快照
  change_note         TEXT,
  engine_version      TEXT,                       -- 计算引擎版本 (可重算一致性)
  calc_hash           TEXT,                       -- 输入指纹
  created_by          BIGINT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  approved_at         TIMESTAMPTZ,
  UNIQUE (cer_id, version_no)
);
ALTER TABLE cer ADD CONSTRAINT fk_cer_current_ver
  FOREIGN KEY (current_version_id) REFERENCES cer_version(id);
CREATE INDEX ix_ver_draft ON cer_version (cer_id) WHERE status = 'DRAFT';

-- INFO 主输入 (1:1)
CREATE TABLE cer_info (
  cer_version_id          BIGINT PRIMARY KEY REFERENCES cer_version(id) ON DELETE CASCADE,
  initial_capex_po_month  DATE,                   -- 2024-12-30
  p0_cashout_periods      INT,                    -- 2
  sop_fiscal_year         INT,                    -- 2026
  sop_months_in_p1        INT,                    -- 7
  period_months           INT DEFAULT 12,         -- 12
  total_depreciation_months INT,                  -- 55
  depreciation_life_years INT                     -- 5
);

-- 成品 (项目关联的多个成品)
CREATE TABLE cer_fg (
  id              BIGSERIAL PRIMARY KEY,
  cer_version_id  BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  part_master_id  BIGINT NOT NULL REFERENCES part_master(id),
  description     TEXT,
  is_primary      BOOLEAN DEFAULT FALSE,
  line_no         INT,
  UNIQUE (cer_version_id, part_master_id)
);

-- 销量 & 价格预测 (existing/proposed × 12+期)
CREATE TABLE cer_sales_forecast (
  id                    BIGSERIAL PRIMARY KEY,
  cer_version_id        BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  cer_fg_id             BIGINT NOT NULL REFERENCES cer_fg(id) ON DELETE CASCADE,
  scenario              sales_scenario NOT NULL,
  period_no             INT NOT NULL,             -- 1..14
  fiscal_year           INT,
  volume                NUMERIC(18,2) NOT NULL DEFAULT 0,
  unit_price            NUMERIC(18,6) NOT NULL DEFAULT 0,
  currency              CHAR(3) REFERENCES currency(code),
  customer_contribution NUMERIC(18,4) DEFAULT 0,
  rebate                NUMERIC(18,4) DEFAULT 0,
  UNIQUE (cer_version_id, cer_fg_id, scenario, period_no)
);

-- 投资明细 (Mold/Die/Assembly/Others)
CREATE TABLE cer_capex_item (
  id              BIGSERIAL PRIMARY KEY,
  cer_version_id  BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  category        capex_category NOT NULL,
  part_master_id  BIGINT REFERENCES part_master(id),
  description     TEXT,
  tool_no         TEXT,
  concept         TEXT,                            -- 1-Fixed / 5-Integrated / SE-Semi...
  ownership       ownership_type NOT NULL DEFAULT 'TE_ONETIME',
  cavity_or_feed  NUMERIC(12,2),                   -- No.of CAV / Row/Feed / No.of Head
  cycle_or_spm    NUMERIC(12,2),                   -- Cyc.Time / SPM / M/C Speed
  lr_m_per_hr     NUMERIC(12,2),
  mtl             TEXT,
  wt_gross_g      NUMERIC(12,3),
  wt_net_g        NUMERIC(12,3),
  purc_build      NUMERIC(18,4) DEFAULT 0,         -- Purc or Build
  design_dev      NUMERIC(18,4) DEFAULT 0,         -- Design & Develop
  capitalize_rm   NUMERIC(18,4) DEFAULT 0,         -- Capitalize raw material
  expense         NUMERIC(18,4) DEFAULT 0,         -- Expense (费用化)
  currency        CHAR(3) REFERENCES currency(code) DEFAULT 'CNY',
  -- 计算列: Total Capital = purc_build + design_dev + capitalize_rm
  total_capital   NUMERIC(18,4) GENERATED ALWAYS AS (purc_build + design_dev + capitalize_rm) STORED,
  UNIQUE (cer_version_id, category, part_master_id, tool_no)
);

CREATE TABLE cer_capex_followon (
  id              BIGSERIAL PRIMARY KEY,
  cer_version_id  BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  period_no       INT NOT NULL,
  ownership       ownership_type,
  process         TEXT,
  amount          NUMERIC(18,4) NOT NULL DEFAULT 0,
  currency        CHAR(3) REFERENCES currency(code) DEFAULT 'CNY'
);

-- BOM / 成本拆解到原材料级 (自引用层级: FG→BOM→RAW)
CREATE TABLE cer_bom (
  id                BIGSERIAL PRIMARY KEY,
  cer_version_id    BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  cer_fg_id         BIGINT NOT NULL REFERENCES cer_fg(id) ON DELETE CASCADE,
  parent_bom_id     BIGINT REFERENCES cer_bom(id),   -- 层级关系
  level             bom_level NOT NULL,
  seq               INT,
  process           TEXT,                            -- Purchasing/Stamping/Plating/Molding/Assembly
  part_master_id    BIGINT REFERENCES part_master(id),
  material_id       BIGINT REFERENCES material_master(id),
  make_buy          make_buy,
  material_category TEXT,
  qty_per           NUMERIC(18,6) NOT NULL DEFAULT 1,  -- 每成品用量
  unit_price        NUMERIC(18,6) NOT NULL DEFAULT 0,
  currency          CHAR(3) REFERENCES currency(code) DEFAULT 'CNY',
  vendor_profit_pct NUMERIC(9,6) DEFAULT 0,           -- 0.05
  markup_pct        NUMERIC(9,6) DEFAULT 0,           -- TTL Markup 0.06
  -- 计算列: line_cost = qty_per × unit_price × (1 + markup_pct)
  line_cost         NUMERIC(18,6) GENERATED ALWAYS AS (qty_per * unit_price * (1 + markup_pct)) STORED
);
CREATE INDEX ix_bom_fg ON cer_bom (cer_fg_id);
CREATE INDEX ix_bom_parent ON cer_bom (parent_bom_id);

CREATE TABLE cer_process_step (
  id              BIGSERIAL PRIMARY KEY,
  cer_version_id  BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  cer_fg_id       BIGINT NOT NULL REFERENCES cer_fg(id) ON DELETE CASCADE,
  seq             INT,
  process         TEXT NOT NULL,                   -- Stamping/Purchasing/Plating/Molding/Assembly
  station_qty     NUMERIC(8,2),
  cycle_time      NUMERIC(12,3),
  spm             NUMERIC(12,2),
  overhead_rate_id BIGINT REFERENCES overhead_rate(id)
);

CREATE TABLE cer_conversion_cost (
  id              BIGSERIAL PRIMARY KEY,
  cer_version_id  BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  cer_fg_id       BIGINT NOT NULL REFERENCES cer_fg(id) ON DELETE CASCADE,
  cost_type       conversion_type NOT NULL,
  basis           TEXT,
  rate            NUMERIC(18,6),
  unit_cost       NUMERIC(18,6) NOT NULL DEFAULT 0,  -- $/ea
  currency        CHAR(3) REFERENCES currency(code) DEFAULT 'USD'
);

-- =====================================================================
-- L3  CALC OUTPUT (按版本物化)
-- =====================================================================
CREATE TABLE cer_depreciation_schedule (
  id                 BIGSERIAL PRIMARY KEY,
  cer_version_id     BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  cer_capex_item_id  BIGINT REFERENCES cer_capex_item(id),  -- NULL = 资产池汇总
  period_no          INT NOT NULL,
  opening_nbv        NUMERIC(18,4),
  depreciation       NUMERIC(18,4) NOT NULL DEFAULT 0,
  closing_nbv        NUMERIC(18,4),
  allocation_volume  NUMERIC(18,2),                 -- 当期分摊基准产量
  unit_depreciation  NUMERIC(18,6)                  -- $/pc 回流到 cost_rollup
);

CREATE TABLE cer_cost_rollup (
  id                  BIGSERIAL PRIMARY KEY,
  cer_version_id      BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  cer_fg_id           BIGINT REFERENCES cer_fg(id),   -- NULL = 项目加权
  period_no           INT NOT NULL,
  material            NUMERIC(18,4) DEFAULT 0,
  labor               NUMERIC(18,4) DEFAULT 0,
  sustaining_eng      NUMERIC(18,4) DEFAULT 0,
  overhead            NUMERIC(18,4) DEFAULT 0,
  freight_duty        NUMERIC(18,4) DEFAULT 0,
  capital_depreciation NUMERIC(18,4) DEFAULT 0,
  total_mfg_cost      NUMERIC(18,4) DEFAULT 0,
  unit_cost           NUMERIC(18,6) DEFAULT 0,
  std_margin_pct      NUMERIC(9,6) DEFAULT 0,
  UNIQUE (cer_version_id, cer_fg_id, period_no)
);

CREATE TABLE cer_pnl (
  id              BIGSERIAL PRIMARY KEY,
  cer_version_id  BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  pnl_type        pnl_type NOT NULL,
  period_no       INT NOT NULL,                    -- 0..N (0 = Period 0)
  line_item       TEXT NOT NULL,                   -- 'Forecast Sales','Material','Operating Income'...
  amount          NUMERIC(18,4) NOT NULL DEFAULT 0,
  currency        CHAR(3) REFERENCES currency(code) DEFAULT 'USD',
  UNIQUE (cer_version_id, pnl_type, period_no, line_item)
);

CREATE TABLE cer_financial_metric (
  id              BIGSERIAL PRIMARY KEY,
  cer_version_id  BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  pnl_type        pnl_type NOT NULL DEFAULT 'CER',
  scope           metric_scope NOT NULL,
  metric          TEXT NOT NULL,                   -- NPV/IRR/ROIC/PAYBACK/OI_PCT/STD_MARGIN
  value           NUMERIC(18,6),
  UNIQUE (cer_version_id, pnl_type, scope, metric)
);

CREATE TABLE cer_sensitivity (
  id              BIGSERIAL PRIMARY KEY,
  cer_version_id  BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  scenario_label  TEXT NOT NULL,                   -- '100%','75%','50% Yr1-3'...
  volume_factor   NUMERIC(9,6),
  total_sales     NUMERIC(18,4),
  std_margin_pct  NUMERIC(9,6),
  oi_pct          NUMERIC(9,6),
  payback_years   NUMERIC(9,4)
);

CREATE TABLE cer_checklist_item (
  id              BIGSERIAL PRIMARY KEY,
  cer_version_id  BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  check_group     TEXT NOT NULL,                   -- SALES/MFG_COST/EXPENSES/OPERATING/WORKING_CAPITAL
  item            TEXT NOT NULL,
  status          check_status NOT NULL DEFAULT 'CHECK',
  expected        TEXT,
  actual          TEXT,
  note            TEXT,
  UNIQUE (cer_version_id, check_group, item)
);

-- =====================================================================
-- L4  WORKFLOW & AUDIT
-- =====================================================================
CREATE TABLE approval_step (
  id              BIGSERIAL PRIMARY KEY,
  cer_version_id  BIGINT NOT NULL REFERENCES cer_version(id) ON DELETE CASCADE,
  gate            gate_code NOT NULL,
  level           INT NOT NULL,                    -- L1..L5
  role            TEXT,                            -- Cost Engineer / Plant Controller ...
  approver_id     BIGINT,
  decision        approval_decision NOT NULL DEFAULT 'PENDING',
  decided_at      TIMESTAMPTZ,
  comment         TEXT,
  UNIQUE (cer_version_id, gate, level)
);

CREATE TABLE audit_log (
  id              BIGSERIAL PRIMARY KEY,
  cer_version_id  BIGINT REFERENCES cer_version(id),
  entity          TEXT NOT NULL,
  entity_id       BIGINT,
  field           TEXT,
  old_value       TEXT,
  new_value       TEXT,
  user_id         BIGINT,
  ts              TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_audit_ver ON audit_log (cer_version_id, ts);

CREATE TABLE attachment (
  id              BIGSERIAL PRIMARY KEY,
  cer_version_id  BIGINT REFERENCES cer_version(id) ON DELETE CASCADE,
  file_name       TEXT NOT NULL,
  blob_ref        TEXT NOT NULL,
  kind            TEXT,                            -- RFQ / QUOTE / DRAWING / IMDS
  uploaded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- 不可变性保护 (P3): 批准/作废版本禁止修改其输入行
-- =====================================================================
CREATE OR REPLACE FUNCTION cer.guard_frozen_version() RETURNS trigger AS $$
DECLARE st version_status;
DECLARE vid BIGINT;
BEGIN
  vid := COALESCE(NEW.cer_version_id, OLD.cer_version_id);
  SELECT status INTO st FROM cer.cer_version WHERE id = vid;
  IF st IN ('APPROVED','SUPERSEDED') THEN
    RAISE EXCEPTION '版本 % 已冻结(%): 禁止修改输入。请克隆为新草稿版本。', vid, st;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;$$ LANGUAGE plpgsql;

-- 对所有 L2 输入表挂触发器 (示例: 其余表同理 CREATE TRIGGER ...)
CREATE TRIGGER trg_freeze_capex   BEFORE INSERT OR UPDATE OR DELETE ON cer_capex_item
  FOR EACH ROW EXECUTE FUNCTION cer.guard_frozen_version();
CREATE TRIGGER trg_freeze_bom     BEFORE INSERT OR UPDATE OR DELETE ON cer_bom
  FOR EACH ROW EXECUTE FUNCTION cer.guard_frozen_version();
CREATE TRIGGER trg_freeze_sales   BEFORE INSERT OR UPDATE OR DELETE ON cer_sales_forecast
  FOR EACH ROW EXECUTE FUNCTION cer.guard_frozen_version();

-- =====================================================================
-- 版本克隆 (P2 copy-on-write): 基于源版本派生新草稿
-- =====================================================================
CREATE OR REPLACE FUNCTION cer.clone_version(p_src BIGINT, p_new_no TEXT, p_user BIGINT)
RETURNS BIGINT AS $$
DECLARE v_new BIGINT; v_cer BIGINT; v_gate gate_code;
        v_fx BIGINT; v_as BIGINT; v_fxv NUMERIC; v_ccy CHAR(3);
DECLARE map_fg JSONB := '{}'::jsonb;  -- 旧fg.id -> 新fg.id
BEGIN
  SELECT cer_id, gate, fx_rate_set_id, assumption_set_id, fx_value, reporting_ccy
    INTO v_cer, v_gate, v_fx, v_as, v_fxv, v_ccy
  FROM cer.cer_version WHERE id = p_src;

  INSERT INTO cer.cer_version(cer_id,version_no,parent_version_id,gate,status,
        fx_rate_set_id,assumption_set_id,reporting_ccy,fx_value,created_by)
  VALUES (v_cer,p_new_no,p_src,v_gate,'DRAFT',v_fx,v_as,v_ccy,v_fxv,p_user)
  RETURNING id INTO v_new;

  INSERT INTO cer.cer_info SELECT v_new, initial_capex_po_month, p0_cashout_periods,
        sop_fiscal_year, sop_months_in_p1, period_months, total_depreciation_months,
        depreciation_life_years FROM cer.cer_info WHERE cer_version_id = p_src;

  -- FG (需记录 id 映射以便子表重指向)
  WITH ins AS (
    INSERT INTO cer.cer_fg(cer_version_id,part_master_id,description,is_primary,line_no)
    SELECT v_new, part_master_id, description, is_primary, line_no
    FROM cer.cer_fg WHERE cer_version_id = p_src
    RETURNING id, part_master_id )
  SELECT jsonb_object_agg(o.id::text, n.id) INTO map_fg
  FROM cer.cer_fg o JOIN ins n ON n.part_master_id = o.part_master_id
  WHERE o.cer_version_id = p_src;

  INSERT INTO cer.cer_sales_forecast(cer_version_id,cer_fg_id,scenario,period_no,fiscal_year,
        volume,unit_price,currency,customer_contribution,rebate)
  SELECT v_new, (map_fg ->> cer_fg_id::text)::bigint, scenario, period_no, fiscal_year,
        volume,unit_price,currency,customer_contribution,rebate
  FROM cer.cer_sales_forecast WHERE cer_version_id = p_src;

  INSERT INTO cer.cer_capex_item(cer_version_id,category,part_master_id,description,tool_no,
        concept,ownership,cavity_or_feed,cycle_or_spm,lr_m_per_hr,mtl,wt_gross_g,wt_net_g,
        purc_build,design_dev,capitalize_rm,expense,currency)
  SELECT v_new,category,part_master_id,description,tool_no,concept,ownership,cavity_or_feed,
        cycle_or_spm,lr_m_per_hr,mtl,wt_gross_g,wt_net_g,purc_build,design_dev,capitalize_rm,
        expense,currency
  FROM cer.cer_capex_item WHERE cer_version_id = p_src;

  -- cer_bom / process_step / conversion_cost 同理 (略, parent_bom_id 需二次重映射)
  RETURN v_new;
END;$$ LANGUAGE plpgsql;

-- =====================================================================
-- 便利视图: 当前 CapEx 汇总 (CHECK LIST 勾稽用)
-- =====================================================================
CREATE OR REPLACE VIEW v_capex_summary AS
SELECT cer_version_id,
       SUM(total_capital)                                              AS total_capital,
       SUM(total_capital) FILTER (WHERE ownership <> 'CUSTOMER')       AS depreciable_capital,
       SUM(expense + design_dev)                                       AS total_expense
FROM cer_capex_item
GROUP BY cer_version_id;

-- 勾稽断言示例: 折旧总额 == 可折旧投资 (Depreciation Value / Cross Check)
-- SELECT (SELECT SUM(depreciation) FROM cer_depreciation_schedule WHERE cer_version_id=:v)
--      = (SELECT depreciable_capital FROM v_capex_summary WHERE cer_version_id=:v);
