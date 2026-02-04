#!/usr/bin/env julia

"""
Run PassivBot backtest

Usage:
    julia --project=. scripts/backtest.jl <live_config_path> [options]

Example:
    julia --project=. scripts/backtest.jl configs/live/5x.json -b configs/backtest/default.json
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
            help = "Output directory for results"
            default = "backtest_results"
    end

    return parse_args(s)
end

function main()
    args = parse_commandline()
    
    live_config_path = args["live_config"]
    backtest_config_path = args["backtest-config"]
    do_plot = args["plot"]
    output_dir = args["output"]
    
    println("=" ^ 60)
    println("PassivBot.jl - Backtest")
    println("=" ^ 60)
    println("Live config: $live_config_path")
    println("Backtest config: $backtest_config_path")
    println("Plot: $do_plot")
    println("Output: $output_dir")
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
    
    # Merge configurations
    config = merge(backtest_config, live_config)
    
    println("\nLoading tick data...")
    # TODO: Load tick data from cache or download
    # For now, this is a placeholder
    println("ERROR: Tick data loading not yet implemented")
    println("You need to:")
    println("1. Download historical data using downloader.jl")
    println("2. Load the data and pass to backtest()")
    println("\nExample:")
    println("  ticks = load_ticks(symbol, start_date, end_date)")
    println("  fills, stats, finished = backtest(config, ticks, true)")
    
    return 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
