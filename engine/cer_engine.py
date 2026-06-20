"""
CER Calculation Engine — reference implementation (v1)
======================================================
确定性纯函数: snapshot(版本输入快照) -> result(物化输出) + calc_hash

设计原则
  - 纯函数 / 无副作用 / 无随机 / 无 wall-clock。相同 snapshot 必得相同 result。
  - 内部全程 float 全精度; 仅在 *呈现* 时舍入。校验用绝对容差。
  - 所有跨财年/折旧/折现/营运资本公式均从真实样本 PRJ-24-000902644 反推校准。

计算 DAG (见 docs/calc-engine.md §3)
  sales_phasing -> revenue
  bom -> material_per_unit ┐
  capex -> depreciation ───┼-> cost_rollup -> std_margin
  conversion ──────────────┘
  cost_rollup -> pnl(OI) -> working_capital -> net_cash_flow
  net_cash_flow -> npv / irr / payback / roic ; + sensitivity ; + checklist
"""
from __future__ import annotations
import hashlib, json
from dataclasses import dataclass, field
from typing import Any

ENGINE_VERSION = "cer-engine/1.0.0"


# ----------------------------------------------------------------------
# 工具
# ----------------------------------------------------------------------
def calc_hash(snapshot: dict) -> str:
    """输入指纹: 规范化 JSON 的 sha256, 与 engine_version 绑定。"""
    canon = json.dumps(snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return ENGINE_VERSION + ":" + hashlib.sha256(canon.encode("utf-8")).hexdigest()[:16]


def npv(rate: float, flows: list[float], mid_year: bool = True) -> float:
    """
    中点折现 (mid-year convention)。
    flows[0] = Period 0 (CAPEX), 不折现; flows[k>=1] 在 t = k - 0.5 处折现。
    复刻样本: NPV(CER) = $4,667,243。
    """
    total = 0.0
    for k, cf in enumerate(flows):
        if k == 0:
            total += cf                      # CAPEX 不折现
        else:
            t = (k - 0.5) if mid_year else k
            total += cf / (1.0 + rate) ** t
    return total


def irr(flows: list[float], mid_year: bool = True, lo: float = -0.95, hi: float = 1000.0) -> float:
    """二分法求 IRR (NPV=0)。本地化项目现金流前正后零, IRR 极高, 故上界放大。"""
    f_lo = npv(lo, flows, mid_year)
    f_hi = npv(hi, flows, mid_year)
    if f_lo * f_hi > 0:
        return float("nan")
    for _ in range(200):
        mid = (lo + hi) / 2
        fm = npv(mid, flows, mid_year)
        if abs(fm) < 1e-6:
            return mid
        if f_lo * fm < 0:
            hi, f_hi = mid, fm
        else:
            lo, f_lo = mid, fm
    return (lo + hi) / 2


def payback_years(flows: list[float]) -> float:
    """累计现金流首次转正的年数 (线性插值)。Period 0 视为 t=0。"""
    cum = 0.0
    for k, cf in enumerate(flows):
        prev = cum
        cum += cf
        if cum >= 0 and prev < 0:
            frac = -prev / cf if cf != 0 else 0.0
            return (k - 1) + frac        # k-1 因为 P0 在 t=0
    return float("nan")


# ----------------------------------------------------------------------
# 模块 1: 销量跨财年分摊 (project periods -> fiscal periods)
# ----------------------------------------------------------------------
def phase_volumes(proj: list[float], sop_months_in_p1: int) -> list[float]:
    """
    项目期(自 SOP 起的 12 个月桶) -> 财年期。
    规则 (从样本反推, sop_months_in_p1=7):
        shift = 12 - m
        fiscal[0] = proj[0]            (SOP 残桶, 整体落入首财年) + proj[1]*shift/12
        fiscal[k] = proj[k]*m/12 + proj[k+1]*shift/12   (k>=1)
    复刻样本: [600k,1M,1M,1M,1M] -> [1,016,667, 1M,1M,1M, 583,333]。
    """
    m, shift, n = sop_months_in_p1, 12 - sop_months_in_p1, len(proj)
    out = [0.0] * n
    for k in range(n):
        if k == 0:
            out[0] = proj[0] + (proj[1] * shift / 12 if n > 1 else 0.0)
        else:
            spill = proj[k + 1] * shift / 12 if k + 1 < n else 0.0
            out[k] = proj[k] * m / 12 + spill
    return out


# ----------------------------------------------------------------------
# 模块 2: BOM 物料卷积 (component -> material_per_unit)
# ----------------------------------------------------------------------
def bom_material_per_unit(bom_lines: list[dict], fx_usd_to_cny: float) -> float:
    """
    line_cost(CNY) = qty * unit_price * (1 + markup); 汇总后折 USD。
    成品 -> BOM -> 原材料 逐级 roll-up 的叶子求和。
    """
    total_cny = sum(
        ln["qty"] * ln["unit_price"] * (1 + ln.get("markup", 0.0)) for ln in bom_lines
    )
    return total_cny / fx_usd_to_cny


# ----------------------------------------------------------------------
# 模块 3: 折旧计划 (capex -> straight-line schedule)
# ----------------------------------------------------------------------
def depreciation_schedule(depreciable_capital: float, total_dep_months: int,
                          n_periods: int, period_months: int = 12) -> list[float]:
    """
    直线法, 按月计提: monthly = capital / total_dep_months。
    末期为不足整年的余月 (样本: 55 = 12*4 + 7)。客户买断资本已在上游排除。
    复刻样本: [51,871.32]*4 + [30,258.27], 合计 = 237,743.55 = 总投资。
    """
    monthly = depreciable_capital / total_dep_months
    out, remaining = [], total_dep_months
    for _ in range(n_periods):
        mo = min(period_months, max(remaining, 0))
        out.append(monthly * mo)
        remaining -= mo
    return out


# ----------------------------------------------------------------------
# 模块 4: 营运资本 (sales/cost -> NWC, 按账期)
# ----------------------------------------------------------------------
def net_working_capital(sales: float, total_mfg: float, material: float,
                        ar_days: int, inv_days: int, ap_days: int) -> float:
    ar = sales * ar_days / 365.0
    inventory = total_mfg * inv_days / 365.0
    ap = material * ap_days / 365.0
    return inventory + ar - ap


# ----------------------------------------------------------------------
# 主引擎
# ----------------------------------------------------------------------
@dataclass
class EngineResult:
    fiscal_units: list[float] = field(default_factory=list)
    cost_rollup: list[dict] = field(default_factory=list)
    pnl: list[dict] = field(default_factory=list)
    depreciation: list[float] = field(default_factory=list)
    net_cash_flow: list[float] = field(default_factory=list)
    metrics: dict[str, float] = field(default_factory=dict)
    checklist: list[dict] = field(default_factory=list)
    calc_hash: str = ""
    engine_version: str = ENGINE_VERSION


def compute(snap: dict) -> EngineResult:
    v = snap["version"]
    info = snap["info"]
    fx = v["fx_usd_to_cny"]
    wacc = v["wacc"]
    tax = v.get("tax_rate", 0.25)
    n = info["life_years"]
    fg = snap["fg"][0]                       # 单成品样本; 多成品按量加权扩展
    asp = fg["asp"]

    # 1) 销量分摊 + 营收 -----------------------------------------------
    proj_vol = snap["sales_proposed"][fg["part_no"]]
    units = phase_volumes(proj_vol, info["sop_months_in_p1"])
    revenue = [u * asp for u in units]

    # 2) 单件成本要素 -------------------------------------------------
    cpu = snap["cost_per_unit_usd"]          # labor/overhead/sustaining_mfg/freight_duty
    material_pu = cpu.get("material") or bom_material_per_unit(
        snap.get("bom", {}).get(fg["part_no"], []), fx)

    # 3) 折旧池 (排除客户买断) ----------------------------------------
    dep_capital_cny = sum(
        (it["purc_build"] + it["design_dev"] + it["capitalize_rm"])
        for it in snap["capex"] if it["ownership"] != "CUSTOMER")
    dep_capital_usd = dep_capital_cny / fx
    dep = depreciation_schedule(dep_capital_usd, info["total_depreciation_months"], n,
                                info.get("period_months", 12))

    # 4) 成本卷积 + 5) P&L + 6) 营运资本 + 7) 现金流 ------------------
    rollup, pnl_rows, ncf = [], [], []
    opex_other = snap.get("opex_other_per_period", [0.0] * n)   # growth+sustaining(opex)+other
    nwc_prev = 0.0
    capex_usd = dep_capital_usd                                # 全部 P0 流出
    ncf.append(-capex_usd)                                     # Period 0

    for k in range(n):
        u, sales = units[k], revenue[k]
        mat = material_pu * u
        lab = cpu["labor"] * u
        oh = cpu["overhead"] * u
        sust_mfg = cpu["sustaining_mfg"] * u
        frt = cpu["freight_duty"] * u
        depr = dep[k]
        total_mfg = mat + lab + sust_mfg + oh + frt + depr
        unit_cost = total_mfg / u if u else 0.0
        std_margin = (sales - total_mfg) / sales if sales else 0.0

        sga = sales * v["sga_pct"]
        distrib = sales * v["outbound_ship_pct"]
        opex = sga + distrib + opex_other[k]
        oi = sales - total_mfg - opex

        nwc = net_working_capital(sales, total_mfg, mat,
                                  v["ar_days"], v["inv_days"], v["ap_days"])
        d_nwc = nwc - nwc_prev
        nwc_prev = nwc
        # 现金流 (税前, 与样本勾稽一致): OI + 折旧回加 - ΔNWC
        ncf.append(oi + depr - d_nwc)

        rollup.append(dict(period=k + 1, units=u, material=mat, labor=lab,
                           sustaining_eng=sust_mfg, overhead=oh, freight_duty=frt,
                           capital_depreciation=depr, total_mfg_cost=total_mfg,
                           unit_cost=unit_cost, std_margin_pct=std_margin))
        for li, amt in [("Forecast Sales", sales), ("Material", mat), ("Labor Cost", lab),
                        ("Overhead", oh), ("Freight & Duty", frt),
                        ("Capital Depreciation", depr), ("Total Manufacturing Costs", total_mfg),
                        ("SG&A", sga), ("Distribution and Shipping", distrib),
                        ("Operating Income", oi)]:
            pnl_rows.append(dict(period=k + 1, line_item=li, amount=amt))

    # 末期回收剩余营运资本 (terminal WC unwind)
    ncf.append(nwc_prev)

    # 8) 财务指标 ------------------------------------------------------
    total_sales = sum(revenue)
    total_oi = sum(p["amount"] for p in pnl_rows if p["line_item"] == "Operating Income")
    val_npv = npv(wacc, ncf, mid_year=True)
    val_irr = irr(ncf, mid_year=False)   # Excel IRR() = 年末约定; NPV/DCF 用中点 (见 docs §4.7)
    val_pb = payback_years(ncf)
    avg_margin = sum(r["std_margin_pct"] * r["units"] for r in rollup) / sum(r["units"] for r in rollup)
    invested = capex_usd + max((r2 for r2 in [nwc_prev]), default=0)
    nopat = total_oi * (1 - tax)
    roic = nopat / invested if invested else 0.0   # 文档定义版; 与样本量级一致

    metrics = dict(total_sales=total_sales, operating_income=total_oi,
                   oi_pct=total_oi / total_sales if total_sales else 0.0,
                   npv=val_npv, irr=val_irr, payback=val_pb,
                   avg_std_margin=avg_margin, roic_overall=roic,
                   depreciable_capital=dep_capital_usd,
                   total_depreciation=sum(dep))

    # 9) 勾稽校验 (CHECK LIST) ----------------------------------------
    checklist = _checklist(snap, units, dep, dep_capital_usd, info)

    res = EngineResult(fiscal_units=units, cost_rollup=rollup, pnl=pnl_rows,
                       depreciation=dep, net_cash_flow=ncf, metrics=metrics,
                       checklist=checklist, calc_hash=calc_hash(snap))
    return res


def _checklist(snap, units, dep, dep_capital_usd, info) -> list[dict]:
    out = []
    # 折旧值勾稽: Σ折旧 == 可折旧投资
    out.append(dict(group="MFG_COST", item="Depreciation Value Check",
                    status="OK" if abs(sum(dep) - dep_capital_usd) < 1.0 else "CHECK",
                    expected=round(dep_capital_usd, 2), actual=round(sum(dep), 2)))
    # 折旧寿命勾稽
    out.append(dict(group="MFG_COST", item="Depreciation Life Check",
                    status="OK" if info["depreciation_life_years"] == info["life_years"] else "CHECK",
                    expected=info["life_years"], actual=info["depreciation_life_years"]))
    # 销量勾稽: 分摊后总量 == 提报总量
    proj_total = sum(snap["sales_proposed"][snap["fg"][0]["part_no"]])
    out.append(dict(group="SALES", item="Sales Volume Check",
                    status="OK" if abs(sum(units) - proj_total) < 1.0 else "CHECK",
                    expected=proj_total, actual=round(sum(units), 0)))
    return out


if __name__ == "__main__":
    import sys, pathlib
    snap = json.loads(pathlib.Path(sys.argv[1] if len(sys.argv) > 1
                      else "engine/sample_PRJ24.json").read_text())
    r = compute(snap)
    print("calc_hash:", r.calc_hash)
    print("fiscal_units:", [round(x) for x in r.fiscal_units])
    print("depreciation:", [round(x, 2) for x in r.depreciation], "Σ=", round(sum(r.depreciation), 2))
    print("unit_cost P1:", round(r.cost_rollup[0]["unit_cost"], 4),
          "std_margin P1:", round(r.cost_rollup[0]["std_margin_pct"], 4))
    print("net_cash_flow:", [round(x) for x in r.net_cash_flow])
    for k in ("total_sales", "operating_income", "oi_pct", "npv", "irr", "payback", "avg_std_margin"):
        print(f"  {k:18} = {r.metrics[k]:,.4f}")
    print("checklist:", [(c["item"], c["status"]) for c in r.checklist])
