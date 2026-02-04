#!/usr/bin/env julia

"""
RIVERUSDT 回测示例脚本

用法:
    julia --project=. scripts/backtest_RIVERUSDT.jl

功能:
    1. 下载 RIVERUSDT 历史数据 (如果缓存不存在)
    2. 运行回测
    3. 显示结果
"""

using PassivBot
using JSON3
using Dates
using HTTP
using CodecZip: ZipReader
using CodecZlib: GzipDecompressorStream
using ProgressBars

# ==================== 数据下载函数 ====================

"""
    download_aggtrades(symbol::String, start_date::Date, end_date::Date) -> String

下载 Binance 的聚合交易数据
返回保存的文件路径
"""
function download_aggtrades(symbol::String, start_date::Date, end_date::Date)
    # 创建数据目录
    data_dir = joinpath("data", "binance", symbol)
    mkpath(data_dir)

    # Binance data URL
    base_url = "https://data.binance.vision/data/futures/um/daily/aggTrades"

    downloaded_files = String[]

    current_date = start_date
    while current_date <= end_date
        year_str = Dates.year(current_date)
        month_str = lpad(Dates.month(current_date), 2, '0')
        day_str = lpad(Dates.day(current_date), 2, '0')

        # 文件名格式: symbol/aggTrades/daily/symbol/aggTrades-symbol-year-month-day.zip
        filename = "aggTrades-$(symbol)-$(year_str)-$(month_str)-$(day_str).zip"
        url = "$(base_url)/$(symbol)/$(filename)"

        local_path = joinpath(data_dir, filename)

        # 如果文件已存在且大小>0，跳过
        if isfile(local_path) && filesize(local_path) > 0
            println("[跳过] 已存在: $filename")
            current_date += Day(1)
            continue
        end

        println("[下载] $filename")

        try
            response = HTTP.get(url; retry=true, max_retries=3)
            if response.status == 200
                write(local_path, response.body)
                push!(downloaded_files, local_path)
                println("[完成] $filename ($(length(response.body)) bytes)")
            else
                println("[失败] HTTP $(response.status): $filename")
            end
        catch e
            println("[错误] $filename: $e")
        end

        current_date += Day(1)
        # 避免请求过快
        sleep(0.1)
    end

    return data_dir
end

"""
    load_tick_data_from_csv(data_dir::String, symbol::String) -> Matrix{Float64}

从下载的 CSV 文件加载 tick 数据
返回矩阵: [price, buyer_maker, timestamp]
"""
function load_tick_data_from_csv(data_dir::String, symbol::String)
    println("\n[加载] 从 $data_dir 加载 tick 数据...")

    # 查找所有 CSV 文件
    csv_files = sort(filter(x -> endswith(x, ".csv"), readdir(data_dir; join=true)))

    if isempty(csv_files)
        # 尝试从 ZIP 文件中提取 CSV
        zip_files = sort(filter(x -> endswith(x, ".zip"), readdir(data_dir; join=true)))
        for zip_file in zip_files
            println("[解压] $zip_file")
            try
                # 解压 ZIP 文件
                # 使用系统 unzip 命令更可靠
                run(`unzip -o -j $zip_file -d $data_dir`)
            catch e
                println("[警告] 解压失败: $e")
            end
        end

        # 重新查找 CSV 文件
        csv_files = sort(filter(x -> endswith(x, ".csv"), readdir(data_dir; join=true)))
    end

    if isempty(csv_files)
        error("未找到数据文件! 请先下载数据。")
    end

    println("[找到] $(length(csv_files)) 个数据文件")

    # 合并所有数据
    all_ticks = Vector{Float64}[]
    total_lines = 0

    for (i, csv_file) in enumerate(csv_files)
        print("\r[读取] $i/$(length(csv_files)) ")
        try
            for line in eachline(csv_file)
                parts = split(line, ',')
                if length(parts) >= 4
                    price = parse(Float64, parts[1])
                    qty = parse(Float64, parts[2])
                    timestamp = parse(Float64, first(parts[0]))  # 第一列是时间戳
                    is_buyer_maker = parse(Float64, parts[4]) == 1.0 ? 1.0 : 0.0

                    push!(all_ticks, [price, is_buyer_maker, timestamp])
                    total_lines += 1
                end
            end
        catch e
            # 跳过损坏的文件
        end
    end
    println()

    if isempty(all_ticks)
        error("数据为空!")
    end

    # 按时间戳排序
    sort!(all_ticks, by=x->x[3])

    # 转换为 Matrix
    tick_matrix = hcat(all_ticks...)

    println("[完成] 加载了 $(size(tick_matrix, 2)) 条 tick 数据")
    println("[范围] $(Dates.unix2millisecond(tick_matrix[3, 1] ÷ 1000)) 到 $(Dates.unix2millisecond(tick_matrix[3, end] ÷ 1000))")

    return tick_matrix
end

# ==================== 缓存管理 ====================

"""
    get_cache_path(symbol::String, start_date::String, end_date::String) -> String

获取缓存文件路径
"""
function get_cache_path(symbol::String, start_date::String, end_date::String)
    cache_dir = "caches"
    mkpath(cache_dir)
    return joinpath(cache_dir, "$(symbol)_$(start_date)_$(end_date)_ticks.bin")
end

"""
    save_tick_cache(ticks::Matrix{Float64}, cache_path::String)

保存 tick 数据到缓存
"""
function save_tick_cache(ticks::Matrix{Float64}, cache_path::String)
    open(cache_path, "w") do io
        # 简单的序列化: 写入维度和数据
        write(io, size(ticks, 1))
        write(io, size(ticks, 2))
        write(io, ticks)
    end
    println("[缓存] 已保存到: $cache_path")
end

