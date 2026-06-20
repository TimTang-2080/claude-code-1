# CER 计算引擎规格 (v1)

> 把 [`data-model.md`](./data-model.md) §6 的计算 DAG，固化为一个**确定性、可测试、可复现**的计算服务。
> 参考实现：[`engine/cer_engine.py`](../engine/cer_engine.py) · Golden 测试：[`engine/test_cer_engine.py`](../engine/test_cer_engine.py)（对真实样本 `PRJ-24-000902644 G4`，**12/12 通过**）。

---

## 1. 引擎契约

```
compute(snapshot) -> EngineResult
```

| | 说明 |
|---|---|
| **输入** | `snapshot`：某个 `cer_version` 的**完整输入快照**（INFO + FG + sales + capex + bom + conversion + 固化的假设/FX）。见 [`engine/sample_PRJ24.json`](../engine/sample_PRJ24.json)。 |
| **输出** | `EngineResult`：`cost_rollup` / `pnl` / `depreciation` / `net_cash_flow` / `metrics` / `checklist` + `calc_hash` + `engine_version`。物化写入 L3 表。 |
| **副作用** | 无。纯函数。 |

### 1.1 确定性原则

1. **纯函数**：无随机、无 wall-clock、无外部 I/O、无全局可变状态。
2. **输入闭包**：所有依赖（FX、WACC、费率、账期）随 `snapshot` 固化传入——不读 live 主数据，保证历史版本可复现（呼应数据模型 P4）。
3. **全精度内算**：内部 `float` 全程不舍入；仅呈现/对账时舍入。
4. **`calc_hash`**：`engine_version + sha256(canonical_json(snapshot))[:16]`。同输入 → 同 hash → 同结果。`engine_version` 变更（公式修订）即视为新结果谱系。

---

## 2. 输入快照结构（节选）

```jsonc
{
  "version": { "fx_usd_to_cny": 7.24218, "wacc": 0.105, "tax_rate": 0.25,
               "sga_pct": 0.0227, "outbound_ship_pct": 0.01,
               "ar_days": 97, "inv_days": 55, "ap_days": 70 },
  "info":    { "life_years": 5, "sop_months_in_p1": 7,
               "period_months": 12, "total_depreciation_months": 55,
               "depreciation_life_years": 5 },
  "fg":      [ { "part_no": "2483376-1", "asp": 3.7281592 } ],
  "sales_proposed": { "2483376-1": [600000,1000000,1000000,1000000,1000000] },
  "cost_per_unit_usd": { "material":1.7654, "labor":0.1954, "overhead":0.1335,
                         "sustaining_mfg":0.0101, "freight_duty":0.0422 },
  "opex_other_per_period": [35408, 34828, 34828, 34828, 20316],
  "capex":   [ { "category":"MOLD", "ownership":"TE_ONETIME",
                 "purc_build":637260, "capitalize_rm":20000, ... } ],
  "bom":     { "2483376-1": [ {"qty":1,"unit_price":3.21,"markup":0.06}, ... ] }
}
```
> `cost_per_unit_usd.material` 可省略——此时引擎从 `bom` 卷积得出（见 §4.2）。`labor/overhead/freight` 等转换成本，当前由上游费率表（`labor_rate`/`overhead_rate`/`Freight & Burden`）解析为单件值后传入；后续版本可内联费率计算。

---

## 3. 计算 DAG

```
sales_phasing ──▶ revenue
bom ──▶ material_per_unit ┐
capex ─▶ depreciation ────┼─▶ cost_rollup ─▶ std_margin
conversion ───────────────┘
cost_rollup ─▶ pnl(OI) ─▶ working_capital ─▶ net_cash_flow
net_cash_flow ─▶ npv | irr | payback | roic
              └▶ sensitivity ; checklist
```

---

## 4. 模块规格与公式

> 每条公式后标注从真实样本反推校准的依据值。

### 4.1 销量跨财年分摊 `phase_volumes(proj, m)`
项目期（自 SOP 起 12 个月桶）→ 财年期。`m = sop_months_in_p1 = 7`，`shift = 12 − m = 5`：

```
fiscal[0] = proj[0]              + proj[1]·shift/12      # SOP 残桶整体计入首财年
fiscal[k] = proj[k]·m/12         + proj[k+1]·shift/12    # k ≥ 1
```
**校准**：`[600k,1M,1M,1M,1M] → [1,016,667, 1M, 1M, 1M, 583,333]`，总量守恒 4.6M。

### 4.2 物料卷积 `bom_material_per_unit(bom, fx)`
```
line_cost_CNY = qty · unit_price · (1 + markup)
material_per_unit_USD = Σ line_cost_CNY / fx
```
成品 → BOM → 原材料的叶子求和。**校准**：13 个外购件 → ≈ $1.7654/ea。

