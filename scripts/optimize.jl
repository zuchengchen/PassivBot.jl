#!/usr/bin/env julia

"""
Run PassivBot hyperparameter optimization

Usage:
    julia --project=. scripts/optimize.jl <live_config_path> [options]

Example:
    julia --project=. scripts/optimize.jl configs/live/lev10x_stable.json -s RIVERUSDT --start-date 2026-02-01 --end-date 2026-02-02
    julia --project=. scripts/optimize.jl configs/live/5x.json -n 1000
    julia --project=. scripts/optimize.jl configs/live/5x.json --start results/best_config.json
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
        "live_config"
            help = "Path to live configuration JSON file (starting point for optimization)"
            required = true
        "--backtest-config", "-b"
            help = "Path to backtest configuration JSON file"
            default = "configs/backtest/default.json"
        "--optimize-config", "-o"
            help = "Path to optimize configuration JSON file"
            default = "configs/optimize/default.json"
        "--symbol", "-s"
            help = "Override symbol from config"
            default = nothing
        "--start-date"
            help = "Override start date (YYYY-MM-DD)"
            default = nothing
        "--end-date"
            help = "Override end date (YYYY-MM-DD)"
            default = nothing
        "--n-iterations", "-n"
            help = "Number of optimization iterations"
            arg_type = Int
            default = 0
        "--start"
            help = "Path to starting candidate config (file or directory)"
            default = nothing
        "--output"
            help = "Output directory for results"
            default = "results/optimize"
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
    optimize_config_path = args["optimize-config"]
    starting_config = args["start"]
    output_dir = args["output"]
    n_iterations = args["n-iterations"]
    use_cache = !args["no-cache"]

    println("=" ^ 60)
    println("PassivBot.jl - Hyperparameter Optimization")
    println("=" ^ 60)
    println("Live config:     $live_config_path")
    println("Backtest config: $backtest_config_path")
    println("Optimize config: $optimize_config_path")
    println("Starting config: $starting_config")
    println("Output:          $output_dir")
    println("Iterations:      $(n_iterations > 0 ? n_iterations : "default from config")")
    println("Use cache:       $use_cache")
    println("=" ^ 60)

    # Load configurations
    if !isfile(live_config_path)
        error("Live configuration file not found: $live_config_path")
    end
    if !isfile(backtest_config_path)
        error("Backtest configuration file not found: $backtest_config_path")
    end
    if !isfile(optimize_config_path)
        error("Optimize configuration file not found: $optimize_config_path")
    end

    live_config = JSON3.read(read(live_config_path, String), Dict{String, Any})
    backtest_config = JSON3.read(read(backtest_config_path, String), Dict{String, Any})
    optimize_config = JSON3.read(read(optimize_config_path, String), Dict{String, Any})

    # Merge: optimize_config provides ranges/iters, backtest_config provides exchange/symbol/dates
    config = merge(backtest_config, optimize_config)

    # Apply command-line overrides
    if args["symbol"] !== nothing
        config["symbol"] = args["symbol"]
    end
    if args["start-date"] !== nothing
        config["start_date"] = args["start-date"]
    end
    if args["end-date"] !== nothing
        config["end_date"] = args["end-date"]
    end
    if n_iterations > 0
        config["iters"] = n_iterations
    end

    # Generate session name from dates
    symbol = config["symbol"]
    start_date = config["start_date"]
    end_date = config["end_date"]
    config["session_name"] = "$(start_date)_$(end_date)"

    # Setup directories (unified structure)
    config["caches_dirpath"] = joinpath("data", "caches", config["exchange"], symbol)
    config["plots_dirpath"] = joinpath("results", "backtests")
    config["optimize_dirpath"] = joinpath("results", "optimize")

    # Ensure directories exist
    mkpath(config["caches_dirpath"])
    mkpath(config["optimize_dirpath"])

    # Load market-specific settings from cache (matching backtest.jl)
    mss_path = joinpath(config["caches_dirpath"], "market_specific_settings.json")
    if isfile(mss_path)
        println("Loading market specific settings from $mss_path")
        mss = JSON3.read(read(mss_path, String), Dict{String, Any})
        merge!(config, mss)
    else
        @warn "market_specific_settings.json not found at $mss_path, using defaults"
    end

    # Add required exchange-specific parameters (only if not already set)
    defaults = Dict{String,Any}(
        "qty_step" => 0.001,
        "price_step" => 0.01,
        "min_qty" => 0.001,
        "min_cost" => 5.0,
        "c_mult" => 1.0,
        "max_leverage" => 125.0,
        "maker_fee" => 0.0002,
        "taker_fee" => 0.0004,
        "latency_simulation_ms" => 1000.0,
        "starting_balance" => 1000.0,
    )
    for (k, v) in defaults
        if !haskey(config, k)
            config[k] = v
        end
    end

    # Merge live config values into config (these are the starting point params)
    for (k, v) in live_config
        if !haskey(config, k) || k in [
            "ddown_factor", "qty_pct", "leverage", "n_close_orders",
            "grid_spacing", "pos_margin_grid_coeff", "volatility_grid_coeff",
            "volatility_qty_coeff", "min_markup", "markup_range",
            "do_long", "do_shrt", "ema_span", "ema_spread",
            "stop_loss_liq_diff", "stop_loss_pos_pct", "pbr_limit"
        ]
            config[k] = v
        end
    end

    # Ensure entry_liq_diff_thr exists
    if !haskey(config, "entry_liq_diff_thr")
        config["entry_liq_diff_thr"] = get(config, "stop_loss_liq_diff", 0.1)
    end

    # Clamp leverage range to max_leverage
    if haskey(config, "ranges") && haskey(config["ranges"], "leverage")
        config["ranges"]["leverage"][2] = min(
            config["ranges"]["leverage"][2], config["max_leverage"]
        )
        config["ranges"]["leverage"][1] = min(
            config["ranges"]["leverage"][1], config["ranges"]["leverage"][2]
        )
    end

    # Print configuration summary
    println("\nConfiguration:")
    for k in ["exchange", "symbol", "starting_balance", "start_date", "end_date",
              "latency_simulation_ms", "do_long", "do_shrt"]
        if haskey(config, k)
            println("  $k: $(config[k])")
        end
    end

    println("\nOptimization settings:")
    for k in ["iters", "n_particles", "num_cpus", "sliding_window_size",
              "n_sliding_windows", "break_early_factor", "minimum_liquidation_distance",
              "max_hrs_no_fills", "max_hrs_no_fills_same_side"]
        if haskey(config, k)
            println("  $k: $(config[k])")
        end
    end

    println("\nLive config (starting point):")
    println(JSON3.pretty(live_config))
    println()

    # Load tick data via Downloader (same as backtest.jl)
    println("Loading tick data...")
    downloader = Downloader(config)
    ticks = get_ticks(downloader, single_file=true)

    if isempty(ticks) || size(ticks, 1) == 0
        error("No tick data available for the specified date range")
    end

    println("Loaded $(size(ticks, 1)) ticks")

    # Calculate n_days
    n_days = (ticks[end, 3] - ticks[1, 3]) / (1000 * 60 * 60 * 24)
    config["n_days"] = n_days
    println("Data spans $(round(n_days, digits=1)) days")

    # Load starting candidate(s) if provided
    current_best = nothing
    if starting_config !== nothing
        try
            if isdir(starting_config)
                json_files = filter(f -> endswith(f, ".json"), readdir(starting_config, join=true))
                current_best = [JSON3.read(read(f, String), Dict{String,Any}) for f in json_files]
                println("\nLoaded $(length(current_best)) starting configs from directory")
            elseif isfile(starting_config)
                current_best = JSON3.read(read(starting_config, String), Dict{String,Any})
                println("\nLoaded starting config from file")
            else
                @warn "Starting config path not found: $starting_config"
            end
        catch e
            @warn "Could not load starting configurations" exception=e
        end
    end

    # If no starting config provided, use the live_config as starting point
    if current_best === nothing
        current_best = live_config
        println("\nUsing live config as starting candidate")
    end

    # Run optimization
    println("\n" * "=" ^ 60)
    println("Starting optimization...")
    println("=" ^ 60)

    result = backtest_tune(ticks, config; current_best=current_best)

    # Print results
    println("\n" * "=" ^ 60)
    println("Optimization Results")
    println("=" ^ 60)

    if haskey(result, "best_config") && result["best_config"] !== nothing
        best = result["best_config"]
        println("Best fitness: $(round(result["best_fitness"], digits=6))")
        println("\nBest configuration:")
        for k in sort(collect(keys(best)))
            if haskey(config, "ranges") && haskey(config["ranges"], k)
                println("  $k: $(best[k])")
            end
        end

        # Save best config as JSON
        mkpath(output_dir)
        best_config_path = joinpath(output_dir, "best_$(symbol)_$(start_date)_$(end_date).json")
        open(best_config_path, "w") do f
            # Merge best params into live_config for a complete config
            output_config = merge(live_config, Dict(
                k => v for (k, v) in best
                if haskey(config, "ranges") && haskey(config["ranges"], k)
            ))
            JSON3.pretty(f, output_config)
        end
        println("\nBest config saved to: $best_config_path")

        # Save full results
        try
            save_results(result, config)
        catch e
            @warn "Could not save detailed results" exception=e
        end
    else
        println("No valid configuration found.")
    end

    println("\n" * "=" ^ 60)

    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
