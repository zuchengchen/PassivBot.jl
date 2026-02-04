#!/usr/bin/env julia

"""
Run PassivBot hyperparameter optimization

Usage:
    julia --project=. scripts/optimize.jl [options]

Example:
    julia --project=. scripts/optimize.jl -b configs/backtest/default.json -o configs/optimize/default.json
"""

using PassivBot
using ArgParse
using JSON3
using Dates

function parse_commandline()
    s = ArgParseSettings(
        description = "Run PassivBot hyperparameter optimization",
        version = "0.1.0",
        add_version = true
    )

    @add_arg_table! s begin
        "--backtest-config", "-b"
            help = "Path to backtest configuration JSON file"
            default = "configs/backtest/default.json"
        "--optimize-config", "-o"
            help = "Path to optimize configuration JSON file"
            default = "configs/optimize/default.json"
        "--start"
            help = "Path to starting candidate config (file or directory)"
            default = nothing
        "--output"
            help = "Output directory for results"
            default = "optimize_results"
        "--n-iterations", "-n"
            help = "Number of optimization iterations"
            arg_type = Int
            default = 100
    end

    return parse_args(s)
end

function main()
    args = parse_commandline()
    
    backtest_config_path = args["backtest-config"]
    optimize_config_path = args["optimize-config"]
    starting_config = args["start"]
    output_dir = args["output"]
    n_iterations = args["n-iterations"]
    
    println("=" ^ 60)
    println("PassivBot.jl - Hyperparameter Optimization")
    println("=" ^ 60)
    println("Backtest config: $backtest_config_path")
    println("Optimize config: $optimize_config_path")
    println("Starting config: $starting_config")
    println("Output: $output_dir")
    println("Iterations: $n_iterations")
    println("=" ^ 60)
    
    # Load configurations
    if !isfile(backtest_config_path)
        error("Backtest configuration file not found: $backtest_config_path")
    end
    
    if !isfile(optimize_config_path)
        error("Optimize configuration file not found: $optimize_config_path")
    end
    
    backtest_config = JSON3.read(read(backtest_config_path, String), Dict{String, Any})
    optimize_config = JSON3.read(read(optimize_config_path, String), Dict{String, Any})
    
    # Override n_iterations if specified
    if n_iterations > 0
        optimize_config["n_iterations"] = n_iterations
    end
    
    println("\nLoading tick data...")
    # TODO: Load tick data from cache or download
    println("ERROR: Tick data loading not yet implemented")
    println("You need to:")
    println("1. Download historical data using downloader.jl")
    println("2. Load the data and pass to backtest_tune()")
    println("\nExample:")
    println("  ticks = load_ticks(symbol, start_date, end_date)")
    println("  best_config = backtest_tune(backtest_config, optimize_config, ticks)")
    
    return 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
