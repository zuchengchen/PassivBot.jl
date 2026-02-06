# Backtest Comparison Design: Julia vs Python

**Date:** 2026-02-06  
**Goal:** 确保Julia版本回测与Python版本数值完全一致（误差 < 1e-10）

---

## 概述

### 测试命令
```bash
# Julia
julia --project=. scripts/backtest.jl configs/live/lev10x_stable.json -s RIVERUSDT --start-date 2026-02-01 --end-date 2026-02-02

# Python
python backtest.py configs/backtest/default.json -lc configs/live/lev10x_stable.json -s RIVERUSDT --start_date 2026-02-01 --end_date 2026-02-02
```

### 一致性要求
- **数值完全一致**：每个fill的所有字段误差 < 1e-10
- **比较范围**：Fill详情、中间计算值、最终统计指标、订单生成逻辑
- **方法**：分步运行两个版本，输出中间结果到文件，然后对比

---

## 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                    Layer 1: 单元函数对比                      │
│  calc_ema, calc_diff, round_, iter_entries 等核心函数         │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                    Layer 2: 中间状态对比                      │
│  每N个tick输出: EMA值, volatility, bids/asks, position状态    │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                    Layer 3: Fill结果对比                      │
│  每个fill的完整字段: qty, price, pnl, fee, timestamp等        │
└─────────────────────────────────────────────────────────────┘
```

---

## Layer 1: 单元函数对比

### 需要对比的函数

| Python (jitted.py) | Julia (Jitted.jl) | 功能 |
|-------------------|-------------------|------|
| `round_` | `round_` | 价格/数量取整 |
| `round_up` | `round_up` | 向上取整 |
| `round_dn` | `round_dn` | 向下取整 |
| `calc_diff` | `calc_diff` | 计算百分比差异 |
| `calc_ema` | `calc_ema` | EMA计算 |
| `calc_bid_ask_thresholds` | `calc_bid_ask_thresholds` | 买卖阈值 |
| `calc_liq_price` | `calc_liq_price` | 清算价格 |
| `calc_available_margin` | `calc_available_margin` | 可用保证金 |
| `calc_new_psize_pprice` | `calc_new_psize_pprice` | 新仓位计算 |
| `iter_entries` | `iter_entries` | 入场订单迭代 |
| `iter_closes` | `iter_closes` | 平仓订单迭代 |

### 测试方法
- 为每个函数生成相同的测试输入（固定随机种子）
- 两边运行，输出结果到JSON
- 逐字段对比，误差阈值 1e-10

---

## Layer 2: 中间状态对比

### 状态快照内容

```json
{
  "tick_index": 1000,
  "timestamp": 1706745600000,
  "price": 0.01234,
  
  "ema": {
    "ema_span": 5000.0,
    "ema_spread": 0.002,
    "ema": 0.012345,
    "ema_alpha": 0.0004,
    "ema_alpha_": 0.9996
  },
  
  "volatility": {
    "volatility": 0.0015,
    "volatility_array": [0.001, 0.0012, ...]
  },
  
  "position": {
    "long_psize": 100.0,
    "long_pprice": 0.01230,
    "shrt_psize": 0.0,
    "shrt_pprice": 0.0
  },
  
  "balance": {
    "balance": 1000.5,
    "equity": 1001.2
  },
  
  "orders": {
    "bids": [{"qty": 50, "price": 0.01220}, ...],
    "asks": [{"qty": 50, "price": 0.01250}, ...]
  },
  
  "thresholds": {
    "bid_thr": 0.01225,
    "ask_thr": 0.01245
  }
}
```

### 快照频率
- 每 1000 个 tick 输出一次状态
- 每次 fill 发生时额外输出一次（标记 `"trigger": "fill"`）

### 对比策略

| 字段类型 | 对比方式 | 容差 |
|---------|---------|------|
| 整数 (tick_index, timestamp) | 精确匹配 | 0 |
| 浮点数 (ema, price, qty) | 绝对误差 | 1e-10 |
| 数组 (volatility_array, bids) | 逐元素对比 | 1e-10 |

---

## Layer 3: Fill结果对比

### Fill记录结构

```json
{
  "trade_id": 1,
  "timestamp": 1706745612345,
  "tick_index": 1523,
  
  "fill_info": {
    "type": "long_reentry",
    "side": "buy",
    "qty": 50.0,
    "price": 0.01225,
    "pside": "long"
  },
  
  "pnl": {
    "pnl": 0.0,
    "fee_paid": -0.00011025,
    "realized_pnl": 0.0
  },
  
  "position_after": {
    "long_psize": 150.0,
    "long_pprice": 0.012267,
    "shrt_psize": 0.0,
    "shrt_pprice": 0.0
  },
  
  "balance_after": {
    "balance": 999.89,
    "equity": 1000.12,
    "available_margin": 850.5
  },
  
  "risk": {
    "closest_liq": 0.85,
    "liq_price": 0.00180
  }
}
```

### 差异报告格式

```markdown
## Fill #15 差异

