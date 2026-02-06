# PassivBot Comparison Test Report

Generated: 2026-02-06T18:25:16.967
Tolerance: 1.0e-10


## Layer 1: Unit Function Tests

✅ calc_available_margin: 50/50 passed
✅ calc_cost: 50/50 passed
✅ calc_diff: 100/100 passed
✅ calc_ema: 100/100 passed
✅ calc_liq_price: 50/50 passed
✅ calc_long_pnl: 50/50 passed
✅ calc_margin_cost: 50/50 passed
✅ calc_new_psize_pprice: 50/50 passed
✅ calc_shrt_pnl: 50/50 passed
✅ iter_closes: 30/30 passed
✅ iter_entries: 30/30 passed
✅ round_: 100/100 passed
✅ round_dn: 100/100 passed
✅ round_up: 100/100 passed

**Summary**: 910 passed, 0 failed

## Layer 3: Fill Comparison

Python fills: 98
Julia fills: 98
✅ All 98 fills match exactly

## Final Statistics

| Metric | Python | Julia | Match |
|--------|--------|-------|-------|
| gain | 0.069310 | 0.069310 | ✅ |
| ADG | 0.000000 | 0.000000 | ✅ |
| max_drawdown | 0.002568 | 0.002568 | ✅ |
| n_fills | 98.000000 | 98.000000 | ✅ |
| final_balance | 69.309638 | 69.309638 | ✅ |
| final_equity | 69.309638 | 69.309638 | ✅ |

## Layer 2: State Snapshot Comparison

Python snapshots: 775
Julia snapshots: 775
Periodic snapshots: Python=677, Julia=677
✅ All state snapshots match (max diff: 0)

---

## Result: ✅ FULLY CONSISTENT