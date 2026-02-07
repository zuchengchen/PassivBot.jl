"""
    Plotting

Visualization utilities for backtest results.
Uses Plots.jl for creating charts and graphs.
Ported from plotting.py with full feature parity.
"""

using Plots
using DataFrames
using Statistics
using JSON3

export dump_plots, plot_fills, plot_balance_and_equity
export plot_position_sizes, plot_average_daily_gain

function ffill!(v::AbstractVector)
    last_valid = v[1]
    for i in 2:length(v)
        if ismissing(v[i]) || (v[i] isa Number && isnan(v[i]))
            v[i] = last_valid
        else
            last_valid = v[i]
        end
    end
    return v
end

function dump_plots(result::Dict{String,Any}, fdf::DataFrame, df::DataFrame, plot::String="True")
    ENV["GKSwstype"] = "100"
    gr()
    default(size=(2900, 1800), dpi=100)

    res = result["result"]
    gain_pct = (res["gain"] - 1) * 100
    adg_pct = (res["average_daily_gain"] - 1) * 100
    annual_return = res["average_daily_gain"]^365 - 1
    closest_liq_pct = res["closest_liq"] * 100

    lines = String[]
    push!(lines, "gain percentage $(round(gain_pct, digits=4))%")
    push!(lines, "average_daily_gain percentage $(round(adg_pct, digits=3))%")
    push!(lines, "annual return $(round(annual_return, digits=5))")
    push!(lines, "closest_liq percentage $(round(closest_liq_pct, digits=4))%")
    push!(lines, "starting balance $(round(result["starting_balance"], digits=3))")

    if plot != "True"
        output_file = "results/backtests/backtest_results_$(result["start_date"])_$(result["end_date"]).txt"
        mkpath(dirname(output_file))
        open(output_file, "a") do f
            write(f, "$(result["symbol"]) $(round(annual_return, digits=5)) $(round(res["closest_liq"], digits=4)) $(round(res["max_hrs_no_fills"], digits=4))\n")
        end
        for line in lines
            println(line)
        end
        return
    end

    skip_keys = ["gain", "average_daily_gain", "closest_liq", "do_long", "do_shrt"]
    for (key, value) in res
        if !(key in skip_keys)
            push!(lines, "$key $(round(value, digits=6))")
        end
    end
    push!(lines, "long: $(result["do_long"]), short: $(result["do_shrt"])")

    plots_dir = get(result, "plots_dirpath", "plots/")
    mkpath(plots_dir)

    live_config = candidate_to_live_config(result)
    open(plots_dir * "live_config.json", "w") do f
        JSON3.write(f, live_config)
    end
    open(plots_dir * "result.json", "w") do f
        JSON3.write(f, result)
    end

    ema_span = Int(round(get(result, "ema_span", 1000.0)))
    ema_spread = Float64(get(result, "ema_spread", 0.001))
    alpha = 2.0 / (ema_span + 1)
    prices = df.price
    ema_vals = similar(prices)
    ema_vals[1] = prices[1]
    @inbounds for i in 2:length(prices)
        ema_vals[i] = ema_vals[i-1] * (1.0 - alpha) + prices[i] * alpha
    end
    df[!, :bid_thr] = ema_vals .* (1.0 - ema_spread)
    df[!, :ask_thr] = ema_vals .* (1.0 + ema_spread)

    println("writing backtest_result.txt...")
    open(plots_dir * "backtest_result.txt", "w") do f
        for line in lines
            println(line)
            write(f, line * "\n")
        end
    end

    println("plotting balance and equity...")
    plot_balance_and_equity(fdf, plots_dir)

    println("plotting backtest whole and in chunks...")
    n_parts = 7
    for z in 0:(n_parts-1)
        start_idx = Int(floor(nrow(fdf) * z / n_parts)) + 1
        end_idx = Int(floor(nrow(fdf) * (z + 1) / n_parts))
        println("$(z/n_parts) $((z+1)/n_parts)")
        fdf_chunk = fdf[start_idx:end_idx, :]
        fig = plot_fills(df, fdf_chunk, liq_thr=0.1)
        savefig(fig, plots_dir * "backtest_$(z+1)of$(n_parts).png")
    end
    fig = plot_fills(df, fdf, liq_thr=0.1)
    savefig(fig, plots_dir * "whole_backtest.png")

    println("plotting pos sizes...")
    plot_position_sizes(fdf, plots_dir)

    println("plotting average daily gain...")
    plot_average_daily_gain(fdf, plots_dir)

    println("All plots saved to $plots_dir")