### 4.3 折旧计划 `depreciation_schedule(cap, total_months, n, period_months)`
直线法按月计提，末期为不足整年的余月：
```
monthly      = depreciable_capital / total_depreciation_months
period_dep[k]= monthly · months_in_period[k]      # [12,12,12,12,7] (Σ=55)
```
- `depreciable_capital` = Σ capex(`purc_build+design_dev+capitalize_rm`)，**排除 `ownership=CUSTOMER`**（客户买断不进 TE 折旧池）。
- **校准**：$237,743.55 / 55 × 12 = **$51,871.32**（P1–P4）；× 7 = **$30,258.27**（P5）；合计回到 $237,743.55。

### 4.4 成本卷积 `cost_rollup`（逐财年期）
```
material = material_pu · units ;  labor = labor_pu · units ;  (OH / sustaining / freight 同理)
total_mfg_cost = material + labor + sustaining_mfg + overhead + freight_duty + period_dep
unit_cost      = total_mfg_cost / units
std_margin     = (sales − total_mfg_cost) / sales
```
**校准**：P1 unit_cost = **$2.198**，std_margin = **41.05%**。

### 4.5 P&L / 营业利润
```
SG&A          = sales · sga_pct            (2.27%)     → 校准 $86,040
Distribution  = sales · outbound_ship_pct  (1.0%)      → 校准 $37,903
OPEX          = SG&A + Distribution + opex_other       (Growth/Sustaining(OPEX)/Other, 输入)
Operating Income = sales − total_mfg_cost − OPEX       → 校准 OI% 36.83%
```

### 4.6 营运资本 `net_working_capital`
```
AR        = sales      · ar_days/365   (97d)  → $1,007,284
Inventory = total_mfg  · inv_days/365  (55d)  → $336,702
AP        = material   · ap_days/365   (70d)  → $344,179
NWC       = Inventory + AR − AP               → ≈ $999,753 (P1)
```

### 4.7 现金流 / NPV / IRR / Payback
```
NCF[0]      = −capex                                   (Period 0, 税前)
NCF[k]      = OI[k] + depreciation[k] − ΔNWC[k]        ΔNWC = NWC[k] − NWC[k−1]
NCF[末+1]   = NWC[last]                                (期末回收营运资本)
```
> **双折现约定**（关键，从样本反推）：
> - **NPV / DCF 表 = 中点折现**：`DCF[k] = NCF[k] / (1+wacc)^(k−0.5)`，CAPEX(P0) 不折现 → **NPV $4,667,243**。
> - **IRR = 年末约定**（等价 Excel `IRR()`）：`NCF[k]` 置于 `t=k` → **IRR 293.6%**。
> 两者刻意不同：DCF 行用中点更保守，IRR 沿用电子表内置函数口径。引擎对二者分别实现。

`payback` = 累计 NCF 首次转正的年数（线性插值），P0 视为 t=0。

### 4.8 ROIC（文档定义版）
`ROIC = OI·(1−tax) / (capex + 期末NWC)`。量级与样本 92% 一致；精确口径（含分年投入资本）将在 v1.1 细化。

---

## 5. 勾稽校验（自动断言，落 `cer_checklist_item`）

| 校验项 | 断言 | 样本 |
|---|---|---|
| Depreciation Value Check | `Σ depreciation == depreciable_capital` | $237,743.55 ✓ |
| Depreciation Life Check | `depreciation_life_years == life_years` | 5 == 5 ✓ |
| Sales Volume Check | `Σ fiscal_units == Σ proposed_volume` | 4.6M ✓ |

> 其余 CHECK LIST 项（Material / Labor&OH / Freight&Duty / Investment / OI / Working Capital）按相同模式扩展为断言。

---

## 6. 保真度（引擎 vs 真实 Excel）

`python3 engine/test_cer_engine.py` → **12/12 通过**：

| 指标 | 引擎 | Excel | Δ |
|---|--:|--:|--:|
| 财年销量 P1 | 1,016,667 | 1,016,667 | 0 |
| 折旧合计 | 237,743.55 | 237,743.55 | 0.00 |
| 单件成本 | 2.1977 | 2.198 | <0.001 |
| 毛利率 | 41.05% | 41.05% | 0 |
| 营收合计 | 17,149,532 | 17,149,532 | 0.32 |
| 营业利润 | 6,316,011 | 6,315,962 | 49 |
| **NPV** | **4,667,280** | **4,667,243** | **37** |
| **IRR** | **293.64%** | **293.64%** | **0.00** |

> 残差 < $50，源于上游单件成本/OPEX 的小数舍入；核心公式（分摊、折旧、中点 NPV、年末 IRR）数值级吻合。

---

## 7. 错误与校验模型

- **输入校验**（服务层，先于 `compute`）：必填项、量纲、`Σproposed_volume>0`、`ownership` 枚举、负值规则。
- **计算告警**：除零（`units==0` 期）、IRR 不收敛（返回 `NaN` 并标记）、勾稽未过 → `checklist.status=CHECK`（不阻断计算，但阻断 G4 提交）。
- **可复现保证**：结果随 `calc_hash` 落库；重算时 hash 不变即可信缓存命中。

## 8. 版本演进

`engine_version` 语义化：公式修订（影响数值）→ 升 minor；重构/性能（不影响数值）→ 升 patch。历史 `cer_version` 记录其 `engine_version`，确保审计时用**当时的引擎**重算。