| 字段 | Python | Julia | 差异 |
|------|--------|-------|------|
| qty | 50.00000000 | 50.00000001 | 1e-8 ❌ |
| price | 0.01225000 | 0.01225000 | 0 ✅ |
| long_pprice | 0.01226700 | 0.01226700 | 0 ✅ |
| pnl | 0.00000000 | 0.00000000 | 0 ✅ |

### 上下文
- tick_index: 1523
- 触发价格: 0.01224
- 前一个fill: #14 (long_initial_entry)
```

---

## 文件结构

```
test/comparison/
├── unit_test_python.py       # Python单元函数测试 (~150行)
├── unit_test_julia.jl        # Julia单元函数测试 (~150行)
├── backtest_python.py        # Python回测+状态输出 (~200行)
├── backtest_julia.jl         # Julia回测+状态输出 (~200行)
├── compare.jl                # 对比脚本+报告生成 (~300行)
├── run_comparison.sh         # 一键运行脚本 (~30行)
└── output/
    ├── python/
    │   ├── fills.json
    │   ├── states.json
    │   └── unit_tests.json
    └── julia/
        ├── fills.json
        ├── states.json
        └── unit_tests.json
```

---

## 运行方式

```bash
# 一键运行完整对比
./test/comparison/run_comparison.sh \
  --config configs/live/lev10x_stable.json \
  --symbol RIVERUSDT \
  --start-date 2026-02-01 \
  --end-date 2026-02-02
```

---

## 预期输出

```
=====================================
PassivBot Comparison Test Report
=====================================

Config: lev10x_stable.json
Symbol: RIVERUSDT
Period: 2026-02-01 ~ 2026-02-02

Layer 1: Unit Functions
-----------------------
✅ round_: 100/100 passed
✅ calc_ema: 100/100 passed
✅ calc_diff: 100/100 passed
✅ iter_entries: 50/50 passed
✅ iter_closes: 50/50 passed

Layer 2: State Snapshots
------------------------
Total snapshots: 1,234
✅ All snapshots match (max diff: 2.3e-15)

Layer 3: Fills
--------------
Python fills: 89
Julia fills: 89
✅ All fills match exactly

Final Statistics
----------------
| Metric | Python | Julia | Match |
|--------|--------|-------|-------|
| gain | 1.00234 | 1.00234 | ✅ |
| ADG | 1.00234 | 1.00234 | ✅ |
| max_drawdown | 0.0012 | 0.0012 | ✅ |
| n_fills | 89 | 89 | ✅ |

Result: ✅ FULLY CONSISTENT
```

---

## 实现顺序

1. **Layer 1**: 单元函数测试（最基础，先确保基础计算一致）
2. **Layer 3**: Fill对比（最重要的结果验证）
3. **Layer 2**: 状态快照（用于调试不一致时定位问题）
4. **整合**: 一键运行脚本和报告生成
