"""
    Plotting

Visualization utilities for backtest results.
Uses Plots.jl for creating charts and graphs.
"""

using Plots
using DataFrames
using Statistics
using JSON3

export dump_plots, plot_fills, plot_balance_and_equity
export plot_position_sizes, plot_average_daily_gain

"""
    dump_plots(result::Dict, fdf::DataFrame, df::DataFrame, plot::String="True")

Generate and save all backtest plots.
"""
function dump_plots(result::Dict{String,Any}, fdf::DataFrame, df::DataFrame, plot::String="True")
    # Set plot defaults
    gr()  # Use GR backend
    default(size=(2900, 1800), dpi=100)
    
    # Calculate metrics
    res = result["result"]
    gain_pct = (res["gain"] - 1) * 100
    adg_pct = (res["average_daily_gain"] - 1) * 100
    annual_return = res["average_daily_gain"]^365 - 1
    closest_liq_pct = res["closest_liq"] * 100
    
    # Create summary lines
    lines = String[]
    push!(lines, "gain percentage $(round(gain_pct, digits=4))%")
    push!(lines, "average_daily_gain percentage $(round(adg_pct, digits=3))%")
    push!(lines, "annual return $(round(annual_return, digits=5))")
    push!(lines, "closest_liq percentage $(round(closest_liq_pct, digits=4))%")
    push!(lines, "starting balance $(round(result["starting_balance"], digits=3))")
    
    # If not plotting, just write summary
    if plot != "True"
        output_file = "backtests/backtest_results_$(result["start_date"])_$(result["end_date"]).txt"
        mkpath(dirname(output_file))
        open(output_file, "a") do f
            write(f, "$(result["symbol"]) $(round(annual_return, digits=5)) $(round(res["closest_liq"], digits=4)) $(round(res["max_hrs_no_fills"], digits=4))\n")
        end
        for line in lines
            println(line)
        end
        return
    end
    
    # Add all other metrics
    skip_keys = ["gain", "average_daily_gain", "closest_liq", "do_long", "do_shrt"]
    for (key, value) in res
        if !(key in skip_keys)
            push!(lines, "$key $(round(value, digits=6))")
        end
    end
    push!(lines, "long: $(result["do_long"]), short: $(result["do_shrt"])")
    
    # Save configs
    plots_dir = get(result, "plots_dirpath", "plots/")
    mkpath(plots_dir)
    
    live_config = candidate_to_live_config(result)
    open(plots_dir * "live_config.json", "w") do f
        JSON3.write(f, live_config)
    end
    open(plots_dir * "result.json", "w") do f
        JSON3.write(f, result)
    end
    
    # Write summary
    println("writing backtest_result.txt...")
    open(plots_dir * "backtest_result.txt", "w") do f
        for line in lines
            println(line)
            write(f, line * "\n")
        end
    end
    
    # Plot balance and equity
    println("plotting balance and equity...")
    plot_balance_and_equity(fdf, plots_dir)
    
    # Plot backtest in chunks
    println("plotting backtest whole and in chunks...")
    n_parts = 7
    for z in 0:(n_parts-1)
        start_idx = Int(floor(length(fdf.balance) * z / n_parts)) + 1
        end_idx = Int(floor(length(fdf.balance) * (z + 1) / n_parts))
        println("Part $(z+1)/$n_parts: $start_idx to $end_idx")
        
        fdf_chunk = fdf[start_idx:end_idx, :]
        fig = plot_fills(df, fdf_chunk, liq_thr=0.1)
        savefig(fig, plots_dir * "backtest_$(z+1)of$(n_parts).png")
    end
    
    # Plot whole backtest
    fig = plot_fills(df, fdf, liq_thr=0.1)
    savefig(fig, plots_dir * "whole_backtest.png")
    
    # Plot position sizes
    println("plotting pos sizes...")
    plot_position_sizes(fdf, plots_dir)
    
    # Plot average daily gain
    println("plotting average daily gain...")
    plot_average_daily_gain(fdf, plots_dir)
    
    println("All plots saved to $plots_dir")
