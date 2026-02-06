#!/usr/bin/env julia
"""
Compare Python and Julia backtest results.
Generates detailed diff report.
"""

using JSON3
using Printf

const TOLERANCE = 1e-10

function load_json(path::String)
    isfile(path) || return nothing
    JSON3.read(read(path, String))
end

function compare_values(py_val, jl_val, path::String)
    diffs = String[]
    
    if py_val === nothing && jl_val === nothing
        return diffs
    end
    
    if py_val === nothing || jl_val === nothing
        push!(diffs, "$path: Python=$(py_val) Julia=$(jl_val)")
        return diffs
    end
    
    if isa(py_val, Number) && isa(jl_val, Number)
        diff = abs(Float64(py_val) - Float64(jl_val))
        if diff > TOLERANCE
            push!(diffs, @sprintf("%s: Python=%.15g Julia=%.15g diff=%.2e", path, py_val, jl_val, diff))
        end
    elseif isa(py_val, AbstractString) && isa(jl_val, AbstractString)
        if py_val != jl_val
            push!(diffs, "$path: Python='$py_val' Julia='$jl_val'")
        end
    elseif isa(py_val, AbstractDict) && isa(jl_val, AbstractDict)
        all_keys = union(keys(py_val), keys(jl_val))
        for k in all_keys
            py_v = get(py_val, k, nothing)
            jl_v = get(jl_val, k, nothing)
            append!(diffs, compare_values(py_v, jl_v, "$path.$k"))
        end
    elseif isa(py_val, AbstractVector) && isa(jl_val, AbstractVector)
        if length(py_val) != length(jl_val)
            push!(diffs, "$path: length mismatch Python=$(length(py_val)) Julia=$(length(jl_val))")
        end
        for i in 1:min(length(py_val), length(jl_val))
            append!(diffs, compare_values(py_val[i], jl_val[i], "$path[$i]"))
        end
    else
        push!(diffs, "$path: type mismatch Python=$(typeof(py_val)) Julia=$(typeof(jl_val))")
    end
    
    return diffs
end

function compare_unit_tests(py_results, jl_results)
    report = String[]
    push!(report, "\n## Layer 1: Unit Function Tests\n")
    
    all_funcs = union(keys(py_results), keys(jl_results))
    total_passed = 0
    total_failed = 0
    
    for func_name in sort(collect(all_funcs))
        py_tests = get(py_results, func_name, [])
        jl_tests = get(jl_results, func_name, [])
        
        if length(py_tests) != length(jl_tests)
            push!(report, "❌ $func_name: test count mismatch (Python=$(length(py_tests)), Julia=$(length(jl_tests)))")
            total_failed += max(length(py_tests), length(jl_tests))
            continue
        end
        
        passed = 0
        failed = 0
        first_diff = nothing
        
        for i in 1:length(py_tests)
            py_out = py_tests[i]["output"]
            jl_out = jl_tests[i]["output"]
            diffs = compare_values(py_out, jl_out, "output")
            
            if isempty(diffs)
                passed += 1
            else
                failed += 1
                if first_diff === nothing
                    first_diff = (i, diffs)
                end
            end
        end
        
        total_passed += passed
        total_failed += failed
        
        if failed == 0
            push!(report, "✅ $func_name: $passed/$passed passed")
        else
            push!(report, "❌ $func_name: $passed/$(passed+failed) passed, $failed failed")
            if first_diff !== nothing
                push!(report, "   First failure at test #$(first_diff[1]):")
                for d in first_diff[2][1:min(3, length(first_diff[2]))]
                    push!(report, "     $d")
                end
            end
        end
    end
    
    push!(report, "\n**Summary**: $total_passed passed, $total_failed failed")
    return report, total_failed == 0
end