end

function plot_balance_and_equity(fdf::DataFrame, output_dir::String)
    p = Plots.plot(
        fdf.balance,
        label="Balance",
        xlabel="Fill Index",
        ylabel="Value",
        title="Balance and Equity",
        linewidth=2
    )
    Plots.plot!(p, fdf.equity, label="Equity", linewidth=2)
    savefig(p, output_dir * "balance_and_equity.png")
    return p
end

function plot_position_sizes(fdf::DataFrame, output_dir::String)
    long_pprice_clean = coalesce.(fdf.long_pprice, 0.0)
    long_pprice_clean = [isnan(v) ? 0.0 : v for v in long_pprice_clean]
    shrt_pprice_clean = coalesce.(fdf.shrt_pprice, 0.0)
    shrt_pprice_clean = [isnan(v) ? 0.0 : v for v in shrt_pprice_clean]

    long_psize_rel = (fdf.long_psize .* long_pprice_clean) ./ fdf.balance
    shrt_psize_rel = (fdf.shrt_psize .* shrt_pprice_clean) ./ fdf.balance

    p = Plots.plot(
        long_psize_rel,
        label="Long Position Size",
        xlabel="Fill Index",
        ylabel="Position Size / Balance",
        title="Position Sizes Relative to Balance",
        linewidth=2
    )
    Plots.plot!(p, shrt_psize_rel, label="Short Position Size", linewidth=2)
    savefig(p, output_dir * "psizes_plot.png")
    return p
end

function plot_average_daily_gain(fdf::DataFrame, output_dir::String)
    n = nrow(fdf)
    skip_idx = Int(floor(n * 0.1)) + 1
    adg_subset = fdf.average_daily_gain[skip_idx:end]
    x_norm = range(0.1, 1.0, length=length(adg_subset))

    println("ADG min: $(minimum(adg_subset)), max: $(maximum(adg_subset))")

    p = Plots.plot(
        collect(x_norm), adg_subset,
        label="Average Daily Gain",
        xlabel="Normalized Index",
        ylabel="ADG",
        title="Average Daily Gain (skipping first 10%)",
        linewidth=2
    )
    savefig(p, output_dir * "average_daily_gain_plot.png")
    return p
end

