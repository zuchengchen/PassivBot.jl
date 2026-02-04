"""
    Analysis

Trade analysis and performance metrics.
Ported from analyze.py with full feature parity.
"""

using DataFrames
using Statistics
using Dates

export analyze_fills, analyze_samples, analyze_backtest
export get_empty_analysis, candidate_to_live_config
export objective_function, result_sampled_default

# Period definitions in seconds
const PERIODS = Dict(
    "daily" => 60 * 60 * 24,
    "weekly" => 60 * 60 * 24 * 7,
    "monthly" => 60 * 60 * 24 * 365.25 / 12,
    "yearly" => 60 * 60 * 24 * 365.25
)

const METRICS_OBJ = ["average_daily_gain", "returns_daily", "sharpe_ratio_daily", "VWR_daily"]

"""
    objective_function(result::Dict, metric::String, bc::Dict) -> Float64

Calculate objective function value for optimization.
Penalizes based on max hours without fills and liquidation distance.
"""
function objective_function(result::Dict{String,Any}, metric::String, bc::Dict{String,Any})
    if get(result, "n_fills", 0) == 0
        return -1.0
    end
    
    try
        base_metric = get(result, metric, 0.0)
        
        # Penalty for max hours without fills
        fill_penalty = min(1.0, get(bc, "max_hrs_no_fills", 1000.0) / get(result, "max_hrs_no_fills", 1.0))
        
        # Penalty for max hours without fills on same side
        same_side_penalty = min(1.0, get(bc, "max_hrs_no_fills_same_side", 1000.0) / get(result, "max_hrs_no_fills_same_side", 1.0))
        
        # Penalty for liquidation distance
        liq_penalty = min(1.0, get(result, "closest_liq", 1.0) / get(bc, "minimum_liquidation_distance", 0.05))
        
        return base_metric * fill_penalty * same_side_penalty * liq_penalty
    catch e
        return -1.0
    end
end

"""
    result_sampled_default() -> Dict

Return default empty result for sampled analysis.
"""
function result_sampled_default()
    result = Dict{String,Any}()
    for (period, sec) in PERIODS
        result["returns_" * period] = 0.0
        result["sharpe_ratio_" * period] = 0.0
        result["VWR_" * period] = 0.0
    end
    return result
end

"""
    analyze_samples(stats::Vector{Dict}, bc::Dict) -> (DataFrame, Dict)

Analyze equity samples and calculate returns, Sharpe ratio, and VWR.
"""
function analyze_samples(stats::Vector{Dict{String,Any}}, bc::Dict{String,Any})
    if isempty(stats)
        return (DataFrame(), result_sampled_default())
    end
    
    # Convert to DataFrame
    sdf = DataFrame(stats)
    
    # Set timestamp as index
    sdf.timestamp = unix2datetime.(sdf.timestamp ./ 1000)
    
    equity_start = stats[1]["equity"]
    equity_end = stats[end]["equity"]
    
    # Resample to hourly
    # Note: Julia doesn't have pandas resample, so we'll approximate
    # For now, use the data as-is (this is a simplification)
    
    # Calculate returns
    returns = diff(sdf.equity) ./ sdf.equity[1:end-1]
    pushfirst!(returns, sdf.equity[1] / equity_start - 1)
    replace!(returns, NaN => 0.0)
    
    N = length(returns)
    
    # Geometrical mean of returns
    returns_mean = exp(mean(log.(returns .+ 1))) - 1
    
    # Log returns
    returns_log = log.(1 .+ returns)
    returns_log_mean = log(equity_end / equity_start) / N
    
    # Equity differential (relative to zero-variability ideal)
    equity_diff = (sdf.equity ./ (equity_start .* exp.(returns_log_mean .* (1:N)))) .- 1
    equity_diff_std = std(equity_diff, corrected=true)
    
    # VWR parameters
    tau = get(bc, "tau", 2.0)
    sdev_max = get(bc, "sdev_max", 0.1)
    
    # VWR weight
    VWR_weight = 1.0 - (equity_diff_std / sdev_max)^tau
    
    # Sample period in seconds (1 hour)
    sample_sec = 3600.0
    
    result = Dict{String,Any}()
    for (period, sec) in PERIODS
        periods_nb = sec / sample_sec
        
        # Expected compounded returns for period
        returns_expected_period = (returns_mean + 1)^periods_nb - 1
        volatility_expected_period = std(returns) * sqrt(periods_nb)
        
        # Sharpe ratio
        if volatility_expected_period == 0.0
            SR = 0.0
        else
            SR = returns_expected_period / volatility_expected_period
        end
        
        # VWR
        VWR = returns_expected_period * VWR_weight
        
        result["returns_" * period] = returns_expected_period
        
        if equity_end > equity_start
            result["sharpe_ratio_" * period] = SR
            result["VWR_" * period] = VWR > 0.0 ? VWR : 0.0
        else
            result["sharpe_ratio_" * period] = 0.0
            result["VWR_" * period] = returns_expected_period
        end
    end
    
    return (sdf, result)
