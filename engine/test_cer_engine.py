"""
Golden 测试 — 验证计算引擎对真实样本 PRJ-24-000902644 (G4) 的数值复刻。
所有期望值取自原 Excel workbook (CER P&L / Data for PAC / CAPEX / Capital Depreciation)。

运行:  python3 engine/test_cer_engine.py        (自带 runner, 打印 PASS/FAIL)
   或:  pytest engine/test_cer_engine.py
"""
import json, pathlib, math
from cer_engine import (compute, phase_volumes, bom_material_per_unit,
                        depreciation_schedule, net_working_capital, npv, irr, calc_hash)

SNAP = json.loads((pathlib.Path(__file__).parent / "sample_PRJ24.json").read_text())
R = compute(SNAP)


def approx(a, b, tol):
    assert abs(a - b) <= tol, f"期望 {b}, 实得 {a}, 偏差 {abs(a-b):.4f} > 容差 {tol}"


# ---- 模块级单元测试 -------------------------------------------------
def test_phasing_reproduces_fiscal_units():
    """销量跨财年分摊: [600k,1M,1M,1M,1M] -> [1,016,667,1M,1M,1M,583,333]"""
    f = phase_volumes([600000, 1000000, 1000000, 1000000, 1000000], 7)
    approx(f[0], 1016666.667, 0.5)
    approx(f[1], 1000000, 0.5)
    approx(f[4], 583333.333, 0.5)
    approx(sum(f), 4600000, 0.5)            # 守恒: 总量不变


def test_bom_rollup_exact():
    """精确合成用例: line_cost = qty*price*(1+markup) 逐叶求和"""
    lines = [{"qty": 2, "unit_price": 5.0, "markup": 0.10},   # 11.0
             {"qty": 1, "unit_price": 3.0, "markup": 0.00}]   #  3.0
    approx(bom_material_per_unit(lines, 2.0), (11.0 + 3.0) / 2.0, 1e-9)


def test_depreciation_straight_line():
    """直线按月: 55 月 = 12*4 + 7; 合计 == 可折旧投资"""
    cap = 237743.55
    sch = depreciation_schedule(cap, 55, 5, 12)
    approx(sch[0], 51871.32, 0.05)
    approx(sch[4], 30258.27, 0.05)
    approx(sum(sch), cap, 0.01)             # 关键勾稽


def test_working_capital_components():
    """营运资本按账期: AR=sales*97/365, Inv=mfg*55/365, AP=material*70/365"""
    nwc = net_working_capital(3790295.19, 2234341.14, 1794819.63, 97, 55, 70)
    approx(nwc, 999753, 200)                # 样本 NWC P1


def test_npv_mid_year_vs_irr_end_year():
    """NPV 中点折现; IRR 年末约定 (Excel IRR())"""
    flows = R.net_cash_flow
    approx(npv(0.105, flows, mid_year=True), 4667243, 2000)
    approx(irr(flows, mid_year=False), 2.9364, 0.01)


# ---- 全链路 Golden (对真实 Excel) -----------------------------------
def test_golden_fiscal_units():
    exp = [1016667, 1000000, 1000000, 1000000, 583333]
    for got, e in zip(R.fiscal_units, exp):
        approx(got, e, 1)


def test_golden_depreciation():
    approx(R.depreciation[0], 51871.32, 0.05)
    approx(sum(R.depreciation), 237743.55, 0.01)


def test_golden_period1_costs():
    p1 = R.cost_rollup[0]
    approx(p1["material"], 1794819.63, 50)
    approx(p1["labor"], 198700.98, 50)
    approx(p1["overhead"], 135775.49, 50)
    approx(p1["freight_duty"], 42954.06, 50)
    approx(p1["capital_depreciation"], 51871.32, 1)
    approx(p1["total_mfg_cost"], 2234341.14, 100)
    approx(p1["unit_cost"], 2.1977, 0.001)
    approx(p1["std_margin_pct"], 0.41051, 0.0005)


def test_golden_metrics():
    m = R.metrics
    approx(m["total_sales"], 17149532.32, 1)
    approx(m["operating_income"], 6315962, 200)
    approx(m["oi_pct"], 0.36828, 0.0005)
    approx(m["avg_std_margin"], 0.41033, 0.0005)
    approx(m["npv"], 4667243, 2000)
    approx(m["irr"], 2.9364, 0.01)
    approx(m["payback"], 0.557, 0.05)
    approx(m["total_depreciation"], 237743.55, 1)


def test_golden_net_cash_flow():
    exp = [-237744, 448721, 1440975, 1424716, 1424716, 1240873, 573705]
    for got, e in zip(R.net_cash_flow, exp):
        approx(got, e, 50)                  # ΔWC/opex 舍入引致 <$50


def test_reconciliation_checklist_all_ok():
    for c in R.checklist:
        assert c["status"] == "OK", f"勾稽失败: {c}"


def test_determinism():
    """相同输入 -> 相同 hash 与结果"""
    assert calc_hash(SNAP) == calc_hash(SNAP)
    assert compute(SNAP).metrics["npv"] == R.metrics["npv"]


# ---- 自带 runner -----------------------------------------------------
if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    npass = 0
    print(f"\n  Golden 测试 · 样本 PRJ-24-000902644 (G4) · {R.engine_version}\n" + "-" * 64)
    for t in tests:
        try:
            t()
            print(f"  \033[32mPASS\033[0m  {t.__name__}")
            npass += 1
        except AssertionError as e:
            print(f"  \033[31mFAIL\033[0m  {t.__name__}: {e}")
    print("-" * 64)
    print(f"  {npass}/{len(tests)} 通过\n")
    # 保真度对照表 (引擎 vs Excel)
    print("  保真度对照 (引擎 → Excel):")
    pairs = [("单件成本 $/ea", R.cost_rollup[0]["unit_cost"], 2.198),
             ("毛利率", R.cost_rollup[0]["std_margin_pct"], 0.4105),
             ("折旧合计 $", sum(R.depreciation), 237743.55),
             ("营收合计 $", R.metrics["total_sales"], 17149532),
             ("营业利润 $", R.metrics["operating_income"], 6315962),
             ("NPV $", R.metrics["npv"], 4667243),
             ("IRR", R.metrics["irr"], 2.9364)]
    for nm, got, exc in pairs:
        d = got - exc
        print(f"    {nm:14} 引擎={got:>14,.4f}  Excel={exc:>14,.4f}  Δ={d:>10,.2f}")
    raise SystemExit(0 if npass == len(tests) else 1)
