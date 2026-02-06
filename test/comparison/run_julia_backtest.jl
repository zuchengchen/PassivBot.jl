#!/usr/bin/env julia
#=
Minimal Julia backtest for comparison with Python version.
=#

using PassivBot
using JSON3
using NPZ

const SCRIPT_DIR = @__DIR__
const TICKS_PATH = joinpath(SCRIPT_DIR, "test_ticks.npy")
const CONFIG_PATH = joinpath(SCRIPT_DIR, "test_config.json")
const OUTPUT_FILLS = joinpath(SCRIPT_DIR, "julia_fills.json")
const OUTPUT_STATS = joinpath(SCRIPT_DIR, "julia_stats.json")


function convert_fill_for_json(fill::Dict)
    result = Dict{String,Any}()
    for (k, v) in fill
        if isa(v, AbstractFloat) && isnan(v)
            result[k] = nothing
        else
            result[k] = v
        end
    end
    return result
end


function main()
    println("Loading ticks from: $TICKS_PATH")
    ticks = npzread(TICKS_PATH)
    println("Loaded $(size(ticks, 1)) ticks")
    
    println("Loading config from: $CONFIG_PATH")
    config = JSON3.read(read(CONFIG_PATH, String), Dict{String,Any})
    
    println("\nConfig:")
    for k in ["symbol", "starting_balance", "leverage", "ema_span", "do_long", "do_shrt"]
        println("  $k: $(get(config, k, "N/A"))")
    end
    
    println("\nRunning backtest...")
    fills, stats, did_finish = backtest(config, ticks, true)
    
    println("\n\nBacktest completed:")
    println("  Total fills: $(length(fills))")
    println("  Did finish: $did_finish")
    
    if !isempty(fills)
        last_fill = fills[end]
        println("  Final balance: $(get(last_fill, "balance", "N/A"))")
        println("  Final equity: $(get(last_fill, "equity", "N/A"))")
        println("  Final gain: $(get(last_fill, "gain", "N/A"))")
    end
    
    fills_json = [convert_fill_for_json(f) for f in fills]
    stats_json = [convert_fill_for_json(s) for s in stats]
    
    println("\nSaving fills to: $OUTPUT_FILLS")
    open(OUTPUT_FILLS, "w") do f
        JSON3.pretty(f, fills_json)
    end
    
    println("Saving stats to: $OUTPUT_STATS")
    open(OUTPUT_STATS, "w") do f
        JSON3.pretty(f, stats_json)
    end
    
    println("\nDone!")
end


if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
