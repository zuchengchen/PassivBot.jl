#!/usr/bin/env julia
"""
Julia backtest with fill/state output for comparison with Python version.
"""

using ArgParse
using JSON3
using Dates

include(joinpath(@__DIR__, "..", "..", "src", "PassivBot.jl"))
using .PassivBot

function backtest_with_output(config::Dict, ticks::Matrix{Float64}, output_dir::String)
    ema_span = Int(round(config["ema_span"]))
    if size(ticks, 1) <= ema_span
        return Dict[], Dict[], Dict[], false
    end
    
    long_psize, long_pprice = 0.0, 0.0
    shrt_psize, shrt_pprice = 0.0, 0.0
    liq_price, liq_diff = 0.0, 1.0
    balance = Float64(config["starting_balance"])
    
    if !haskey(config, "entry_liq_diff_thr")
        config["entry_liq_diff_thr"] = get(config, "stop_loss_liq_diff", 0.1)
    end
    
    xk = Dict{String, Float64}(k => Float64(config[k]) for k in get_keys())
    calc_liq_price = Jitted.calc_liq_price_binance
    
    latency_simulation_ms = get(config, "latency_simulation_ms", 1000.0)
    
    next_stats_update = 0.0
    stats = Dict{String,Any}[]
    state_snapshots = Dict{String,Any}[]
    snapshot_interval = 1000
    
    function stats_update(tick)
        upnl_l = long_pprice != 0.0 && long_psize != 0.0 ? Jitted.calc_long_pnl(long_pprice, tick[1], long_psize) : 0.0
        upnl_s = shrt_pprice != 0.0 && shrt_psize != 0.0 ? Jitted.calc_shrt_pnl(shrt_pprice, tick[1], shrt_psize) : 0.0
        push!(stats, Dict{String,Any}(
            "timestamp" => tick[3],
            "balance" => balance,
            "equity" => balance + upnl_l + upnl_s
        ))
    end
    
    all_fills = Dict{String,Any}[]
    bids = Vector{Any}[]
    asks = Vector{Any}[]
    
    ob = [min(ticks[1, 1], ticks[2, 1]), max(ticks[1, 1], ticks[2, 1])]
    
    ema_std_iterator = Jitted.iter_indicator_chunks(ticks[:, 1], ema_span)
    iter_result = iterate(ema_std_iterator)
    if iter_result === nothing
        return Dict[], Dict[], Dict[], false
    end
    (ema_chunk_val, std_chunk_val, z_val), ema_state = iter_result
    
    volatility_chunk = replace(std_chunk_val ./ ema_chunk_val, NaN => 0.0, Inf => 0.0, -Inf => 0.0)
    zc = 0
    
    closest_liq = 1.0
    prev_update_plus_delay = ticks[ema_span, 3] + latency_simulation_ms
    update_triggered = false
    prev_update_plus_5sec = 0.0
    
    tick = ticks[1, :]
    stats_update(tick)
    
    for k in (ema_span + 1):size(ticks, 1)
        tick = ticks[k, :]
        
        chunk_i = k - zc
        if chunk_i > length(ema_chunk_val)
            next_result = iterate(ema_std_iterator, ema_state)
            if next_result === nothing
                break
            end
            (ema_chunk_val, std_chunk_val, z_val), ema_state = next_result
            volatility_chunk = replace(std_chunk_val ./ ema_chunk_val, NaN => 0.0, Inf => 0.0, -Inf => 0.0)
            zc = z_val * length(ema_chunk_val)
            chunk_i = k - zc
        end
        
        if k % snapshot_interval == 0
            upnl = long_psize != 0.0 || shrt_psize != 0.0 ? 
                Jitted.calc_long_pnl(long_pprice, tick[1], long_psize) + Jitted.calc_shrt_pnl(shrt_pprice, tick[1], shrt_psize) : 0.0
            push!(state_snapshots, Dict{String,Any}(
                "tick_index" => k,
                "timestamp" => tick[3],
                "price" => tick[1],
                "trigger" => "periodic",
                "ema" => Dict("ema" => ema_chunk_val[chunk_i], "ema_span" => config["ema_span"], "ema_spread" => config["ema_spread"]),
                "volatility" => Dict("volatility" => volatility_chunk[chunk_i]),
                "position" => Dict("long_psize" => long_psize, "long_pprice" => long_pprice, "shrt_psize" => shrt_psize, "shrt_pprice" => shrt_pprice),
                "balance" => Dict("balance" => balance, "equity" => balance + upnl),
                "orders" => Dict("bids" => [Dict("qty" => b[1], "price" => b[2]) for b in bids[1:min(5, length(bids))]], 
                               "asks" => [Dict("qty" => a[1], "price" => a[2]) for a in asks[1:min(5, length(asks))]]),
                "thresholds" => Dict("bid_thr" => ob[1], "ask_thr" => ob[2])
            ))
        end
        
        if tick[3] > next_stats_update
            closest_liq = min(closest_liq, Jitted.calc_diff(liq_price, tick[1]))
            stats_update(tick)
            next_stats_update = tick[3] + 1000 * 60 * 30
        end
        
        fills = Dict[]
        
        if tick[2] == 1.0
            if liq_diff < 0.05 && long_psize > -shrt_psize && tick[1] <= liq_price
                push!(fills, Dict(
                    "qty" => -long_psize, "price" => tick[1], "pside" => "long",
                    "type" => "long_liquidation", "side" => "sel",
                    "pnl" => Jitted.calc_long_pnl(long_pprice, tick[1], long_psize),
                    "fee_paid" => -Jitted.calc_cost(long_psize, tick[1]) * config["taker_fee"],
                    "long_psize" => 0.0, "long_pprice" => 0.0,
                    "shrt_psize" => 0.0, "shrt_pprice" => 0.0,
                    "liq_price" => 0.0, "liq_diff" => 1.0
                ))
                long_psize, long_pprice, shrt_psize, shrt_pprice = 0.0, 0.0, 0.0, 0.0
            else
                if !isempty(bids)
                    if tick[1] <= bids[1][2]
                        update_triggered = true
                    end
                    while !isempty(bids)
                        if tick[1] < bids[1][2]
                            bid = popfirst!(bids)
                            fill = Dict{String,Any}(
                                "qty" => bid[1], "price" => bid[2], "side" => "buy", "type" => bid[5],
                                "fee_paid" => -Jitted.calc_cost(bid[1], bid[2]) * config["maker_fee"]
                            )
                            if occursin("close", bid[5])
                                fill["pnl"] = Jitted.calc_shrt_pnl(shrt_pprice, bid[2], bid[1])
                                shrt_psize = min(0.0, Jitted.round_(shrt_psize + bid[1], config["qty_step"]))
                                merge!(fill, Dict("pside" => "shrt", "long_psize" => long_psize, "long_pprice" => long_pprice, "shrt_psize" => shrt_psize, "shrt_pprice" => shrt_pprice))
                            else
                                fill["pnl"] = 0.0
                                long_psize, long_pprice = Jitted.calc_new_psize_pprice(long_psize, long_pprice, bid[1], bid[2], xk["qty_step"])
                                if long_psize < 0.0
                                    long_psize, long_pprice = 0.0, 0.0
                                end
                                merge!(fill, Dict("pside" => "long", "long_psize" => bid[3], "long_pprice" => bid[4], "shrt_psize" => shrt_psize, "shrt_pprice" => shrt_pprice))
                            end
                            push!(fills, fill)
                        else
                            break
                        end
                    end
                end
            end
            ob[1] = tick[1]
        else
            if liq_diff < 0.05 && -shrt_psize > long_psize && tick[1] >= liq_price
                push!(fills, Dict(
                    "qty" => -shrt_psize, "price" => tick[1], "pside" => "shrt",
                    "type" => "shrt_liquidation", "side" => "buy",
                    "pnl" => Jitted.calc_shrt_pnl(shrt_pprice, tick[1], shrt_psize),
                    "fee_paid" => -Jitted.calc_cost(shrt_psize, tick[1]) * config["taker_fee"],
                    "long_psize" => 0.0, "long_pprice" => 0.0,
                    "shrt_psize" => 0.0, "shrt_pprice" => 0.0,
                    "liq_price" => 0.0, "liq_diff" => 1.0
                ))
                long_psize, long_pprice, shrt_psize, shrt_pprice = 0.0, 0.0, 0.0, 0.0
            else
                if !isempty(asks)
                    if tick[1] >= asks[1][2]
                        update_triggered = true
                    end
                    while !isempty(asks)
                        if tick[1] > asks[1][2]
                            ask = popfirst!(asks)
                            fill = Dict{String,Any}(
                                "qty" => ask[1], "price" => ask[2], "side" => "sel", "type" => ask[5],
                                "fee_paid" => -Jitted.calc_cost(ask[1], ask[2]) * config["maker_fee"]
                            )
                            if occursin("close", ask[5])
                                fill["pnl"] = Jitted.calc_long_pnl(long_pprice, ask[2], ask[1])
                                long_psize = max(0.0, Jitted.round_(long_psize + ask[1], config["qty_step"]))
                                merge!(fill, Dict("pside" => "long", "long_psize" => long_psize, "long_pprice" => long_pprice, "shrt_psize" => shrt_psize, "shrt_pprice" => shrt_pprice))
                            else
                                fill["pnl"] = 0.0
                                shrt_psize, shrt_pprice = Jitted.calc_new_psize_pprice(shrt_psize, shrt_pprice, ask[1], ask[2], xk["qty_step"])
                                if shrt_psize > 0.0
                                    shrt_psize, shrt_pprice = 0.0, 0.0
                                end
                                merge!(fill, Dict("pside" => "shrt", "long_psize" => long_psize, "long_pprice" => long_pprice, "shrt_psize" => shrt_psize, "shrt_pprice" => shrt_pprice))
                            end
                            liq_diff = Jitted.calc_diff(liq_price, tick[1])
                            merge!(fill, Dict("liq_price" => liq_price, "liq_diff" => liq_diff))
                            push!(fills, fill)
                        else
                            break
                        end
                    end
                end
            end
            ob[2] = tick[1]
        end
        
        if tick[3] > prev_update_plus_delay && (update_triggered || tick[3] > prev_update_plus_5sec)
            prev_update_plus_delay = tick[3] + latency_simulation_ms
            prev_update_plus_5sec = tick[3] + 5000
            update_triggered = false
            bids = Vector{Any}[]
            asks = Vector{Any}[]
            liq_diff = Jitted.calc_diff(liq_price, tick[1])
            closest_liq = min(closest_liq, liq_diff)
            
            for tpl in Jitted.iter_entries(
                balance, long_psize, long_pprice, shrt_psize, shrt_pprice,
                liq_price, ob[1], ob[2], ema_chunk_val[chunk_i], tick[1],
                volatility_chunk[chunk_i], 
                xk["do_long"] > 0.5, xk["do_shrt"] > 0.5, xk["qty_step"], xk["price_step"],
                xk["min_qty"], xk["min_cost"], xk["ddown_factor"], xk["qty_pct"], xk["leverage"],
                xk["n_close_orders"], xk["grid_spacing"], xk["pos_margin_grid_coeff"],
                xk["volatility_grid_coeff"], xk["volatility_qty_coeff"],
                xk["min_markup"], xk["markup_range"], Float64(ema_span), xk["ema_spread"],
                xk["stop_loss_liq_diff"], xk["stop_loss_pos_pct"], xk["entry_liq_diff_thr"]
            )
                if length(bids) > 2 && length(asks) > 2
                    break
                end
                if tpl[1] > 0.0
                    push!(bids, collect(tpl))
                elseif tpl[1] < 0.0
                    push!(asks, collect(tpl))
                else
                    break
                end
            end
            
            if tick[1] <= shrt_pprice && shrt_pprice > 0.0
                for tpl in Jitted.iter_shrt_closes(
                    balance, shrt_psize, shrt_pprice, ob[1],
                    xk["do_long"] > 0.5, xk["do_shrt"] > 0.5, xk["qty_step"], xk["price_step"],
                    xk["min_qty"], xk["min_cost"], xk["ddown_factor"], xk["qty_pct"], xk["leverage"],
                    xk["n_close_orders"], xk["grid_spacing"], xk["pos_margin_grid_coeff"],
                    xk["volatility_grid_coeff"], xk["volatility_qty_coeff"],
                    xk["min_markup"], xk["markup_range"], Float64(ema_span), xk["ema_spread"],
                    xk["stop_loss_liq_diff"], xk["stop_loss_pos_pct"], xk["entry_liq_diff_thr"]
                )
                    push!(bids, vcat(collect(tpl), [shrt_pprice, "shrt_close"]))
                end
            end
            
            if tick[1] >= long_pprice && long_pprice > 0.0
                for tpl in Jitted.iter_long_closes(
                    balance, long_psize, long_pprice, ob[2],
                    xk["do_long"] > 0.5, xk["do_shrt"] > 0.5, xk["qty_step"], xk["price_step"],
                    xk["min_qty"], xk["min_cost"], xk["ddown_factor"], xk["qty_pct"], xk["leverage"],
                    xk["n_close_orders"], xk["grid_spacing"], xk["pos_margin_grid_coeff"],
                    xk["volatility_grid_coeff"], xk["volatility_qty_coeff"],
                    xk["min_markup"], xk["markup_range"], Float64(ema_span), xk["ema_spread"],
                    xk["stop_loss_liq_diff"], xk["stop_loss_pos_pct"], xk["entry_liq_diff_thr"]
                )
                    push!(asks, vcat(collect(tpl), [long_pprice, "long_close"]))
                end
            end
            
            sort!(bids, by=x -> x[2], rev=true)
            sort!(asks, by=x -> x[2])
        end
        
        if !isempty(fills)
            for fill in fills
                balance += fill["pnl"] + fill["fee_paid"]
                upnl_l = Jitted.calc_long_pnl(long_pprice, tick[1], long_psize)
                upnl_s = Jitted.calc_shrt_pnl(shrt_pprice, tick[1], shrt_psize)
                
                liq_price = calc_liq_price(balance, long_psize, long_pprice, shrt_psize, shrt_pprice, Float64(config["max_leverage"]))
                liq_diff = Jitted.calc_diff(liq_price, tick[1])
                merge!(fill, Dict("liq_price" => liq_price, "liq_diff" => liq_diff))
                
                fill["equity"] = balance + upnl_l + upnl_s
                fill["available_margin"] = Jitted.calc_available_margin(balance, long_psize, long_pprice, shrt_psize, shrt_pprice, tick[1], xk["leverage"])
                
                for side_ in ["long", "shrt"]
                    if fill["$(side_)_pprice"] == 0.0
                        fill["$(side_)_pprice"] = nothing
                    end
                end
                
                fill["balance"] = balance
                fill["timestamp"] = tick[3]
                fill["trade_id"] = k
                fill["tick_index"] = k
                fill["gain"] = fill["equity"] / config["starting_balance"]
                fill["n_days"] = (tick[3] - ticks[ema_span, 3]) / (1000 * 60 * 60 * 24)
                fill["closest_liq"] = closest_liq
                
                try
                    fill["average_daily_gain"] = fill["n_days"] > 0.5 && fill["gain"] > 0.0 ? fill["gain"] ^ (1 / fill["n_days"]) : 0.0
                catch
                    fill["average_daily_gain"] = 0.0
                end
                
                push!(all_fills, fill)
                
                push!(state_snapshots, Dict{String,Any}(
                    "tick_index" => k,
                    "timestamp" => tick[3],
                    "price" => tick[1],
                    "trigger" => "fill",
                    "fill_type" => fill["type"],
                    "ema" => Dict("ema" => ema_chunk_val[chunk_i]),
                    "volatility" => Dict("volatility" => volatility_chunk[chunk_i]),
                    "position" => Dict("long_psize" => long_psize, "long_pprice" => long_pprice, "shrt_psize" => shrt_psize, "shrt_pprice" => shrt_pprice),
                    "balance" => Dict("balance" => balance, "equity" => fill["equity"])
                ))
                
                if balance <= 0.0 || occursin("liquidation", fill["type"])
                    return all_fills, stats, state_snapshots, false
                end
            end
        end
    end
    
    tick = ticks[end, :]
    stats_update(tick)
    
    mkpath(output_dir)
    open(joinpath(output_dir, "fills.json"), "w") do f
        JSON3.write(f, all_fills)
    end
    open(joinpath(output_dir, "states.json"), "w") do f
        JSON3.write(f, state_snapshots)
    end
    open(joinpath(output_dir, "stats.json"), "w") do f
        JSON3.write(f, stats)
    end
    
    return all_fills, stats, state_snapshots, true