end

"""
    plot_balance_and_equity(fdf::DataFrame, output_dir::String)

Plot balance and equity over time.
"""
function plot_balance_and_equity(fdf::DataFrame, output_dir::String)
    p = plot(
        fdf.balance,
        label="Balance",
        xlabel="Fill Index",
        ylabel="Value",
        title="Balance and Equity",
        linewidth=2
    )
    plot!(p, fdf.equity, label="Equity", linewidth=2)
    savefig(p, output_dir * "balance_and_equity.png")
    return p
end

"""
    plot_position_sizes(fdf::DataFrame, output_dir::String)

Plot position sizes relative to balance.
"""
function plot_position_sizes(fdf::DataFrame, output_dir::String)
    long_psize_rel = (fdf.long_psize .* fdf.long_pprice) ./ fdf.balance
    shrt_psize_rel = (fdf.shrt_psize .* fdf.shrt_pprice) ./ fdf.balance
    
    p = plot(
        long_psize_rel,
        label="Long Position Size",
        xlabel="Fill Index",
        ylabel="Position Size / Balance",
        title="Position Sizes Relative to Balance",
        linewidth=2
    )
    plot!(p, shrt_psize_rel, label="Short Position Size", linewidth=2)
    savefig(p, output_dir * "psizes_plot.png")
    return p
end

"""
    plot_average_daily_gain(fdf::DataFrame, output_dir::String)

Plot average daily gain over time.
"""
function plot_average_daily_gain(fdf::DataFrame, output_dir::String)
    # Skip first 10% of data
    skip_idx = Int(floor(length(fdf.average_daily_gain) * 0.1)) + 1
    adg_subset = fdf.average_daily_gain[skip_idx:end]
    
    println("ADG min: $(minimum(adg_subset)), max: $(maximum(adg_subset))")
    
    p = plot(
        adg_subset,
        label="Average Daily Gain",
        xlabel="Fill Index (normalized)",
        ylabel="ADG",
        title="Average Daily Gain (skipping first 10%)",
        linewidth=2
    )
    savefig(p, output_dir * "average_daily_gain_plot.png")
    return p
end