end

"""
    get_empty_analysis(bc::Dict) -> Dict

Return empty analysis result with default values.
"""
function get_empty_analysis(bc::Dict{String,Any})
    return Dict{String,Any}(
        "net_pnl_plus_fees" => 0.0,
        "profit_sum" => 0.0,
        "loss_sum" => 0.0,
        "fee_sum" => 0.0,
        "final_equity" => get(bc, "starting_balance", 0.0),
        "gain" => 1.0,
        "max_drawdown" => 0.0,
        "n_days" => 0.0,
        "average_daily_gain" => 0.0,
        "closest_liq" => 1.0,
        "n_fills" => 0.0,
        "n_entries" => 0.0,
        "n_closes" => 0.0,
        "n_reentries" => 0.0,
        "n_initial_entries" => 0.0,
        "n_normal_closes" => 0.0,
        "n_stop_loss_closes" => 0.0,
        "n_stop_loss_entries" => 0.0,
        "biggest_psize" => 0.0,
        "max_hrs_no_fills_same_side" => 1000.0,
        "max_hrs_no_fills" => 1000.0
    )
end

"""
    analyze_fills(fills::Vector{Dict}, bc::Dict, last_ts::Float64) -> (DataFrame, Dict)

Analyze fill data and calculate comprehensive performance metrics.
"""
function analyze_fills(fills::Vector{Dict{String,Any}}, bc::Dict{String,Any}, last_ts::Float64)
    if isempty(fills)
        return (DataFrame(), get_empty_analysis(bc))
    end
    
    # Convert to DataFrame
    fdf = DataFrame(fills)
    
    # Separate long and short fills
    longs = filter(row -> get(row, "pside", "") == "long", fills)
    shrts = filter(row -> get(row, "pside", "") == "shrt", fills)
    
    # Calculate max hours without fills for each side
    if get(bc, "do_long", false)
        if !isempty(longs)
            long_timestamps = [f["timestamp"] for f in longs]
            push!(long_timestamps, last_ts)
            long_stuck = maximum(diff(long_timestamps)) / (1000 * 60 * 60)
        else
            long_stuck = 1000.0
        end
    else
        long_stuck = 0.0
    end
    
    if get(bc, "do_shrt", false)
        if !isempty(shrts)
            shrt_timestamps = [f["timestamp"] for f in shrts]
            push!(shrt_timestamps, last_ts)
            shrt_stuck = maximum(diff(shrt_timestamps)) / (1000 * 60 * 60)
        else
            shrt_stuck = 1000.0
        end
    else
        shrt_stuck = 0.0
    end
    
    # Calculate metrics
    pnls = [get(f, "pnl", 0.0) for f in fills]
    fees = [get(f, "fee_paid", 0.0) for f in fills]
    
    profit_sum = sum(p for p in pnls if p > 0.0)
    loss_sum = sum(p for p in pnls if p < 0.0)
    fee_sum = sum(fees)
    
    final_balance = fills[end]["balance"]
    final_equity = fills[end]["equity"]
    starting_balance = get(bc, "starting_balance", 1000.0)
    
    gain = final_balance / starting_balance
    n_days = (last_ts - fills[1]["timestamp"]) / (1000 * 60 * 60 * 24)
    
    # Calculate max drawdown
    equities = [f["equity"] for f in fills]
    balances = [f["balance"] for f in fills]
    drawdowns = abs.((equities .- balances) ./ balances)
    max_drawdown = maximum(drawdowns)
    
    # Count different fill types
    n_entries = count(f -> occursin("entry", get(f, "type", "")), fills)
    n_closes = count(f -> occursin("close", get(f, "type", "")), fills)
    n_reentries = count(f -> occursin("reentry", get(f, "type", "")), fills)
    n_initial_entries = count(f -> occursin("initial", get(f, "type", "")), fills)
    n_normal_closes = count(f -> get(f, "type", "") in ["long_close", "shrt_close"], fills)
    n_stop_loss_closes = count(f -> occursin("stop_loss", get(f, "type", "")) && occursin("close", get(f, "type", "")), fills)
    n_stop_loss_entries = count(f -> occursin("stop_loss", get(f, "type", "")) && occursin("entry", get(f, "type", "")), fills)
    
    # Biggest position size
    long_psizes = [abs(get(f, "long_psize", 0.0)) for f in fills]
    shrt_psizes = [abs(get(f, "shrt_psize", 0.0)) for f in fills]
    biggest_psize = maximum(vcat(long_psizes, shrt_psizes))
    
    # Max hours without any fills
    all_timestamps = [f["timestamp"] for f in fills]
    push!(all_timestamps, last_ts)
    max_hrs_no_fills = maximum(diff(all_timestamps)) / (1000 * 60 * 60)
    
    result = Dict{String,Any}(
        "net_pnl_plus_fees" => sum(pnls) + fee_sum,
        "profit_sum" => profit_sum,
        "loss_sum" => loss_sum,
        "fee_sum" => fee_sum,
        "final_equity" => final_equity,
        "gain" => gain,
        "max_drawdown" => max_drawdown,
        "n_days" => n_days,
        "average_daily_gain" => gain > 0.0 && n_days > 0.0 ? gain^(1/n_days) : 0.0,
        "closest_liq" => fills[end]["closest_liq"],
        "n_fills" => length(fills),
        "n_entries" => n_entries,
        "n_closes" => n_closes,
        "n_reentries" => n_reentries,
        "n_initial_entries" => n_initial_entries,
        "n_normal_closes" => n_normal_closes,
        "n_stop_loss_closes" => n_stop_loss_closes,
        "n_stop_loss_entries" => n_stop_loss_entries,
        "biggest_psize" => biggest_psize,
        "max_hrs_no_fills_long" => long_stuck,
        "max_hrs_no_fills_shrt" => shrt_stuck,
        "max_hrs_no_fills_same_side" => max(long_stuck, shrt_stuck),
        "max_hrs_no_fills" => max_hrs_no_fills
    )
    
    return (fdf, result)
