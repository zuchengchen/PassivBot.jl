# RIVERUSDT 回测使用指南

## 快速开始

### 1. 下载历史数据

从 Binance 官方数据源下载 RIVERUSDT 的历史数据:

```bash
# 创建数据目录
mkdir -p data/binance/RIVERUSDT

# 下载示例 (2024年1月1日)
wget https://data.binance.vision/data/futures/um/daily/aggTrades/RIVERUSDT/aggTrades-RIVERUSDT-2024-01-01.zip -P data/binance/RIVERUSDT/

# 解压
unzip data/binance/RIVERUSDT/*.zip -d data/binance/RIVERUSDT/
```

或者使用批量下载脚本下载指定日期范围。

### 2. 运行回测

```bash
julia --project=. scripts/simple_backtest_RIVERUSDT.jl
```

## 配置文件

### 回测配置 (`configs/backtest/RIVERUSDT.json`)

```json
{
    "exchange": "binance",
    "symbol": "RIVERUSDT",
    "starting_balance": 1000.0,
    "start_date": "2024-01-01",
    "end_date": "2024-12-31"
}
```

### 交易策略配置 (`configs/live/5x.json`)

```json
{
    "config_name": "5x_general",
    "leverage": 5,
    "do_long": true,
    "do_shrt": false,
    "grid_spacing": 0.01,
    "ema_span": 1000,
    ...
}
```

## 回测参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| starting_balance | 起始资金 | 1000 USDT |
| leverage | 杠杆倍数 | 5 |
| do_long | 是否做多 | true |
| do_shrt | 是否做空 | false |
| grid_spacing | 网格间距 | 0.01 (1%) |
| ema_span | EMA周期 | 1000 |
| min_markup | 最小利润 | 0.005 (0.5%) |

## 输出结果

回测完成后会显示:

```
============================================================
回测结果
============================================================
是否完成: ✅ 是
总成交: 1253 笔
最终余额: $1234.56
最终权益: $1250.78
收益率: 25.08%
日均收益: 1.0006
年化收益: 25.71%
最近爆仓距离: 15.23%
============================================================
```

结果会保存到: `backtest_results/RIVERUSDT_result.json`

## 常见问题

### Q: 数据下载失败怎么办?

A: RIVERUSDT 可能在某些日期没有交易数据，请检查:
1. 交易对是否正确
2. 日期范围内是否有数据
3. 访问 https://data.binance.vision 确认数据可用性

### Q: 回测没有成交?

A: 检查以下配置:
1. `min_qty`: 是否小于该交易对的最小交易量
2. `min_cost`: 是否小于最小交易金额
3. `grid_spacing`: 是否过大导致订单无法成交

### Q: 如何调整策略参数?

A: 编辑 `configs/live/5x.json` 或创建新的配置文件，主要参数:
- `leverage`: 杠杆 (越高风险越大)
- `grid_spacing`: 网格间距 (越小订单越密集)
- `min_markup`: 最小利润要求
- `do_long/do_shrt`: 交易方向

## 数据来源

Binance 官方历史数据:
- Daily: https://data.binance.vision/data/futures/um/daily/aggTrades/
- Monthly: https://data.binance.vision/data/futures/um/monthly/aggTrades/