function compare_fills(py_fills, jl_fills)
    report = String[]
    push!(report, "\n## Layer 3: Fill Comparison\n")
    
    push!(report, "Python fills: $(length(py_fills))")
    push!(report, "Julia fills: $(length(jl_fills))")
    
    if length(py_fills) != length(jl_fills)
        push!(report, "❌ Fill count mismatch!")
        return report, false
    end
    
    if isempty(py_fills)
        push!(report, "⚠️ No fills to compare")
        return report, true
    end
    
    fields_to_compare = ["qty", "price", "pnl", "fee_paid", "type", "side", "pside",
                         "long_psize", "long_pprice", "shrt_psize", "shrt_pprice",
                         "balance", "equity", "liq_price", "liq_diff", "closest_liq"]
    
    total_diffs = 0
    first_diff_fill = nothing
    
    for i in 1:length(py_fills)
        py_fill = py_fills[i]
        jl_fill = jl_fills[i]
        
        fill_diffs = String[]
        for field in fields_to_compare
            py_val = get(py_fill, field, nothing)
            jl_val = get(jl_fill, field, nothing)
            
            if py_val === nothing && jl_val === nothing
                continue
            end
            
            diffs = compare_values(py_val, jl_val, field)
            append!(fill_diffs, diffs)
        end
        
        if !isempty(fill_diffs)
            total_diffs += 1
            if first_diff_fill === nothing
                first_diff_fill = (i, py_fill, jl_fill, fill_diffs)
            end
        end
    end
    
    if total_diffs == 0
        push!(report, "✅ All $(length(py_fills)) fills match exactly")
    else
        push!(report, "❌ $total_diffs fills have differences")
        if first_diff_fill !== nothing
            i, py_fill, jl_fill, diffs = first_diff_fill
            push!(report, "\n### First Difference: Fill #$i")
            push!(report, "| Field | Python | Julia | Diff |")
            push!(report, "|-------|--------|-------|------|")
            for d in diffs[1:min(10, length(diffs))]
                push!(report, "| $d |")
            end
            push!(report, "\n**Context**:")
            push!(report, "- tick_index: $(get(py_fill, "tick_index", get(py_fill, "trade_id", "?")))")
            push!(report, "- type: $(get(py_fill, "type", "?"))")
        end
    end
    
    return report, total_diffs == 0
end

function compare_states(py_states, jl_states)
    report = String[]
    push!(report, "\n## Layer 2: State Snapshot Comparison\n")
    
    push!(report, "Python snapshots: $(length(py_states))")
    push!(report, "Julia snapshots: $(length(jl_states))")
    
    if isempty(py_states) || isempty(jl_states)
        push!(report, "⚠️ No state snapshots to compare")
        return report, true
    end
    
    py_periodic = filter(s -> get(s, "trigger", "") == "periodic", py_states)
    jl_periodic = filter(s -> get(s, "trigger", "") == "periodic", jl_states)
    
    push!(report, "Periodic snapshots: Python=$(length(py_periodic)), Julia=$(length(jl_periodic))")
    
    max_diff = 0.0
    total_diffs = 0
    
    min_len = min(length(py_periodic), length(jl_periodic))
    for i in 1:min_len
        py_s = py_periodic[i]
        jl_s = jl_periodic[i]
        
        for field in ["ema", "volatility", "position", "balance"]
            py_val = get(py_s, field, nothing)
            jl_val = get(jl_s, field, nothing)
            if py_val !== nothing && jl_val !== nothing
                diffs = compare_values(py_val, jl_val, field)
                if !isempty(diffs)
                    total_diffs += 1
                    for d in diffs
                        m = match(r"diff=([0-9.e+-]+)", d)
                        if m !== nothing
                            diff_val = parse(Float64, m.captures[1])
                            max_diff = max(max_diff, diff_val)
                        end
                    end
                end
            end
        end
    end
    
    if total_diffs == 0
        push!(report, "✅ All state snapshots match (max diff: 0)")
    else
        push!(report, @sprintf("⚠️ %d state differences found (max diff: %.2e)", total_diffs, max_diff))
    end
    
    return report, total_diffs == 0 || max_diff < 1e-6
end