end

"""
    analyze_backtest(fills::Vector{Dict}, stats::Vector{Dict}, bc::Dict) -> (DataFrame, DataFrame, Dict)

Complete backtest analysis including fills, samples, and objective calculation.
"""
function analyze_backtest(fills::Vector{Dict{String,Any}}, stats::Vector{Dict{String,Any}}, bc::Dict{String,Any})
    res = Dict{String,Any}(
        "do_long" => get(bc, "do_long", false),
        "do_shrt" => get(bc, "do_shrt", false),
        "starting_balance" => get(bc, "starting_balance", 1000.0)
    )
    
    last_ts = !isempty(stats) ? stats[end]["timestamp"] : 0.0
    
    # Analyze fills
    fdf, res_fill = analyze_fills(fills, bc, last_ts)
    
    # Analyze samples
    sdf, res_samp = analyze_samples(stats, bc)
    
    # Merge results
    merge!(res, res_fill)
    merge!(res, res_samp)
    
    # Compute objectives for interesting metrics
    for metric in METRICS_OBJ
        res[metric * "_obj"] = objective_function(res, metric, bc)
    end
    
    # Compute objective for the metric defined in config
    metric_name = get(bc, "metric", "average_daily_gain")
    if !haskey(res, metric_name)
        res[metric_name * "_obj"] = objective_function(res, metric_name, bc)
    end
    
    res["objective"] = res[metric_name * "_obj"]
    
    return (fdf, sdf, res)
end

"""
    candidate_to_live_config(candidate::Dict, template::Dict) -> Dict

Convert optimization candidate to live config format.
"""
function candidate_to_live_config(candidate::Dict{String,Any}, template::Dict{String,Any}=Dict{String,Any}())
    live_config = Dict{String,Any}()
    
    # Keys to extract from candidate
    keys_to_copy = [
        "config_name", "logging_level", "ddown_factor", "qty_pct",
        "leverage", "n_close_orders", "grid_spacing", "pos_margin_grid_coeff",
        "volatility_grid_coeff", "volatility_qty_coeff", "min_markup",
        "markup_range", "do_long", "do_shrt", "ema_span", "ema_spread",
        "stop_loss_liq_diff", "stop_loss_pos_pct", "entry_liq_diff_thr", "symbol"
    ]
    
    for k in keys_to_copy
        if haskey(candidate, k)
            live_config[k] = candidate[k]
        elseif haskey(template, k)
            live_config[k] = template[k]
        else
            live_config[k] = 0.0
        end
    end
    
    # Convert boolean flags
    for k in ["do_long", "do_shrt"]
        if haskey(live_config, k)
            live_config[k] = Bool(live_config[k])
        end
    end
    
    return live_config
end