function plot_fills(df::DataFrame, fdf::DataFrame; side::Int=0, liq_thr::Float64=0.1)
    if isempty(fdf)
        return Plots.plot(title="No fills to plot")
    end

    first_tid = Int(fdf.trade_id[1])
    last_tid = Int(fdf.trade_id[end])
    first_idx = max(1, first_tid)
    last_idx = min(nrow(df), last_tid)
    dfc = df[first_idx:last_idx, :]
    x_price = first_idx:last_idx

    p = Plots.plot(
        collect(x_price), dfc.price,
        label="Price", color=:yellow, linewidth=1,
        xlabel="Trade ID", ylabel="Price",
        title="Backtest Fills",
        legend=:outertopright,
        size=(2900, 1800)
    )

    if hasproperty(dfc, :bid_thr)
        Plots.plot!(p, collect(x_price), dfc.bid_thr, label="Bid Threshold", color=:blue, alpha=0.5, linewidth=1)
    end
    if hasproperty(dfc, :ask_thr)
        Plots.plot!(p, collect(x_price), dfc.ask_thr, label="Ask Threshold", color=:red, alpha=0.5, linewidth=1)
    end

    if side >= 0
        longs_mask = fdf.pside .== "long"
        if any(longs_mask)
            longs_df = fdf[longs_mask, :]

            lentry_mask = (longs_df.type .== "long_entry") .| (longs_df.type .== "long_reentry")
            if any(lentry_mask)
                Plots.scatter!(p, longs_df.trade_id[lentry_mask], longs_df.price[lentry_mask],
                    label="Long Entry", color=:blue, markersize=3, markerstrokewidth=0)
            end

            lstopentry_mask = longs_df.type .== "stop_loss_long_entry"
            if any(lstopentry_mask)
                Plots.scatter!(p, longs_df.trade_id[lstopentry_mask], longs_df.price[lstopentry_mask],
                    label="Long Stop Entry", color=:blue, marker=:xcross, markersize=4)
            end

            lclose_mask = longs_df.type .== "long_close"
            if any(lclose_mask)
                Plots.scatter!(p, longs_df.trade_id[lclose_mask], longs_df.price[lclose_mask],
                    label="Long Close", color=:red, marker=:xcross, markersize=4)
            end

            lstopclose_mask = longs_df.type .== "stop_loss_long_close"
            if any(lstopclose_mask)
                Plots.scatter!(p, longs_df.trade_id[lstopclose_mask], longs_df.price[lstopclose_mask],
                    label="Long Stop Close", color=:red, marker=:xcross, markersize=4)
            end

            pprice_vals = Float64.(coalesce.(longs_df.long_pprice, NaN))
            ffill!(pprice_vals)
            Plots.plot!(p, longs_df.trade_id, pprice_vals,
                label="Long Position Price", color=:blue, linestyle=:dash, linewidth=2,
                seriestype=:steppost)
        end
    end

    if side <= 0
        shrts_mask = fdf.pside .== "shrt"
        if any(shrts_mask)
            shrts_df = fdf[shrts_mask, :]

            sentry_mask = (shrts_df.type .== "shrt_entry") .| (shrts_df.type .== "shrt_reentry")
            if any(sentry_mask)
                Plots.scatter!(p, shrts_df.trade_id[sentry_mask], shrts_df.price[sentry_mask],
                    label="Short Entry", color=:red, markersize=3, markerstrokewidth=0)
            end

            sstopentry_mask = shrts_df.type .== "stop_loss_shrt_entry"
            if any(sstopentry_mask)
                Plots.scatter!(p, shrts_df.trade_id[sstopentry_mask], shrts_df.price[sstopentry_mask],
                    label="Short Stop Entry", color=:red, marker=:xcross, markersize=4)
            end

            sclose_mask = shrts_df.type .== "shrt_close"
            if any(sclose_mask)
                Plots.scatter!(p, shrts_df.trade_id[sclose_mask], shrts_df.price[sclose_mask],
                    label="Short Close", color=:blue, marker=:xcross, markersize=4)
            end

            sstopclose_mask = shrts_df.type .== "stop_loss_shrt_close"
            if any(sstopclose_mask)
                Plots.scatter!(p, shrts_df.trade_id[sstopclose_mask], shrts_df.price[sstopclose_mask],
                    label="Short Stop Close", color=:blue, marker=:xcross, markersize=4)
            end

            pprice_vals = Float64.(coalesce.(shrts_df.shrt_pprice, NaN))
            ffill!(pprice_vals)
            Plots.plot!(p, shrts_df.trade_id, pprice_vals,
                label="Short Position Price", color=:red, linestyle=:dash, linewidth=2,
                seriestype=:steppost)
        end
    end

    if hasproperty(fdf, :liq_price) && hasproperty(fdf, :liq_diff)
        liq_prices = Float64.(copy(fdf.liq_price))
        liq_prices[fdf.liq_diff .>= liq_thr] .= NaN
        Plots.plot!(p, fdf.trade_id, liq_prices,
            label="Liquidation Price", color=:black, linestyle=:dash, linewidth=2)
    end

    return p
end
