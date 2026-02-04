#!/usr/bin/env julia

"""
Run PassivBot backtest

Usage:
    julia --project=. scripts/backtest.jl <live_config_path> [options]

Example:
    julia --project=. scripts/backtest.jl configs/live/5x.json
    julia --project=. scripts/backtest.jl configs/live/5x.json -p
    julia --project=. scripts/backtest.jl configs/live/5x.json -b configs/backtest/default.json -p
"""

using PassivBot
using ArgParse
using JSON3
using Dates

function parse_commandline()
    s = ArgParseSettings(
        description = "Run PassivBot backtest",
        version = "0.1.0",
        add_version = true
    )

    @add_arg_table! s begin
        "live_config"
            help = "Path to live configuration JSON file"
            required = true
        "--backtest-config", "-b"
            help = "Path to backtest configuration JSON file"
            default = "configs/backtest/default.json"
        "--plot", "-p"
            help = "Generate plots"
            action = :store_true
        "--output", "-o"
            help = "Output directory for plots"
            default = "plots"
        "--symbol", "-s"
            help = "Override symbol from config"
            default = nothing
        "--start-date"
            help = "Override start date (YYYY-MM-DD)"
            default = nothing
        "--end-date"
            help = "Override end date (YYYY-MM-DD)"
            default = nothing
        "--no-cache"
            help = "Force re-download of tick data"
            action = :store_true
    end

    return parse_args(s)
end

function main()
    args = parse_commandline()
    
    live_config_path = args["live_config"]
    backtest_config_path = args["backtest-config"]
    do_plot = args["plot"] ? "True" : "False"
    output_dir = args["output"]
    use_cache = !args["no-cache"]
    
    println("=" ^ 60)
    println("PassivBot.jl - Backtest")
    println("=" ^ 60)
    println("Live config: $live_config_path")
    println("Backtest config: $backtest_config_path")
    println("Plot: $do_plot")
    println("Output: $output_dir")
    println("Use cache: $use_cache")
    println("=" ^ 60)
    
    # Load configurations
    if !isfile(live_config_path)
        error("Live configuration file not found: $live_config_path")
    end
    
    if !isfile(backtest_config_path)
        error("Backtest configuration file not found: $backtest_config_path")
    end
    
    live_config = JSON3.read(read(live_config_path, String), Dict{String, Any})
    backtest_config = JSON3.read(read(backtest_config_path, String), Dict{String, Any})
    
    # Apply command-line overrides
    if args["symbol"] !== nothing
        backtest_config["symbol"] = args["symbol"]
    end
    if args["start-date"] !== nothing
        backtest_config["start_date"] = args["start-date"]
    end
    if args["end-date"] !== nothing
        backtest_config["end_date"] = args["end-date"]
    end
    
    # Set output directory
    backtest_config["plots_dirpath"] = output_dir
    backtest_config["caches_dirpath"] = get(backtest_config, "caches_dirpath", "data/caches")
    
    # Generate session name from symbol and dates
    symbol = backtest_config["symbol"]
    start_date = backtest_config["start_date"]
    end_date = backtest_config["end_date"]
    backtest_config["session_name"] = "$(symbol)_$(start_date)_$(end_date)"
    
    # Add required exchange-specific parameters
    if !haskey(backtest_config, "qty_step")
        backtest_config["qty_step"] = 0.001
    end
    if !haskey(backtest_config, "price_step")
        backtest_config["price_step"] = 0.01
    end
    if !haskey(backtest_config, "min_qty")
        backtest_config["min_qty"] = 0.001
    end
    if !haskey(backtest_config, "min_cost")
        backtest_config["min_cost"] = 5.0
    end
    if !haskey(backtest_config, "c_mult")
        backtest_config["c_mult"] = 1.0
    end
    if !haskey(backtest_config, "max_leverage")
        backtest_config["max_leverage"] = 125.0
    end
    if !haskey(backtest_config, "maker_fee")
        backtest_config["maker_fee"] = 0.0002
    end
    if !haskey(backtest_config, "taker_fee")
        backtest_config["taker_fee"] = 0.0004
    end
    if !haskey(backtest_config, "latency_simulation_ms")
        backtest_config["latency_simulation_ms"] = 1000.0
    end
    
    # Print configuration summary
    println("\nConfiguration:")
    for k in ["exchange", "symbol", "starting_balance", "start_date", "end_date", "latency_simulation_ms"]
        if haskey(backtest_config, k)
            println("  $k: $(backtest_config[k])")
        end
    end
    println()
    
    # Print live config
    println("Live config:")
    println(JSON3.pretty(live_config))
    println()
    
    # Create Downloader and get tick data
    println("Loading tick data...")
    downloader = Downloader(backtest_config)
    ticks = get_ticks(downloader, use_cache)
    
    if isempty(ticks) || size(ticks, 1) == 0
        error("No tick data available for the specified date range")
    end
    
    println("Loaded $(size(ticks, 1)) ticks")
    
    # Calculate n_days
    n_days = (ticks[end, 3] - ticks[1, 3]) / (1000 * 60 * 60 * 24)
    backtest_config["n_days"] = n_days
    
    # Run backtest with plotting
    println("\nRunning backtest...")
    result = plot_wrap(backtest_config, ticks, live_config, do_plot)
    
    if result === nothing
        println("\nBacktest completed with no fills")
        return 0
    end
    
    fills, stats, did_finish, analysis = result
    
    # Print summary
    println("\n" * "=" ^ 60)
    println("Backtest Results")
    println("=" ^ 60)
    println("Total fills: $(length(fills))")
    println("Did finish: $did_finish")
    
    if !isempty(analysis)
        println("\nPerformance Metrics:")
        println("  Gain: $(round(get(analysis, "gain", 0.0), digits=4))")
        println("  Average Daily Gain: $(round((get(analysis, "average_daily_gain", 1.0) - 1) * 100, digits=4))%")
        println("  Final Equity: $(round(get(analysis, "final_equity", 0.0), digits=2))")
        println("  Max Drawdown: $(round(get(analysis, "max_drawdown", 0.0) * 100, digits=2))%")
        println("  Closest Liquidation: $(round(get(analysis, "closest_liq", 1.0) * 100, digits=2))%")
        println("  N Days: $(round(get(analysis, "n_days", 0.0), digits=1))")
        println("  Max Hours No Fills: $(round(get(analysis, "max_hrs_no_fills", 0.0), digits=1))")
    end
    
    println("\n" * "=" ^ 60)
    
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