"""
    load_tick_cache(cache_path::String) -> Union{Matrix{Float64}, Nothing}

从缓存加载 tick 数据
"""
function load_tick_cache(cache_path::String)
    if !isfile(cache_path)
        return nothing
    end
    println("[缓存] 从缓存加载: $cache_path")
    open(cache_path, "r") do io
        rows = read(io, Int)
        cols = read(io, Int)
        data = read(io, Float64, (rows, cols))
        println("[缓存] 加载了 $(rows) 条数据")
        return data
    end
end

# ==================== 主程序 ====================

function main()
    println("=" ^ 60)
    println("PassivBot.jl - RIVERUSDT 回测")
    println("=" ^ 60)

    # 配置参数
    symbol = "RIVERUSDT"
    start_date = "2024-01-01"
    end_date = "2024-12-31"

    # 加载配置
    live_config_path = "configs/live/5x.json"
    backtest_config_path = "configs/backtest/RIVERUSDT.json"

    if !isfile(live_config_path)
        error("配置文件不存在: $live_config_path")
    end

    if !isfile(backtest_config_path)
        error("回测配置不存在: $backtest_config_path")
    end

    live_config = JSON3.read(read(live_config_path, String), Dict{String, Any})
    backtest_config = JSON3.read(read(backtest_config_path, String), Dict{String, Any})

    # 合并配置
    config = merge(backtest_config, live_config)
    config["maker_fee"] = 0.0002
    config["taker_fee"] = 0.0004
    config["latency_simulation_ms"] = 1000.0
    config["max_leverage"] = 20.0

    # 检查缓存
    cache_path = get_cache_path(symbol, start_date, end_date)
    ticks = load_tick_cache(cache_path)

    # 如果缓存不存在，下载数据
    if ticks === nothing
        println("\n" * "=" ^ 60)
        println("步骤 1: 下载历史数据")
        println("=" ^ 60)

        start_dt = Date(start_date)
        end_dt = Date(end_date)

        data_dir = download_aggtrades(symbol, start_dt, end_dt)

        println("\n" * "=" ^ 60)
        println("步骤 2: 加载 tick 数据")
        println("=" ^ 60)

        ticks = load_tick_data_from_csv(data_dir, symbol)

        # 保存缓存
        save_tick_cache(ticks, cache_path)
    end

    println("\n" * "=" ^ 60)
    println("步骤 3: 运行回测")
    println("=" ^ 60)
    println("配置: $(config["config_name"])")
    println("杠杆: $(config["leverage"])x")
    println("做多: $(config["do_long"])")
    println("做空: $(config["do_shrt"])")
    println("起始余额: \$$(config["starting_balance"])")
    println("数据范围: $(start_date) 到 $(end_date)")
    println("=" ^ 60)
    println()

    # 运行回测
    fills, stats, did_finish = PassivBot.backtest(config, ticks, true)

    println()

    # 显示结果
    println("\n" * "=" ^ 60)
    println("回测结果")
    println("=" ^ 60)

    if isempty(fills)
        println("❌ 没有成交记录!")
        return
    end

    final_fill = fills[end]

    println("是否完成: $(did_finish ? "✅ 是" : "❌ 否 (爆仓/归零)")")
    println("总成交次数: $(length(fills))")
    println("最终余额: \$$(round(final_fill["balance"], digits=2))")
    println("最终权益: \$$(round(final_fill["equity"], digits=2))")
    println("总收益: \$$(round(final_fill["equity"] - config["starting_balance"], digits=2))")
    println("收益率: $(round((final_fill["gain"] - 1) * 100, digits=2))%")
    println("日均收益: $(round(final_fill["average_daily_gain"], digits=4))")
    println("年化收益率: $(round((final_fill["average_daily_gain"]^365 - 1) * 100, digits=2))%")
    println("最近爆仓距离: $(round(final_fill["closest_liq"] * 100, digits=2))%")
    println("交易天数: $(round(final_fill["n_days"], digits=1))")

    # 计算统计
    if length(fills) > 1
        profits = [f["pnl"] for f in fills if f["pnl"] != 0.0]
        if !isempty(profits)
            winning = count(p -> p > 0, profits)
            losing = count(p -> p < 0, profits)
            win_rate = winning / length(profits) * 100

            println("\n交易统计:")
            println("盈利交易: $winning")
            println("亏损交易: $losing")
            println("胜率: $(round(win_rate, digits=1))%")
            println("总手续费: \$$(round(sum(f["fee_paid"] for f in fills), digits=2))")
        end
    end

    println("=" ^ 60)

    # 保存结果
    results_dir = "backtest_results"
    mkpath(results_dir)

    result_file = joinpath(results_dir, "RIVERUSDT_backtest_$(Dates.format(now(), "yyyy-mm-dd_HH-MM")).json")
    result_data = Dict{String, Any}(
        "symbol" => symbol,
        "start_date" => start_date,
        "end_date" => end_date,
        "config_name" => config["config_name"],
        "leverage" => config["leverage"],
        "starting_balance" => config["starting_balance"],
        "final_balance" => final_fill["balance"],
        "final_equity" => final_fill["equity"],
        "total_return" => final_fill["gain"] - 1,
        "average_daily_gain" => final_fill["average_daily_gain"],
        "annualized_return" => final_fill["average_daily_gain"]^365 - 1,
        "n_fills" => length(fills),
        "did_finish" => did_finish,
        "closest_liq" => final_fill["closest_liq"],
        "n_days" => final_fill["n_days"],
        "timestamp" => string(now())
    )

    open(result_file, "w") do io
        JSON3.write(io, result_data)
    end
    println("\n结果已保存到: $result_file")

    return fills, stats, did_finish
end

# 运行主程序
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
