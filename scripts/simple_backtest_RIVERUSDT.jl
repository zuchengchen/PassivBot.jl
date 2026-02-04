#!/usr/bin/env julia

"""
RIVERUSDT 简单回测示例

用法:
    julia --project=. scripts/simple_backtest_RIVERUSDT.jl
"""

using PassivBot
using JSON3
using Dates

println("=" ^ 60)
println("PassivBot.jl - RIVERUSDT 回测示例")
println("=" ^ 60)

# ==================== 配置 ====================
symbol = "RIVERUSDT"

# 加载配置
live_config = JSON3.read(read("configs/live/5x.json", String), Dict{String, Any})
backtest_config = JSON3.read(read("configs/backtest/RIVERUSDT.json", String), Dict{String, Any})

# 合并配置
config = merge(backtest_config, live_config)
config["maker_fee"] = 0.0002
config["taker_fee"] = 0.0004
config["latency_simulation_ms"] = 1000.0
config["max_leverage"] = 20.0

# ==================== 加载数据 ====================
println("\n步骤 1: 准备 tick 数据...")

# 方法1: 从缓存加载
cache_path = joinpath("caches", "$(symbol)_ticks.bin")

if isfile(cache_path)
    println("从缓存加载数据: $cache_path")
    # 使用 deserialize 加载缓存
    ticks = PassivBot.deserialize(cache_path)
else
    println("缓存不存在! 需要先下载历史数据。")
    println("\n请按以下步骤操作:")
    println("1. 访问 https://data.binance.vision/data/futures/um/daily/aggTrades/")
    println("2. 下载 RIVERUSDT 的 aggTrades 数据")
    println("3. 将数据放到 data/binance/RIVERUSDT/ 目录")
    println("4. 或者运行数据下载脚本")
    error("数据文件不存在")
end

println("加载了 $(size(ticks, 1)) 条 tick 数据")

# ==================== 运行回测 ====================
println("\n步骤 2: 运行回测...")
println("配置: $(config["config_name"])")
println("杠杆: $(config["leverage"])x")
println("做多: $(config["do_long"])")
println("做空: $(config["do_shrt"])")
println("=" ^ 60)
println()

fills, stats, did_finish = PassivBot.backtest(config, ticks, true)

println()

# ==================== 显示结果 ====================
println("\n" * "=" ^ 60)
println("回测结果")
println("=" ^ 60)

if isempty(fills)
    println("❌ 没有成交记录!")
    return
end

final_fill = fills[end]

println("是否完成: $(did_finish ? "✅ 是" : "❌ 否 (爆仓)")")
println("总成交: $(length(fills)) 笔")
println("最终余额: \$$(round(final_fill["balance"], digits=2))")
println("最终权益: \$$(round(final_fill["equity"], digits=2))")
println("收益率: $(round((final_fill["gain"] - 1) * 100, digits=2))%")
println("日均收益: $(round(final_fill["average_daily_gain"], digits=4))")
println("年化收益: $(round((final_fill["average_daily_gain"]^365 - 1) * 100, digits=2))%")
println("最近爆仓距离: $(round(final_fill["closest_liq"] * 100, digits=2))%")
println("=" ^ 60)

# 保存结果
results_dir = "backtest_results"
mkpath(results_dir)

result_file = joinpath(results_dir, "$(symbol)_result.json")
result_data = Dict{String, Any}(
    "symbol" => symbol,
    "starting_balance" => config["starting_balance"],
    "final_balance" => final_fill["balance"],
    "final_equity" => final_fill["equity"],
    "gain" => final_fill["gain"],
    "average_daily_gain" => final_fill["average_daily_gain"],
    "n_fills" => length(fills),
    "did_finish" => did_finish,
    "closest_liq" => final_fill["closest_liq"],
    "timestamp" => string(now())
)

open(result_file, "w") do io
    JSON3.write(io, result_data)
end

println("\n结果已保存: $result_file")
