# Optimize.jl - Hyperparameter optimization

using Printf
using Statistics
using Dates
using JSON3
using DataFrames
using CSV

# Try to load BlackBoxOptim, but don't fail if not available
const HAS_BLACKBOXOPTIM = try
    import BlackBoxOptim
    true
catch
    false
end

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

export optimize, backtest_tune, save_results
export clean_result_config, iter_slices, simple_sliding_window_wrap

"""
    get_empty_analysis(config::Dict) -> Dict

Returns an empty analysis result dictionary with default values.
"""
function get_empty_analysis(config::Dict)
    return Dict(
        "net_pnl_plus_fees" => 0.0,
        "profit_sum" => 0.0,
        "loss_sum" => 0.0,
        "fee_sum" => 0.0,
        "final_equity" => config["starting_balance"],
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
    objective_function(result::Dict, metric::String, config::Dict) -> Float64

Calculate objective function value for optimization.
Penalizes configurations that violate constraints.
"""
function objective_function(result::Dict, metric::String, config::Dict)
    if result["n_fills"] == 0
        return -1.0
    end
    
    try
        return (
            result[metric] *
            min(1.0, config["max_hrs_no_fills"] / result["max_hrs_no_fills"]) *
            min(1.0, config["max_hrs_no_fills_same_side"] / result["max_hrs_no_fills_same_side"]) *
            min(1.0, result["closest_liq"] / config["minimum_liquidation_distance"])
        )
    catch e
        return -1.0
    end
end

"""
    clean_result_config(config::Dict) -> Dict

Convert numpy types to native Julia types in configuration.
"""
function clean_result_config(config::Dict)
    cleaned = Dict{String, Any}()
    for (k, v) in config
        if v isa Integer
            cleaned[k] = Int(v)
        elseif v isa AbstractFloat
            cleaned[k] = Float64(v)
        else
            cleaned[k] = v
        end
    end
    return cleaned
end

"""
    iter_slices(data::Matrix{Float64}, sliding_window_size::Float64, 
                n_windows::Int, yield_full::Bool=true)

Generate sliding window slices of data for validation.
"""
function iter_slices(data::Matrix{Float64}, sliding_window_size::Float64, 
                     n_windows::Int, yield_full::Bool=true)
    slices = Vector{Matrix{Float64}}()
    n_rows = size(data, 1)
    
    for ix in range(1 - sliding_window_size, 0.0, length=n_windows)
        start_idx = max(1, Int(round(n_rows * ix)))
        end_idx = Int(round(n_rows * (ix + sliding_window_size)))
        push!(slices, data[start_idx:end_idx, :])
    end
    
    if yield_full
        push!(slices, data)
    end
    
    return slices
end

"""
    tanh_penalty(x::Float64) -> Float64

Tanh-based penalty function for optimization.
"""
function tanh_penalty(x::Float64)
    return tanh(10 * (x - 1))
end

"""
    analyze_fills_simple(fills::Vector{Dict}, config::Dict, last_ts::Float64) -> Dict

Simplified fill analysis for optimization.
Returns metrics needed for objective function calculation.
"""
function analyze_fills_simple(fills::Vector{<:Dict}, config::Dict, last_ts::Float64)
    if isempty(fills)
        return get_empty_analysis(config)
    end
    
    # Extract timestamps and position sides
    timestamps = [fill["timestamp"] for fill in fills]
    
    # Calculate max hours without fills
    time_diffs = diff(vcat(timestamps, [last_ts]))
    max_hrs_no_fills = maximum(time_diffs) / (1000 * 60 * 60)
    
    # Calculate max hours without fills per side
    long_fills = filter(f -> f["pside"] == "long", fills)
    shrt_fills = filter(f -> f["pside"] == "shrt", fills)
    
    long_stuck = if config["do_long"]
        if !isempty(long_fills)
            long_ts = [f["timestamp"] for f in long_fills]
            maximum(diff(vcat(long_ts, [last_ts]))) / (1000 * 60 * 60)
        else
            1000.0
        end
    else
        0.0
    end
    
    shrt_stuck = if config["do_shrt"]
        if !isempty(shrt_fills)
            shrt_ts = [f["timestamp"] for f in shrt_fills]
            maximum(diff(vcat(shrt_ts, [last_ts]))) / (1000 * 60 * 60)
        else
            1000.0
        end
    else
        0.0
    end
    
    # Calculate basic metrics
    pnls = [fill["pnl"] for fill in fills]
    fees = [fill["fee_paid"] for fill in fills]
    
    final_balance = fills[end]["balance"]
    final_equity = fills[end]["equity"]
    gain = final_balance / config["starting_balance"]
    
    n_days = (last_ts - fills[1]["timestamp"]) / (1000 * 60 * 60 * 24)
    average_daily_gain = gain > 0.0 && n_days > 0.0 ? gain^(1/n_days) : 0.0
    
    return Dict(
        "net_pnl_plus_fees" => sum(pnls) + sum(fees),
        "profit_sum" => sum(filter(x -> x > 0, pnls)),
        "loss_sum" => sum(filter(x -> x < 0, pnls)),
        "fee_sum" => sum(fees),
        "final_equity" => final_equity,
        "gain" => gain,
        "n_days" => n_days,
        "average_daily_gain" => average_daily_gain,
        "closest_liq" => fills[end]["closest_liq"],
        "n_fills" => Float64(length(fills)),
        "max_hrs_no_fills" => max_hrs_no_fills,
        "max_hrs_no_fills_same_side" => max(long_stuck, shrt_stuck)
    )
end

"""
    simple_sliding_window_wrap(config::Dict, ticks::Matrix{Float64}) -> Dict

Run backtest with sliding window validation and early stopping.
Returns aggregated results across all windows.
"""
function simple_sliding_window_wrap(config::Dict, ticks::Matrix{Float64})
    sliding_window_size = get(config, "sliding_window_size", 0.4)
    n_windows = get(config, "n_sliding_windows", 4)
    test_full = get(config, "test_full", false)
    
    results = Dict[]
    finished_windows = 0.0
    
    for ticks_slice in iter_slices(ticks, sliding_window_size, n_windows, test_full)
        # Run backtest
        try
            fills, stats, did_finish = backtest(config, ticks_slice, false)
            
            # Analyze results
            try
                result = analyze_fills_simple(fills, config, ticks_slice[end, 3])
                push!(results, result)
            catch e
                @warn "Error analyzing fills" exception=e
                push!(results, get_empty_analysis(config))
            end
            
            finished_windows += 1.0
            
            # Early stopping check
            if config["break_early_factor"] > 0.0
                result = results[end]
                should_break = (
                    !did_finish ||
                    result["closest_liq"] < config["minimum_liquidation_distance"] * (1 - config["break_early_factor"]) ||
                    result["max_hrs_no_fills"] > config["max_hrs_no_fills"] * (1 + config["break_early_factor"]) ||
                    result["max_hrs_no_fills_same_side"] > config["max_hrs_no_fills_same_side"] * (1 + config["break_early_factor"])
                )
                
                if should_break
                    break
                end
            end
        catch e
            @warn "Error in backtest" exception=e
            push!(results, get_empty_analysis(config))
        end
    end
    
    # Aggregate results
    if !isempty(results)
        aggregated = Dict{String, Float64}()
        
        for key in keys(results[1])
            if key == "closest_liq"
                aggregated[key] = minimum([r[key] for r in results])
            elseif key == "average_daily_gain"
                denominator = sum([r["n_days"] for r in results])
                if denominator == 0.0
                    aggregated[key] = 1.0
                else
                    aggregated[key] = sum([r[key] * r["n_days"] for r in results]) / denominator
                end
                # Calculate adjusted daily gain with tanh penalty
                aggregated["adjusted_daily_gain"] = (
                    mean([tanh_penalty(r[key]) for r in results]) *
                    finished_windows / n_windows
                )
            elseif occursin("max_hrs_no_fills", key)
                aggregated[key] = maximum([r[key] for r in results])
            else
                aggregated[key] = mean([r[key] for r in results])
            end
        end
        
        return aggregated
    else
        return get_empty_analysis(config)
    end
end

"""
    create_search_space(ranges::Dict) -> Tuple

Create search space bounds for optimization from parameter ranges.
Returns (lower_bounds, upper_bounds, param_names).
"""
function create_search_space(ranges::Dict)
    param_names = String[]
    lower_bounds = Float64[]
    upper_bounds = Float64[]
    
    for (key, value) in sort(collect(ranges))
        if value[1] != value[2]  # Only include parameters with range
            push!(param_names, key)
            push!(lower_bounds, Float64(value[1]))
            push!(upper_bounds, Float64(value[2]))
        end
    end
    
    return (lower_bounds, upper_bounds, param_names)
end

"""
    vector_to_config(x::Vector{Float64}, param_names::Vector{String}, 
                     base_config::Dict, ranges::Dict) -> Dict

Convert optimization vector to configuration dictionary.
"""
function vector_to_config(x::Vector{Float64}, param_names::Vector{String}, 
                          base_config::Dict, ranges::Dict)
    config = copy(base_config)
    
    for (i, name) in enumerate(param_names)
        value = x[i]
        
        # Round integer parameters
        if name in ["n_close_orders", "leverage"]
            config[name] = Int(round(value))
        else
            config[name] = value
        end
    end
    
    # Add fixed parameters from ranges
    for (key, value) in ranges
        if value[1] == value[2]
            config[key] = value[1]
        end
    end
    
    return config
end

"""
    config_to_vector(config::Dict, param_names::Vector{String}) -> Vector{Float64}

Convert configuration dictionary to optimization vector.
"""
function config_to_vector(config::Dict, param_names::Vector{String})
    return [Float64(config[name]) for name in param_names]
end

"""
    backtest_tune(ticks::Matrix{Float64}, backtest_config::Dict; 
                  current_best::Union{Dict, Vector{Dict}, Nothing}=nothing) -> Dict

Run PSO optimization on backtest configuration.

# Arguments
- `ticks::Matrix{Float64}`: Historical tick data
- `backtest_config::Dict`: Backtest configuration with ranges
- `current_best`: Optional starting configuration(s)

# Returns
- Dictionary with optimization results and best configuration
"""
function backtest_tune(ticks::Matrix{Float64}, backtest_config::Dict; 
                       current_best::Union{Dict, Vector{Dict}, Nothing}=nothing)
    
    # Extract optimization parameters
    iters = get(backtest_config, "iters", 10)
    n_particles = get(backtest_config, "n_particles", 10)
    num_cpus = get(backtest_config, "num_cpus", 2)
    
    # PSO parameters (matching Python defaults)
    omega = 0.7298  # Inertia weight
    phi1 = 1.4962   # Cognitive coefficient
    phi2 = 1.4962   # Social coefficient
    
    if haskey(backtest_config, "options")
        omega = get(backtest_config["options"], "w", omega)
        phi1 = get(backtest_config["options"], "c1", phi1)
        phi2 = get(backtest_config["options"], "c2", phi2)
    end
    
    # Create search space
    ranges = backtest_config["ranges"]
    lower_bounds, upper_bounds, param_names = create_search_space(ranges)
    
    println("\n=== Optimization Setup ===")
    println("Parameters to optimize: ", length(param_names))
    println("Iterations: ", iters)
    println("Particles: ", n_particles)
    println("CPUs: ", num_cpus)
    println("PSO params: ω=$omega, φ1=$phi1, φ2=$phi2")
    println("\nParameter ranges:")
    for (i, name) in enumerate(param_names)
        println("  $name: [$(lower_bounds[i]), $(upper_bounds[i])]")
    end
    println()
    
    # Prepare initial population from current_best
    initial_population = Vector{Vector{Float64}}()
    if current_best !== nothing
        candidates = current_best isa Vector ? current_best : [current_best]
        
        for candidate in candidates
            # Clean and validate candidate
            cleaned = Dict{String, Any}()
            for name in param_names
                if haskey(candidate, name)
                    val = candidate[name]
                    # Clamp to bounds
                    idx = findfirst(==(name), param_names)
                    val = clamp(Float64(val), lower_bounds[idx], upper_bounds[idx])
                    cleaned[name] = val
                end
            end
            
            if length(cleaned) == length(param_names)
                push!(initial_population, config_to_vector(cleaned, param_names))
            end
        end
        
        if !isempty(initial_population)
            println("Starting with $(length(initial_population)) candidate configuration(s)")
        end
    end
    
    # Define objective function for optimization
    function objective(x::Vector{Float64})
        config = vector_to_config(x, param_names, backtest_config, ranges)
        result = simple_sliding_window_wrap(config, ticks)
        obj = objective_function(result, "adjusted_daily_gain", backtest_config)
        
        # Store result for later retrieval
        return -obj  # Negative because we minimize
    end
    
    # Run PSO optimization using BlackBoxOptim.jl
    println("Starting PSO optimization...")
    println("=" ^ 60)
    
    # Run optimization using BlackBoxOptim.jl
    println("Starting optimization...")
    println("=" ^ 60)
    
    if HAS_BLACKBOXOPTIM
        opt_result = BlackBoxOptim.bboptimize(objective;
            SearchRange = collect(zip(lower_bounds, upper_bounds)),
            Method = :adaptive_de_rand_1_bin_radiuslimited,
            MaxFuncEvals = iters * n_particles,
            TraceMode = :verbose,
            TraceInterval = 1.0
        )
        
        best_x = BlackBoxOptim.best_candidate(opt_result)
        best_config = vector_to_config(best_x, param_names, backtest_config, ranges)
        best_fitness = -BlackBoxOptim.best_fitness(opt_result)
        
        println("\n" * "=" ^ 60)
        println("Optimization complete!")
        println("Best objective: ", best_fitness)
        println("\nBest configuration:")
        for name in param_names
            println("  $name: ", best_config[name])
        end
        
        return Dict(
            "best_config" => best_config,
            "best_fitness" => best_fitness,
            "optimization_result" => opt_result
        )
    else
        @warn "BlackBoxOptim.jl not available, using simple random search fallback"
        return simple_grid_search(ticks, backtest_config, param_names, 
                                 lower_bounds, upper_bounds, iters)
    end
end

"""
    simple_grid_search(ticks::Matrix{Float64}, backtest_config::Dict,
                       param_names::Vector{String}, lower_bounds::Vector{Float64},
                       upper_bounds::Vector{Float64}, n_samples::Int) -> Dict

Fallback optimization using random search when BlackBoxOptim is not available.
"""
function simple_grid_search(ticks::Matrix{Float64}, backtest_config::Dict,
                            param_names::Vector{String}, lower_bounds::Vector{Float64},
                            upper_bounds::Vector{Float64}, n_samples::Int)
    
    println("Running random search with $n_samples samples...")
    
    best_config = nothing
    best_fitness = -Inf
    all_results = Dict[]
    
    for i in 1:n_samples
        # Generate random configuration
        x = lower_bounds .+ rand(length(param_names)) .* (upper_bounds .- lower_bounds)
        config = vector_to_config(x, param_names, backtest_config, backtest_config["ranges"])
        
        # Evaluate
        result = simple_sliding_window_wrap(config, ticks)
        fitness = objective_function(result, "adjusted_daily_gain", backtest_config)
        
        # Store result
        result_with_config = merge(result, Dict(name => config[name] for name in param_names))
        result_with_config["objective"] = fitness
        push!(all_results, result_with_config)
        
        # Update best
        if fitness > best_fitness
            best_fitness = fitness
            best_config = config
        end
        
        # Progress
        if i % 10 == 0 || i == n_samples
            println("Sample $i/$n_samples - Best fitness: $best_fitness")
        end
    end
    
    return Dict(
        "best_config" => best_config,
        "best_fitness" => best_fitness,
        "all_results" => all_results
    )
end

"""
    save_results(analysis::Dict, backtest_config::Dict)

Save optimization results to CSV file.
"""
function save_results(analysis::Dict, backtest_config::Dict)
    optimize_dirpath = backtest_config["optimize_dirpath"]
    
    # Create directory if it doesn't exist
    mkpath(optimize_dirpath)
    
    # Extract results
    if haskey(analysis, "all_results")
        results = analysis["all_results"]
    else
        # Single result case
        results = [merge(
            analysis["best_config"],
            Dict("objective" => analysis["best_fitness"])
        )]
    end
    
    # Convert to DataFrame
    df = DataFrame(results)
    
    # Sort by objective (descending)
    if "objective" in names(df)
        sort!(df, :objective, rev=true)
    end
    
    # Save to CSV
    output_path = joinpath(optimize_dirpath, "results.csv")
    CSV.write(output_path, df)
    
    println("\nResults saved to: $output_path")
    println("\nBest candidate found:")
    for (k, v) in analysis["best_config"]
        if k in keys(backtest_config["ranges"])
            println("  $k: $v")
        end
    end
    
    return output_path
end

"""
    optimize(backtest_config::Dict; starting_configs::Union{String, Nothing}=nothing) -> Dict

Main optimization entry point.

# Arguments
- `backtest_config::Dict`: Configuration with ranges and optimization parameters
- `starting_configs`: Optional path to starting configuration(s) (file or directory)

# Returns
- Dictionary with optimization results
"""
function optimize(backtest_config::Dict; starting_configs::Union{String, Nothing}=nothing)
    # Load starting configurations if provided
    current_best = nothing
    if starting_configs !== nothing && starting_configs != "none"
        try
            if isdir(starting_configs)
                # Load all JSON files from directory
                json_files = filter(f -> endswith(f, ".json"), readdir(starting_configs, join=true))
                current_best = [JSON3.read(read(f, String), Dict) for f in json_files]
                println("Starting with $(length(current_best)) configurations from directory")
            elseif isfile(starting_configs)
                # Load single file
                current_best = JSON3.read(read(starting_configs, String), Dict)
                println("Starting with configuration from file")
            end
        catch e
            @warn "Could not load starting configurations" exception=e
        end
    end
    
    # Note: In actual usage, ticks would be loaded via Downloader
    # For now, this is a placeholder that expects ticks to be passed separately
    error("optimize() requires ticks data - use backtest_tune() directly with ticks")
end
