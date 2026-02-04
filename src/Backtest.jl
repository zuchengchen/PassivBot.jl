# Backtest.jl - Backtesting engine

using Printf
using CSV
using DataFrames

# get_keys fallback - should be defined in Utils.jl or Core.jl
if !isdefined(@__MODULE__, :get_keys)
    # Fallback: define get_keys locally
    function get_keys()
        return [
            "qty_step", "price_step", "min_qty", "min_cost", "c_mult",
            "max_leverage", "leverage", "do_long", "do_shrt",
            "ema_span", "volatility_qty_coeff", "volatility_grid_coeff",
            "grid_spacing", "pbr_limit", "initial_qty_pct", "reentry_qty_pct",
            "min_markup", "markup_range", "n_close_orders"
        ]
    end
end

export backtest, plot_wrap

"""
    backtest(config::Dict, ticks::Matrix{Float64}, do_print::Bool=false) -> (Vector{Dict}, Vector{Dict}, Bool)

Backtests a trading strategy on historical tick data.

# Arguments
- `config::Dict`: Configuration dictionary with trading parameters
- `ticks::Matrix{Float64}`: Tick data matrix with columns [price, buyer_maker, timestamp]
- `do_print::Bool`: Whether to print progress information

# Returns
- `fills::Vector{Dict}`: List of all fills/trades executed
- `stats::Vector{Dict}`: Statistics collected at regular intervals
- `did_finish::Bool`: Whether backtest completed successfully (true) or liquidated (false)
"""
function backtest(config::Dict, ticks::Matrix{Float64}, do_print::Bool=false)
    # Check if we have enough data
    ema_span = Int(round(config["ema_span"]))
    if size(ticks, 1) <= ema_span
        return Dict[], Dict[], false
    end
    
    # Initialize position variables
    long_psize, long_pprice = 0.0, 0.0
    shrt_psize, shrt_pprice = 0.0, 0.0
    liq_price, liq_diff = 0.0, 1.0
    balance = config["starting_balance"]
    pbr_limit = 1.0
    
    # Check for initial positions in config
    if all(haskey(config, k) for k in ["long_pprice", "long_psize", "shrt_pprice", "shrt_psize"])
        long_pprice = config["long_pprice"]
        long_psize = config["long_psize"]
        shrt_pprice = config["shrt_pprice"]
        shrt_psize = config["shrt_psize"]
    end
    
    # Initialize cumulative tracking
    pnl_plus_fees_cumsum = 0.0
    loss_cumsum = 0.0
    profit_cumsum = 0.0
    fee_paid_cumsum = 0.0
    
    # Set defaults for missing config keys
    if !haskey(config, "entry_liq_diff_thr")
        config["entry_liq_diff_thr"] = get(config, "stop_loss_liq_diff", 0.1)
    end
    
    # Get config keys as floats
    xk = Dict{String, Float64}(k => Float64(config[k]) for k in get_keys())
    
    # Use Binance liquidation price calculation
    calc_liq_price = Jitted.calc_liq_price_binance
    
    # Initialize timestamp tracking
    prev_long_close_ts, prev_long_entry_ts, prev_long_close_price = 0, 0, 0.0
    prev_shrt_close_ts, prev_shrt_entry_ts, prev_shrt_close_price = 0, 0, 0.0
    
    latency_simulation_ms = get(config, "latency_simulation_ms", 1000.0)
    
    # Statistics tracking
    next_stats_update = 0.0
    stats = Dict[]
    
    # Helper function to update stats
    function stats_update(tick)
        upnl_l = Jitted.calc_long_pnl(long_pprice, tick[1], long_psize)
        upnl_l = isnan(upnl_l) ? 0.0 : upnl_l
        
        upnl_s = Jitted.calc_shrt_pnl(shrt_pprice, tick[1], shrt_psize)
        upnl_s = isnan(upnl_s) ? 0.0 : upnl_s
        
        push!(stats, Dict(
            "timestamp" => tick[3],
            "balance" => balance,
            "equity" => balance + upnl_l + upnl_s
        ))
    end
    
    all_fills = Dict[]
    bids = Vector{Any}[]
    asks = Vector{Any}[]
    
    # Initialize orderbook with first two ticks
    ob = [min(ticks[1, 1], ticks[2, 1]), max(ticks[1, 1], ticks[2, 1])]
    
    # Initialize EMA and volatility calculation
    ema_std_iterator = Jitted.iter_indicator_chunks(ticks[:, 1], ema_span)
    iter_result = iterate(ema_std_iterator)
    if iter_result === nothing
        return Dict[], Dict[], false
    end
    (ema_chunk_val, std_chunk_val, z_val), ema_state = iter_result
    
    volatility_chunk = replace(std_chunk_val ./ ema_chunk_val, NaN => 0.0, Inf => 0.0, -Inf => 0.0)
    zc = 0
    
    closest_liq = 1.0
    
    prev_update_plus_delay = ticks[ema_span + 1, 3] + latency_simulation_ms
    update_triggered = false
    prev_update_plus_5sec = 0.0
    
    # Initial stats update
    tick = ticks[1, :]
    stats_update(tick)
    
    # Main backtest loop - iterate through ticks starting from ema_span
    for k in (ema_span + 1):size(ticks, 1)
        tick = ticks[k, :]
        
        # Update EMA/volatility chunks if needed
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
        
        # Update stats every 30 minutes
        if tick[3] > next_stats_update
            closest_liq = min(closest_liq, Jitted.calc_diff(liq_price, tick[1]))
            stats_update(tick)
            next_stats_update = tick[3] + 1000 * 60 * 30
        end
        
        fills = Dict[]
        
        # Process tick based on buyer_maker flag
        if tick[2] == 1.0  # buyer_maker = true (market buy, we can fill sells)
            # Check for long liquidation
            if liq_diff < 0.05 && long_psize > -shrt_psize && tick[1] <= liq_price
                push!(fills, Dict(
                    "qty" => -long_psize,
                    "price" => tick[1],
                    "pside" => "long",
                    "type" => "long_liquidation",
                    "side" => "sel",
                    "pnl" => Jitted.calc_long_pnl(long_pprice, tick[1], long_psize),
                    "fee_paid" => -Jitted.calc_cost(long_psize, tick[1]) * config["taker_fee"],
                    "long_psize" => 0.0,
                    "long_pprice" => 0.0,
                    "shrt_psize" => 0.0,
                    "shrt_pprice" => 0.0,
                    "liq_price" => 0.0,
                    "liq_diff" => 1.0
                ))
                long_psize, long_pprice, shrt_psize, shrt_pprice = 0.0, 0.0, 0.0, 0.0
            else
                # Process bid fills
                if !isempty(bids)
                    if tick[1] <= bids[1][2]
                        update_triggered = true
                    end
                    while !isempty(bids)
                        if tick[1] < bids[1][2]
                            bid = popfirst!(bids)
                            fill = Dict(
                                "qty" => bid[1],
                                "price" => bid[2],
                                "side" => "buy",
                                "type" => bid[5],
                                "fee_paid" => -Jitted.calc_cost(bid[1], bid[2]) * config["maker_fee"]
                            )
                            
                            if occursin("close", bid[5])
                                # Short close
                                fill["pnl"] = Jitted.calc_shrt_pnl(shrt_pprice, bid[2], bid[1])
                                shrt_psize = min(0.0, Jitted.round_(shrt_psize + bid[1], config["qty_step"]))
                                merge!(fill, Dict(
                                    "pside" => "shrt",
                                    "long_psize" => long_psize,
                                    "long_pprice" => long_pprice,
                                    "shrt_psize" => shrt_psize,
                                    "shrt_pprice" => shrt_pprice
                                ))
                                prev_shrt_close_ts = tick[3]
                            else
                                # Long entry
                                fill["pnl"] = 0.0
                                long_psize, long_pprice = Jitted.calc_new_psize_pprice(
                                    long_psize, long_pprice, bid[1], bid[2], xk["qty_step"]
                                )
                                if long_psize < 0.0
                                    long_psize, long_pprice = 0.0, 0.0
                                end
                                merge!(fill, Dict(
                                    "pside" => "long",
                                    "long_psize" => bid[3],
                                    "long_pprice" => bid[4],
                                    "shrt_psize" => shrt_psize,
                                    "shrt_pprice" => shrt_pprice
                                ))
                                prev_long_entry_ts = tick[3]
                            end
                            push!(fills, fill)
                        else
                            break
                        end
                    end
                end
            end
            ob[1] = tick[1]
            
        else  # buyer_maker = false (market sell, we can fill buys)
            # Check for short liquidation
            if liq_diff < 0.05 && -shrt_psize > long_psize && tick[1] >= liq_price
                push!(fills, Dict(
                    "qty" => -shrt_psize,
                    "price" => tick[1],
                    "pside" => "shrt",
                    "type" => "shrt_liquidation",
                    "side" => "buy",
                    "pnl" => Jitted.calc_shrt_pnl(shrt_pprice, tick[1], shrt_psize),
                    "fee_paid" => -Jitted.calc_cost(shrt_psize, tick[1]) * config["taker_fee"],
                    "long_psize" => 0.0,
                    "long_pprice" => 0.0,
                    "shrt_psize" => 0.0,
                    "shrt_pprice" => 0.0,
                    "liq_price" => 0.0,
                    "liq_diff" => 1.0
                ))
                long_psize, long_pprice, shrt_psize, shrt_pprice = 0.0, 0.0, 0.0, 0.0
            else
                # Process ask fills
                if !isempty(asks)
                    if tick[1] >= asks[1][2]
                        update_triggered = true
                    end
                    while !isempty(asks)
                        if tick[1] > asks[1][2]
                            ask = popfirst!(asks)
                            fill = Dict(
                                "qty" => ask[1],
                                "price" => ask[2],
                                "side" => "sel",
                                "type" => ask[5],
                                "fee_paid" => -Jitted.calc_cost(ask[1], ask[2]) * config["maker_fee"]
                            )
                            
                            if occursin("close", ask[5])
                                # Long close
                                fill["pnl"] = Jitted.calc_long_pnl(long_pprice, ask[2], ask[1])
                                long_psize = max(0.0, Jitted.round_(long_psize + ask[1], config["qty_step"]))
                                merge!(fill, Dict(
                                    "pside" => "long",
                                    "long_psize" => long_psize,
                                    "long_pprice" => long_pprice,
                                    "shrt_psize" => shrt_psize,
                                    "shrt_pprice" => shrt_pprice
                                ))
                                prev_long_close_ts = tick[3]
                            else
                                # Short entry
                                fill["pnl"] = 0.0
                                shrt_psize, shrt_pprice = Jitted.calc_new_psize_pprice(
                                    shrt_psize, shrt_pprice, ask[1], ask[2], xk["qty_step"]
                                )
                                if shrt_psize > 0.0
                                    shrt_psize, shrt_pprice = 0.0, 0.0
                                end
                                merge!(fill, Dict(
                                    "pside" => "shrt",
                                    "long_psize" => long_psize,
                                    "long_pprice" => long_pprice,
                                    "shrt_psize" => shrt_psize,
                                    "shrt_pprice" => shrt_pprice
                                ))
                                prev_shrt_entry_ts = tick[3]
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
        
        # Update orders if enough time has passed
        if tick[3] > prev_update_plus_delay && (update_triggered || tick[3] > prev_update_plus_5sec)
            prev_update_plus_delay = tick[3] + latency_simulation_ms
            prev_update_plus_5sec = tick[3] + 5000
            update_triggered = false
            bids = Vector{Any}[]
            asks = Vector{Any}[]
            liq_diff = Jitted.calc_diff(liq_price, tick[1])
            closest_liq = min(closest_liq, liq_diff)
            
            # Generate entry orders
            for tpl in Jitted.iter_entries(
                balance, long_psize, long_pprice, shrt_psize, shrt_pprice,
                liq_price, ob[1], ob[2], ema_chunk_val[chunk_i], tick[1],
                volatility_chunk[chunk_i], 
                xk["do_long"], xk["do_shrt"], xk["qty_step"], xk["price_step"],
                xk["min_qty"], xk["min_cost"], 1.0, 1.0, xk["leverage"],
                xk["n_close_orders"], xk["grid_spacing"], 1.0,
                xk["volatility_grid_coeff"], xk["volatility_qty_coeff"],
                xk["min_markup"], xk["markup_range"], Float64(ema_span), 0.0,
                0.0, 0.0, 0.0
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
            
            # Generate short close orders
            if tick[1] <= shrt_pprice && shrt_pprice > 0.0
                for tpl in Jitted.iter_shrt_closes(
                    balance, shrt_psize, shrt_pprice, ob[1],
                    xk["do_long"], xk["do_shrt"], xk["qty_step"], xk["price_step"],
                    xk["min_qty"], xk["min_cost"], 1.0, 1.0, xk["leverage"],
                    xk["n_close_orders"], xk["grid_spacing"], 1.0,
                    xk["volatility_grid_coeff"], xk["volatility_qty_coeff"],
                    xk["min_markup"], xk["markup_range"], Float64(ema_span), 0.0,
                    0.0, 0.0, 0.0
                )
                    push!(bids, vcat(collect(tpl), [shrt_pprice, "shrt_close"]))
                end
            end
            
            # Generate long close orders
            if tick[1] >= long_pprice && long_pprice > 0.0
                for tpl in Jitted.iter_long_closes(
                    balance, long_psize, long_pprice, ob[2],
                    xk["do_long"], xk["do_shrt"], xk["qty_step"], xk["price_step"],
                    xk["min_qty"], xk["min_cost"], 1.0, 1.0, xk["leverage"],
                    xk["n_close_orders"], xk["grid_spacing"], 1.0,
                    xk["volatility_grid_coeff"], xk["volatility_qty_coeff"],
                    xk["min_markup"], xk["markup_range"], Float64(ema_span), 0.0,
                    0.0, 0.0, 0.0
                )
                    push!(asks, vcat(collect(tpl), [long_pprice, "long_close"]))
                end
            end
            
            # Sort orders
            sort!(bids, by=x -> x[2], rev=true)
            sort!(asks, by=x -> x[2])
        end
        
        # Process fills
        if !isempty(fills)
            for fill in fills
                balance += fill["pnl"] + fill["fee_paid"]
                
                upnl_l = Jitted.calc_long_pnl(long_pprice, tick[1], long_psize)
                upnl_s = Jitted.calc_shrt_pnl(shrt_pprice, tick[1], shrt_psize)
                
                liq_price = calc_liq_price(
                    balance, long_psize, long_pprice, shrt_psize, shrt_pprice,
                    config["max_leverage"]
                )
                liq_diff = Jitted.calc_diff(liq_price, tick[1])
                merge!(fill, Dict("liq_price" => liq_price, "liq_diff" => liq_diff))
                
                fill["equity"] = balance + upnl_l + upnl_s
                fill["available_margin"] = Jitted.calc_available_margin(
                    balance, long_psize, long_pprice, shrt_psize, shrt_pprice,
                    tick[1], xk["leverage"]
                )
                
                # Set pprice to NaN if zero
                for side_ in ["long", "shrt"]
                    if fill["$(side_)_pprice"] == 0.0
                        fill["$(side_)_pprice"] = NaN
                    end
                end
                
                fill["balance"] = balance
                fill["timestamp"] = tick[3]
                fill["trade_id"] = k
                fill["gain"] = fill["equity"] / config["starting_balance"]
                fill["n_days"] = (tick[3] - ticks[ema_span + 1, 3]) / (1000 * 60 * 60 * 24)
                fill["closest_liq"] = closest_liq
                
                try
                    fill["average_daily_gain"] = if fill["n_days"] > 0.5 && fill["gain"] > 0.0
                        fill["gain"] ^ (1 / fill["n_days"])
                    else
                        0.0
                    end
                catch
                    fill["average_daily_gain"] = 0.0
                end
                
                push!(all_fills, fill)
                
                # Check for liquidation or zero balance
                if balance <= 0.0 || occursin("liquidation", fill["type"])
                    return all_fills, stats, false
                end
            end
            
            if do_print
                line = @sprintf("%.3f ", k / size(ticks, 1))
                line *= @sprintf("adg %.4f ", all_fills[end]["average_daily_gain"])
                line *= @sprintf("AR %.2f ", all_fills[end]["average_daily_gain"]^365 - 1)
                line *= @sprintf("closest_liq %.4f ", closest_liq)
                print("\r", line, " ")
            end
        end
    end
    
    # Final stats update
    tick = ticks[end, :]
    stats_update(tick)
    
    return all_fills, stats, true
end

"""
    plot_wrap(bc::Dict, ticks::Matrix{Float64}, live_config::Dict, plot::String="True")

Wrapper function for backtesting with analysis and plotting.

# Arguments
- `bc::Dict`: Backtest configuration
- `ticks::Matrix{Float64}`: Tick data matrix
- `live_config::Dict`: Live trading configuration
- `plot::String`: Whether to plot results ("True" or "False")

# Returns
- `fills::Vector{Dict}`: All fills from backtest
- `stats::Vector{Dict}`: Statistics snapshots
- `did_finish::Bool`: Whether backtest completed successfully
- `result::Dict`: Analysis results (if fills exist)
"""
function plot_wrap(bc::Dict, ticks::Matrix{Float64}, live_config::Dict, plot::String="True")
    n_days = Jitted.round_((ticks[end, 3] - ticks[1, 3]) / (1000 * 60 * 60 * 24), 0.1)
    println("n_days ", Jitted.round_(n_days, 0.1))
    
    config = merge(bc, live_config)
    println("starting_balance ", config["starting_balance"])
    println("backtesting...")
    
    fills, stats, did_finish = backtest(config, ticks, true)
    
    if isempty(fills)
        println("no fills")
        return fills, stats, did_finish, Dict{String,Any}()
    end
    
    println("Backtest completed with $(length(fills)) fills")
    println("Did finish: $did_finish")
    
    # Analyze fills and samples
    println("Analyzing results...")
    fdf, sdf, result = analyze_backtest(fills, stats, config)
    
    # Store result in config for plotting
    config["result"] = result
    
    # Create output directory with timestamp
    timestamp_str = replace(ts_to_date(time())[1:19], ":" => "")
    plots_dirpath = get(config, "plots_dirpath", "plots/")
    output_dir = joinpath(plots_dirpath, timestamp_str, "")
    mkpath(output_dir)
    config["plots_dirpath"] = output_dir
    
    # Add metadata to config for plotting
    config["start_date"] = get(bc, "start_date", "")
    config["end_date"] = get(bc, "end_date", "")
    
    # Save fills to CSV if plotting
    if plot == "True"
        println("Saving fills to CSV...")
        fills_csv_path = joinpath(output_dir, "fills.csv")
        CSV.write(fills_csv_path, fdf)
        println("Fills saved to $fills_csv_path")
    end
    
    # Create tick DataFrame for plotting
    df = DataFrame(
        price = ticks[:, 1],
        buyer_maker = ticks[:, 2],
        timestamp = ticks[:, 3]
    )
    
    # Generate plots
    println("Dumping plots...")
    dump_plots(config, fdf, df, plot)
    
    return fills, stats, did_finish, result
end
