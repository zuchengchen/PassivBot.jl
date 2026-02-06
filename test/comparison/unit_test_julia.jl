#!/usr/bin/env julia
"""
Unit test for Julia Jitted functions - outputs results to JSON for comparison with Python.
"""

using JSON3
using Random

include(joinpath(@__DIR__, "..", "..", "src", "PassivBot.jl"))
using .PassivBot: round_, round_up, round_dn, calc_diff, calc_ema,
    calc_new_psize_pprice, calc_long_pnl, calc_shrt_pnl,
    calc_cost, calc_margin_cost, calc_available_margin,
    calc_liq_price_binance, calc_bid_ask_thresholds,
    iter_entries, iter_long_closes, iter_shrt_closes,
    calc_initial_entry_qty, calc_reentry_qty, calc_min_entry_qty

Random.seed!(42)

function generate_test_cases()
    cases = Dict{String,Vector{Dict{String,Any}}}()
    
    cases["round_"] = [
        Dict("n" => rand() * 100000, "step" => 10.0^rand(-8:1))
        for _ in 1:100
    ]
    
    cases["round_up"] = [
        Dict("n" => rand() * 100000, "step" => 10.0^rand(-8:1))
        for _ in 1:100
    ]
    
    cases["round_dn"] = [
        Dict("n" => rand() * 100000, "step" => 10.0^rand(-8:1))
        for _ in 1:100
    ]
    
    cases["calc_diff"] = [
        Dict("x" => rand() * 1000, "y" => rand() * 1000)
        for _ in 1:100
    ]
    
    cases["calc_ema"] = [
        let alpha = rand() * 0.1
            Dict(
                "alpha" => alpha,
                "alpha_" => 1.0 - alpha,
                "prev_ema" => 10 + rand() * 90,
                "new_val" => 10 + rand() * 90
            )
        end
        for _ in 1:100
    ]
    
    cases["calc_new_psize_pprice"] = [
        Dict(
            "psize" => rand() * 1000,
            "pprice" => 10 + rand() * 90,
            "qty" => 1 + rand() * 99,
            "price" => 10 + rand() * 90
        )
        for _ in 1:50
    ]
    
    cases["calc_long_pnl"] = [
        Dict(
            "entry_price" => 10 + rand() * 90,
            "close_price" => 10 + rand() * 90,
            "qty" => 1 + rand() * 99
        )
        for _ in 1:50
    ]
    
    cases["calc_shrt_pnl"] = [
        Dict(
            "entry_price" => 10 + rand() * 90,
            "close_price" => 10 + rand() * 90,
            "qty" => 1 + rand() * 99
        )
        for _ in 1:50
    ]
    
    cases["calc_cost"] = [
        Dict("qty" => 1 + rand() * 999, "price" => 10 + rand() * 90)
        for _ in 1:50
    ]
    
    cases["calc_margin_cost"] = [
        Dict(
            "qty" => 1 + rand() * 999,
            "price" => 10 + rand() * 90,
            "leverage" => 1 + rand() * 19
        )
        for _ in 1:50
    ]
    
    cases["calc_available_margin"] = [
        Dict(
            "balance" => 1000 + rand() * 9000,
            "long_psize" => rand() * 100,
            "long_pprice" => 10 + rand() * 90,
            "shrt_psize" => rand() * 100,
            "shrt_pprice" => 10 + rand() * 90,
            "leverage" => 1 + rand() * 19
        )
        for _ in 1:50
    ]
    
    cases["calc_liq_price"] = [
        Dict(
            "balance" => 1000 + rand() * 9000,
            "psize" => 10 + rand() * 490,
            "pprice" => 10 + rand() * 90,
            "leverage" => 2 + rand() * 18,
            "long" => rand(Bool)
        )
        for _ in 1:50
    ]
    
    cases["calc_bid_ask_thresholds"] = [
        Dict(
            "ema" => 10 + rand() * 90,
            "ema_spread" => 0.001 + rand() * 0.009,
            "volatility" => 0.001 + rand() * 0.049,
            "volatility_grid_coeff" => rand()
        )
        for _ in 1:50
    ]
    
    cases["iter_entries"] = [
        let psize = rand() * 100
            Dict(
                "balance" => 1000 + rand() * 9000,
                "psize" => psize,
                "pprice" => psize > 0 ? 10 + rand() * 90 : 0.0,
                "entry_price" => 10 + rand() * 90,
                "ema" => 10 + rand() * 90,
                "volatility" => 0.001 + rand() * 0.049,
                "leverage" => 10.0,
                "qty_pct" => 0.1,
                "ddown_factor" => 0.5,
                "grid_spacing" => 0.01,
                "pos_margin_grid_coeff" => 0.5,
                "volatility_grid_coeff" => 0.5,
                "volatility_qty_coeff" => 0.5,
                "min_qty" => 1.0,
                "qty_step" => 1.0,
                "price_step" => 0.0001,
                "min_cost" => 5.0,
                "max_leverage" => 20.0,
                "entry_liq_diff_thr" => 0.1,
                "long" => true
            )
        end
        for _ in 1:30
    ]
    
    cases["iter_closes"] = [
        let pprice = 10 + rand() * 90
            Dict(
                "balance" => 1000 + rand() * 9000,
                "psize" => 10 + rand() * 190,
                "pprice" => pprice,
                "close_price" => pprice * (1.001 + rand() * 0.049),
                "leverage" => 10.0,
                "min_markup" => 0.002,
                "markup_range" => 0.005,
                "n_close_orders" => 5,
                "min_qty" => 1.0,
                "qty_step" => 1.0,
                "price_step" => 0.0001,
                "long" => true
            )
        end
        for _ in 1:30
    ]
    
    return cases
