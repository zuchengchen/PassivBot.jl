#!/usr/bin/env julia
#=
Compare Python and Julia backtest results.
Outputs detailed diff report for debugging discrepancies.
=#

using JSON3
using Printf

const SCRIPT_DIR = @__DIR__
const PYTHON_FILLS = joinpath(SCRIPT_DIR, "python_fills.json")
const JULIA_FILLS = joinpath(SCRIPT_DIR, "julia_fills.json")
const PYTHON_STATS = joinpath(SCRIPT_DIR, "python_stats.json")
const JULIA_STATS = joinpath(SCRIPT_DIR, "julia_stats.json")

const FLOAT_TOLERANCE = 1e-6
const PRICE_TOLERANCE = 1e-4


function load_json(path)
    if !isfile(path)
        println("File not found: $path")
        return nothing
    end
    return JSON3.read(read(path, String))
end


function compare_values(py_val, jl_val, key)
    if py_val === nothing && jl_val === nothing
        return true, ""
    end
    if py_val === nothing || jl_val === nothing
        return false, "null mismatch: py=$py_val, jl=$jl_val"
    end
    
    if isa(py_val, Number) && isa(jl_val, Number)
        if isnan(py_val) && isnan(jl_val)
            return true, ""
        end
        
        tol = key in ["price", "long_pprice", "shrt_pprice"] ? PRICE_TOLERANCE : FLOAT_TOLERANCE
        diff = abs(py_val - jl_val)
        rel_diff = py_val != 0 ? diff / abs(py_val) : diff
        
        if diff <= tol || rel_diff <= tol
            return true, ""
        end
        return false, @sprintf("py=%.8f, jl=%.8f, diff=%.2e", py_val, jl_val, diff)
    end
    
    if py_val == jl_val
        return true, ""
    end
    return false, "py=$py_val, jl=$jl_val"
end


function compare_fill(py_fill, jl_fill, idx)
    diffs = String[]
    
    all_keys = union(keys(py_fill), keys(jl_fill))
    
    for key in all_keys
        py_val = get(py_fill, key, nothing)
        jl_val = get(jl_fill, key, nothing)
        
        match, msg = compare_values(py_val, jl_val, String(key))
        if !match
            push!(diffs, "  $key: $msg")
        end
    end
    
    return diffs
end


function print_fill_summary(fill, prefix)
    println("$prefix Fill:")
    for key in ["timestamp", "type", "side", "qty", "price", "pnl", "balance", "equity"]
        val = get(fill, key, "N/A")
        if isa(val, Number) && !isnan(val)
            println("    $key: $(@sprintf("%.6f", val))")
        else
            println("    $key: $val")
        end
    end
end


function main()
    println("="^70)
    println("Backtest Comparison: Python vs Julia")
    println("="^70)
    
    py_fills = load_json(PYTHON_FILLS)
    jl_fills = load_json(JULIA_FILLS)
    py_stats = load_json(PYTHON_STATS)
    jl_stats = load_json(JULIA_STATS)
    
    if py_fills === nothing || jl_fills === nothing
        println("\nERROR: Missing fills files. Run both backtests first.")
        return 1
    end
    
    println("\n--- Summary ---")
    println("Python fills: $(length(py_fills))")
    println("Julia fills:  $(length(jl_fills))")
    
    if py_stats !== nothing && jl_stats !== nothing
        println("Python stats: $(length(py_stats))")
        println("Julia stats:  $(length(jl_stats))")
    end
    
    if length(py_fills) != length(jl_fills)
        println("\n⚠️  FILL COUNT MISMATCH!")
        println("This is a critical difference - the backtests produced different numbers of trades.")
    end
    
    if !isempty(py_fills) && !isempty(jl_fills)
        println("\n--- Final Results ---")
        py_last = py_fills[end]
        jl_last = jl_fills[end]
        
        for key in ["balance", "equity", "gain"]
            py_val = get(py_last, key, NaN)
            jl_val = get(jl_last, key, NaN)
            match, _ = compare_values(py_val, jl_val, key)
            status = match ? "✓" : "✗"
            println(@sprintf("  %s %-10s: py=%.6f, jl=%.6f", status, key, py_val, jl_val))
        end
    end
    
    println("\n--- Fill-by-Fill Comparison ---")
    
    min_len = min(length(py_fills), length(jl_fills))
    total_diffs = 0
    first_diff_idx = 0
    
    for i in 1:min_len
        diffs = compare_fill(py_fills[i], jl_fills[i], i)
        if !isempty(diffs)
            total_diffs += 1
            if first_diff_idx == 0
                first_diff_idx = i
            end
            
            if total_diffs <= 5
                println("\nFill #$i has $(length(diffs)) differences:")
                for d in diffs
                    println(d)
                end
                println("\n  Python:")
                print_fill_summary(py_fills[i], "    ")
                println("  Julia:")
                print_fill_summary(jl_fills[i], "    ")
            end
        end
    end
    
    if total_diffs > 5
        println("\n... and $(total_diffs - 5) more fills with differences")
    end
    
    println("\n" * "="^70)
    println("COMPARISON SUMMARY")
    println("="^70)
    
    if length(py_fills) == length(jl_fills) && total_diffs == 0
        println("✓ PERFECT MATCH: All $(length(py_fills)) fills are identical!")
        return 0
    else
        println("✗ DIFFERENCES FOUND:")
        println("  - Fill count: Python=$(length(py_fills)), Julia=$(length(jl_fills))")
        println("  - Fills with differences: $total_diffs / $min_len")
        if first_diff_idx > 0
            println("  - First difference at fill #$first_diff_idx")
        end
        return 1
    end
end


if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