function generate_final_stats(py_fills, jl_fills)
    report = String[]
    push!(report, "\n## Final Statistics\n")
    
    if isempty(py_fills) || isempty(jl_fills)
        push!(report, "No fills to analyze")
        return report
    end
    
    py_last = py_fills[end]
    jl_last = jl_fills[end]
    
    metrics = [
        ("gain", "gain"),
        ("ADG", "average_daily_gain"),
        ("max_drawdown", "closest_liq"),
        ("n_fills", nothing),
        ("final_balance", "balance"),
        ("final_equity", "equity")
    ]
    
    push!(report, "| Metric | Python | Julia | Match |")
    push!(report, "|--------|--------|-------|-------|")
    
    for (name, key) in metrics
        if key === nothing
            py_val = length(py_fills)
            jl_val = length(jl_fills)
        else
            py_val = get(py_last, key, 0.0)
            jl_val = get(jl_last, key, 0.0)
        end
        
        if isa(py_val, Number) && isa(jl_val, Number)
            diff = abs(Float64(py_val) - Float64(jl_val))
            match_str = diff < TOLERANCE ? "✅" : "❌"
            push!(report, @sprintf("| %s | %.6f | %.6f | %s |", name, py_val, jl_val, match_str))
        else
            match_str = py_val == jl_val ? "✅" : "❌"
            push!(report, "| $name | $py_val | $jl_val | $match_str |")
        end
    end
    
    return report
end

function main()
    base_dir = @__DIR__
    py_dir = joinpath(base_dir, "output", "python")
    jl_dir = joinpath(base_dir, "output", "julia")
    
    report = String[]
    push!(report, "# PassivBot Comparison Test Report")
    push!(report, "")
    push!(report, "Generated: $(Dates.now())")
    push!(report, "Tolerance: $TOLERANCE")
    push!(report, "")
    
    all_passed = true
    
    py_unit = load_json(joinpath(py_dir, "unit_tests.json"))
    jl_unit = load_json(joinpath(jl_dir, "unit_tests.json"))
    
    if py_unit !== nothing && jl_unit !== nothing
        unit_report, unit_passed = compare_unit_tests(py_unit, jl_unit)
        append!(report, unit_report)
        all_passed &= unit_passed
    else
        push!(report, "\n## Layer 1: Unit Tests\n")
        push!(report, "⚠️ Unit test results not found")
    end
    
    py_fills = load_json(joinpath(py_dir, "fills.json"))
    jl_fills = load_json(joinpath(jl_dir, "fills.json"))
    
    if py_fills !== nothing && jl_fills !== nothing
        fills_report, fills_passed = compare_fills(py_fills, jl_fills)
        append!(report, fills_report)
        all_passed &= fills_passed
        
        append!(report, generate_final_stats(py_fills, jl_fills))
    else
        push!(report, "\n## Layer 3: Fills\n")
        push!(report, "⚠️ Fill results not found")
        push!(report, "Python fills: $(py_fills !== nothing ? "found" : "not found")")
        push!(report, "Julia fills: $(jl_fills !== nothing ? "found" : "not found")")
    end
    
    py_states = load_json(joinpath(py_dir, "states.json"))
    jl_states = load_json(joinpath(jl_dir, "states.json"))
    
    if py_states !== nothing && jl_states !== nothing
        states_report, states_passed = compare_states(py_states, jl_states)
        append!(report, states_report)
        all_passed &= states_passed
    else
        push!(report, "\n## Layer 2: States\n")
        push!(report, "⚠️ State snapshots not found")
    end
    
    push!(report, "\n---")
    push!(report, "")
    if all_passed
        push!(report, "## Result: ✅ FULLY CONSISTENT")
    else
        push!(report, "## Result: ❌ DIFFERENCES FOUND")
    end
    
    report_path = joinpath(base_dir, "diff_report.md")
    open(report_path, "w") do f
        write(f, join(report, "\n"))
    end
    
    println(join(report, "\n"))
    println("\nReport saved to: $report_path")
    
    return all_passed ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    using Dates
    exit(main())
end