end

function run_tests(cases)
    results = Dict{String,Vector{Dict{String,Any}}}()
    
    results["round_"] = [
        Dict("input" => c, "output" => round_(c["n"], c["step"]))
        for c in cases["round_"]
    ]
    
    results["round_up"] = [
        Dict("input" => c, "output" => round_up(c["n"], c["step"]))
        for c in cases["round_up"]
    ]
    
    results["round_dn"] = [
        Dict("input" => c, "output" => round_dn(c["n"], c["step"]))
        for c in cases["round_dn"]
    ]
    
    results["calc_diff"] = [
        Dict("input" => c, "output" => calc_diff(c["x"], c["y"]))
        for c in cases["calc_diff"]
    ]
    
    results["calc_ema"] = [
        Dict("input" => c, "output" => calc_ema(c["alpha"], c["alpha_"], c["prev_ema"], c["new_val"]))
        for c in cases["calc_ema"]
    ]
    
    results["calc_new_psize_pprice"] = []
    for c in cases["calc_new_psize_pprice"]
        psize, pprice = calc_new_psize_pprice(c["psize"], c["pprice"], c["qty"], c["price"], 1.0)
        push!(results["calc_new_psize_pprice"], Dict(
            "input" => c,
            "output" => Dict("psize" => psize, "pprice" => pprice)
        ))
    end
    
    results["calc_long_pnl"] = [
        Dict("input" => c, "output" => calc_long_pnl(c["entry_price"], c["close_price"], c["qty"]))
        for c in cases["calc_long_pnl"]
    ]
    
    results["calc_shrt_pnl"] = [
        Dict("input" => c, "output" => calc_shrt_pnl(c["entry_price"], c["close_price"], c["qty"]))
        for c in cases["calc_shrt_pnl"]
    ]
    
    results["calc_cost"] = [
        Dict("input" => c, "output" => calc_cost(c["qty"], c["price"]))
        for c in cases["calc_cost"]
    ]
    
    results["calc_margin_cost"] = [
        Dict("input" => c, "output" => calc_margin_cost(c["qty"], c["price"], c["leverage"]))
        for c in cases["calc_margin_cost"]
    ]
    
    results["calc_available_margin"] = [
        Dict("input" => c, "output" => calc_available_margin(
            c["balance"], c["long_psize"], c["long_pprice"],
            c["shrt_psize"], c["shrt_pprice"], 50.0, c["leverage"]
        ))
        for c in cases["calc_available_margin"]
    ]
    
    results["calc_liq_price"] = []
    for c in cases["calc_liq_price"]
        if c["long"]
            liq = calc_liq_price_binance(c["balance"], c["psize"], c["pprice"], 0.0, 0.0, c["leverage"])
        else
            liq = calc_liq_price_binance(c["balance"], 0.0, 0.0, -c["psize"], c["pprice"], c["leverage"])
        end
        push!(results["calc_liq_price"], Dict("input" => c, "output" => liq))
    end
    
    results["calc_bid_ask_thresholds"] = []
    for c in cases["calc_bid_ask_thresholds"]
        bid_thr, ask_thr = calc_bid_ask_thresholds(
            c["ema"], c["ema_spread"], c["volatility"], c["volatility_grid_coeff"]
        )
        push!(results["calc_bid_ask_thresholds"], Dict(
            "input" => c,
            "output" => Dict("bid_thr" => bid_thr, "ask_thr" => ask_thr)
        ))
    end
    
    results["iter_entries"] = []
    for c in cases["iter_entries"]
        entries_list = Dict{String,Any}[]
        try
            for entry in iter_entries(
                c["balance"], c["psize"], c["pprice"], 0.0, 0.0, 0.0,
                c["entry_price"], c["entry_price"] * 1.001, c["ema"],
                c["entry_price"], c["volatility"], c["long"], false,
                c["qty_step"], c["price_step"], c["min_qty"], c["min_cost"],
                c["ddown_factor"], c["qty_pct"], c["leverage"], 5.0,
                c["grid_spacing"], c["pos_margin_grid_coeff"],
                c["volatility_grid_coeff"], c["volatility_qty_coeff"],
                0.002, 0.005, 5000.0, 0.002, 0.1, 0.1, c["entry_liq_diff_thr"]
            )
                push!(entries_list, Dict("qty" => entry[1], "price" => entry[2], "type" => entry[5]))
                length(entries_list) >= 10 && break
            end
        catch e
        end
        push!(results["iter_entries"], Dict("input" => c, "output" => entries_list))
    end
    
    results["iter_closes"] = []
    for c in cases["iter_closes"]
        closes_list = Dict{String,Any}[]
        try
            for close_order in iter_long_closes(
                c["balance"], c["psize"], c["pprice"], c["close_price"],
                true, false, c["qty_step"], c["price_step"],
                c["min_qty"], c["min_cost"], 0.5, 0.1, c["leverage"],
                Float64(c["n_close_orders"]), 0.01, 0.5, 0.5, 0.5,
                c["min_markup"], c["markup_range"], 5000.0, 0.002,
                0.1, 0.1, 0.1
            )
                push!(closes_list, Dict("qty" => close_order[1], "price" => close_order[2], "type" => "long_close"))
            end
        catch e
        end
        push!(results["iter_closes"], Dict("input" => c, "output" => closes_list))
    end
    
    return results
end

function main()
    output_dir = @__DIR__
    output_path = joinpath(output_dir, "output", "julia", "unit_tests.json")
    
    println("Generating test cases...")
    cases = generate_test_cases()
    
    println("Running Julia unit tests...")
    results = run_tests(cases)
    
    mkpath(dirname(output_path))
    open(output_path, "w") do f
        JSON3.write(f, results)
    end
    
    println("Results saved to $output_path")
    
    for (func_name, func_results) in results
        println("  $func_name: $(length(func_results)) tests")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