end

function parse_args()
    s = ArgParseSettings()
    @add_arg_table! s begin
        "live_config_path"
            help = "path to live config"
            required = true
        "-s", "--symbol"
            help = "symbol"
            default = "none"
        "--start-date"
            help = "start date"
            default = "none"
        "--end-date"
            help = "end date"
            default = "none"
    end
    return ArgParse.parse_args(s)
end

function main()
    args = parse_args()
    
    live_config = load_live_config(args["live_config_path"])
    
    bc_config = Dict{String,Any}(
        "exchange" => "binance",
        "symbol" => args["symbol"] != "none" ? args["symbol"] : get(live_config, "symbol", "BTCUSDT"),
        "start_date" => args["start-date"] != "none" ? args["start-date"] : "2026-02-01",
        "end_date" => args["end-date"] != "none" ? args["end-date"] : "2026-02-02",
        "user" => "default",
        "starting_balance" => get(live_config, "starting_balance", 1000.0),
        "latency_simulation_ms" => 1000,
        "maker_fee" => 0.00018,
        "taker_fee" => 0.00036,
        "max_leverage" => 20.0
    )
    
    config = merge(bc_config, live_config)
    config["session_name"] = replace(replace(config["start_date"], "-" => ""), ":" => "") * "_" * replace(replace(config["end_date"], "-" => ""), ":" => "")
    
    base_dirpath = joinpath("backtests", config["exchange"], config["symbol"])
    config["caches_dirpath"] = make_get_filepath(joinpath(base_dirpath, "caches", ""))
    
    println("Symbol: $(config["symbol"])")
    println("Start: $(config["start_date"])")
    println("End: $(config["end_date"])")
    
    downloader = Downloader(config)
    ticks = get_ticks(downloader, single_file=true)
    
    output_dir = joinpath(@__DIR__, "output", "julia")
    
    println("Running backtest with $(size(ticks, 1)) ticks...")
    fills, stats, state_snapshots, did_finish = backtest_with_output(config, ticks, output_dir)
    
    println("Fills: $(length(fills))")
    println("State snapshots: $(length(state_snapshots))")
    println("Output saved to: $output_dir")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