"""
    plot_fills(df::DataFrame, fdf::DataFrame; side::Int=0, liq_thr::Float64=0.1)

Plot price action with fills, entries, and closes.

# Arguments
- `df::DataFrame`: Tick data with price information
- `fdf::DataFrame`: Fill data
- `side::Int=0`: Which side to plot (0=both, 1=long only, -1=short only)
- `liq_thr::Float64=0.1`: Liquidation threshold for plotting liq prices
"""
function plot_fills(df::DataFrame, fdf::DataFrame; side::Int=0, liq_thr::Float64=0.1)
    if isempty(fdf)
        return plot(title="No fills to plot")
    end
    
    # Get price data for the fill range
    # Note: This assumes df has an index that matches fdf
    # In practice, you'd need to filter df by timestamp
    
    p = plot(
        xlabel="Index",
        ylabel="Price",
        title="Backtest Fills",
        legend=:outertopright,
        size=(2900, 1800)
    )
    
    # Plot price (simplified - would need proper indexing in real implementation)
    if hasproperty(df, :price) && !isempty(df.price)
        plot!(p, df.price, label="Price", color=:yellow, linewidth=1)
    end
    
    # Plot EMA thresholds if available
    if hasproperty(df, :bid_thr) && !isempty(df.bid_thr)
        plot!(p, df.bid_thr, label="Bid Threshold", color=:blue, alpha=0.5, linewidth=1)
    end
    if hasproperty(df, :ask_thr) && !isempty(df.ask_thr)
        plot!(p, df.ask_thr, label="Ask Threshold", color=:red, alpha=0.5, linewidth=1)
    end
    
    # Plot long side
    if side >= 0
        longs = filter(row -> row.pside == "long", eachrow(fdf)) |> collect
        if !isempty(longs)
            longs_df = DataFrame(longs)
            
            # Long entries
            lentry = filter(row -> row.type in ["long_entry", "long_reentry"], eachrow(longs_df)) |> collect
            if !isempty(lentry)
                lentry_df = DataFrame(lentry)
                scatter!(p, lentry_df.price, label="Long Entry", color=:blue, markersize=3)
            end
            
            # Long stop entries
            lstopentry = filter(row -> row.type == "stop_loss_long_entry", eachrow(longs_df)) |> collect
            if !isempty(lstopentry)
                lstopentry_df = DataFrame(lstopentry)
                scatter!(p, lstopentry_df.price, label="Long Stop Entry", color=:blue, marker=:x, markersize=4)
            end
            
            # Long closes
            lclose = filter(row -> row.type == "long_close", eachrow(longs_df)) |> collect
            if !isempty(lclose)
                lclose_df = DataFrame(lclose)
                scatter!(p, lclose_df.price, label="Long Close", color=:red, marker=:x, markersize=4)
            end
            
            # Long stop closes
            lstopclose = filter(row -> row.type == "stop_loss_long_close", eachrow(longs_df)) |> collect
            if !isempty(lstopclose)
                lstopclose_df = DataFrame(lstopclose)
                scatter!(p, lstopclose_df.price, label="Long Stop Close", color=:red, marker=:x, markersize=4)
            end
            
            # Long position price
            if hasproperty(longs_df, :long_pprice)
                plot!(p, longs_df.long_pprice, label="Long Position Price", color=:blue, linestyle=:dash, linewidth=2)
            end
        end
    end
    
    # Plot short side
    if side <= 0
        shrts = filter(row -> row.pside == "shrt", eachrow(fdf)) |> collect
        if !isempty(shrts)
            shrts_df = DataFrame(shrts)
            
            # Short entries
            sentry = filter(row -> row.type in ["shrt_entry", "shrt_reentry"], eachrow(shrts_df)) |> collect
            if !isempty(sentry)
                sentry_df = DataFrame(sentry)
                scatter!(p, sentry_df.price, label="Short Entry", color=:red, markersize=3)
            end
            
            # Short stop entries
            sstopentry = filter(row -> row.type == "stop_loss_shrt_entry", eachrow(shrts_df)) |> collect
            if !isempty(sstopentry)
                sstopentry_df = DataFrame(sstopentry)
                scatter!(p, sstopentry_df.price, label="Short Stop Entry", color=:red, marker=:x, markersize=4)
            end
            
            # Short closes
            sclose = filter(row -> row.type == "shrt_close", eachrow(shrts_df)) |> collect
            if !isempty(sclose)
                sclose_df = DataFrame(sclose)
                scatter!(p, sclose_df.price, label="Short Close", color=:blue, marker=:x, markersize=4)
            end
            
            # Short stop closes
            sstopclose = filter(row -> row.type == "stop_loss_shrt_close", eachrow(shrts_df)) |> collect
            if !isempty(sstopclose)
                sstopclose_df = DataFrame(sstopclose)
                scatter!(p, sstopclose_df.price, label="Short Stop Close", color=:blue, marker=:x, markersize=4)
            end
            
            # Short position price
            if hasproperty(shrts_df, :shrt_pprice)
                plot!(p, shrts_df.shrt_pprice, label="Short Position Price", color=:red, linestyle=:dash, linewidth=2)
            end
        end
    end
    
    # Plot liquidation price if available
    if hasproperty(fdf, :liq_price) && hasproperty(fdf, :liq_diff)
        liq_prices = copy(fdf.liq_price)
        liq_prices[fdf.liq_diff .>= liq_thr] .= NaN
        plot!(p, liq_prices, label="Liquidation Price", color=:black, linestyle=:dash, linewidth=2)
    end
    
    return p
end
