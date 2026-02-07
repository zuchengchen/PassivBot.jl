# Core.jl - Core bot logic and trading engine

using Dates
using JSON3
using Statistics
using DataStructures: Deque
import HTTP
import HTTP.WebSockets

# Constants
const MAX_OPEN_ORDERS_LIMIT = 1000
const ORDERS_PER_EXECUTION = 100
const DEFAULT_LAST_PRICE_DIFF_LIMIT = 10
const PRINT_THROTTLE_INTERVAL = 0.5
const CHECK_FILLS_INTERVAL = 120
const CHECK_FILLS_MIN_INTERVAL = 5.0
const DECIDE_TIMEOUT = 5
const LOG_BUFFER_MAX_SIZE = 100
const LOG_FLUSH_INTERVAL = 5.0
const FLUSH_STUCK_LOCKS_MODULO = 100

# Helper functions
# Note: get_keys(), flatten_dict(), sort_dict_keys() are defined in Utils.jl

# Abstract type for all bot implementations
abstract type AbstractBot end

# Bot struct - base class for trading bot

"""
Bot struct - main trading bot with async logic
This is the base type that exchange-specific bots will extend
"""
mutable struct Bot <: AbstractBot
    # Configuration
    config::Dict{String, Any}
    xk::Dict{String, Float64}
    
    # API credentials
    key::String
    secret::String
    
    # Telegram integration
    telegram::Any  # Will be set to Telegram instance or nothing
    
    # EMA parameters
    ema_span::Int
    ema_alpha::Float64
    ema_alpha_::Float64
    
    # Timestamps for rate limiting
    ts_locked::Dict{String, Float64}
    ts_released::Dict{String, Float64}
    
    # Trading state
    position::Dict{String, Any}
    open_orders::Vector{Dict{String, Any}}
    fills::Vector{Dict{String, Any}}
    
    # Price tracking
    highest_bid::Float64
    lowest_ask::Float64
    price::Float64
    is_buyer_maker::Bool
    agg_qty::Float64
    qty::Float64
    ob::Vector{Float64}  # [bid, ask]
    ema::Float64
    
    # Volatility tracking
    tick_prices_deque::Deque{Float64}
    sum_prices::Float64
    sum_prices_squared::Float64
    price_std::Float64
    volatility::Float64
    
    # Order limits
    n_open_orders_limit::Int
    n_orders_per_execution::Int
    
    # Exchange settings
    hedge_mode::Bool
    contract_multiplier::Float64
    
    # Logging
    log_filepath::String
    log_level::Int
    log_buffer::Vector{String}
    log_buffer_max_size::Int
    log_last_flush::Float64
    log_flush_interval::Float64
    
    # WebSocket control
    stop_websocket::Bool
    new_symbol::Union{String, Nothing}
    process_websocket_ticks::Bool
    
    # Constructor
    function Bot(config::Dict{String, Any})
        bot = new()
        
        bot.config = config
        bot.telegram = nothing
        bot.xk = Dict{String, Float64}()
        
        # Set configuration
        set_config!(bot, config)
        
        # Initialize EMA parameters
        bot.ema_span = Int(round(bot.config["ema_span"]))
        bot.ema_alpha = 2 / (bot.ema_span + 1)
        bot.ema_alpha_ = 1 - bot.ema_alpha
        
        # Initialize timestamps
        bot.ts_locked = Dict{String, Float64}(
            "cancel_orders" => 0.0,
            "decide" => 0.0,
            "update_open_orders" => 0.0,
            "update_position" => 0.0,
            "print" => 0.0,
            "create_orders" => 0.0,
            "check_fills" => 0.0,
        )
        bot.ts_released = Dict{String, Float64}(k => 1.0 for k in keys(bot.ts_locked))
        
        # Initialize trading state
        bot.position = Dict{String, Any}()
        bot.open_orders = Vector{Dict{String, Any}}()
        bot.fills = Vector{Dict{String, Any}}()
        bot.highest_bid = 0.0
        bot.lowest_ask = 9.9e9
        bot.price = 0.0
        bot.is_buyer_maker = true
        bot.agg_qty = 0.0
        bot.qty = 0.0
        bot.ob = [0.0, 0.0]
        bot.ema = 0.0
        
        # Initialize volatility tracking
        bot.tick_prices_deque = Deque{Float64}()
        bot.sum_prices = 0.0
        bot.sum_prices_squared = 0.0
        bot.price_std = 0.0
        bot.volatility = 0.0
        
        # Order limits
        bot.n_open_orders_limit = MAX_OPEN_ORDERS_LIMIT
        bot.n_orders_per_execution = ORDERS_PER_EXECUTION
        
        # Exchange settings
        bot.hedge_mode = true
        bot.contract_multiplier = 1.0
        bot.config["contract_multiplier"] = 1.0
        
        # Logging
        exchange = get(config, "exchange", "unknown")
        config_name = get(config, "config_name", "default")
        bot.log_filepath = make_get_filepath("logs/$exchange/$config_name.log")
        
        # Load API keys
        user = get(config, "user", "")
        bot.key, bot.secret = load_key_secret(exchange, user)
        
        bot.log_level = 0
        bot.log_buffer = String[]
        bot.log_buffer_max_size = LOG_BUFFER_MAX_SIZE
        bot.log_last_flush = time()
        bot.log_flush_interval = LOG_FLUSH_INTERVAL
        
        # WebSocket control
        bot.stop_websocket = false
        bot.new_symbol = nothing
        bot.process_websocket_ticks = true
        
        return bot
    end
end

# Configuration management methods

"""
Set configuration and update bot attributes
"""
function set_config!(bot::AbstractBot, config::Dict{String, Any})
    # Set defaults
    config["ema_span"] = Int(round(get(config, "ema_span", 20)))
    
    if !haskey(config, "stop_mode")
        config["stop_mode"] = nothing
    end
    
    if !haskey(config, "entry_liq_diff_thr")
        config["entry_liq_diff_thr"] = get(config, "stop_loss_liq_diff", 0.1)
    end
    
    if !haskey(config, "last_price_diff_limit")
        config["last_price_diff_limit"] = DEFAULT_LAST_PRICE_DIFF_LIMIT
    end
    
    if !haskey(config, "profit_trans_pct")
        config["profit_trans_pct"] = 0.0
    end
    
    bot.config = config
    
    # Set attributes from config
    for (key, value) in config
        setfield!(bot, Symbol(key), value)
    end
    
    # Update xk if keys exist
    for key in keys(bot.xk)
        if haskey(config, key)
            bot.xk[key] = Float64(config[key])
        end
    end
end

"""
Set a single configuration value
"""
function set_config_value!(bot::AbstractBot, key::String, value)
    bot.config[key] = value
    setfield!(bot, Symbol(key), bot.config[key])
end

# Initialization and logging methods

"""
Async initialization - fetch fills and set up xk
"""
function init!(bot::AbstractBot)
    bot.xk = Dict{String, Float64}(
        k => Float64(bot.config[k]) for k in get_keys()
    )
    # Fetch initial fills so first check_fills doesn't treat all as new
    try
        bot.fills = fetch_fills(bot)
    catch e
        @error "Error fetching initial fills" exception=(e, catch_backtrace())
        bot.fills = Vector{Dict{String,Any}}()
    end
end

"""
Dump log entry to buffer
"""
function dump_log!(bot::AbstractBot, data::Dict{String, Any})
    if get(bot.config, "logging_level", 0) > 0
        log_entry = merge(Dict("log_timestamp" => time()), data)
        push!(bot.log_buffer, JSON3.write(log_entry))
        
        if length(bot.log_buffer) >= bot.log_buffer_max_size ||
           time() - bot.log_last_flush >= bot.log_flush_interval
            flush_log_buffer!(bot)
        end
    end
end

"""
Flush log buffer to file
"""
function flush_log_buffer!(bot::AbstractBot)
    if !isempty(bot.log_buffer)
        try
            open(bot.log_filepath, "a") do f
                write(f, join(bot.log_buffer, "\n") * "\n")
            end
            empty!(bot.log_buffer)
        catch e
            @error "Error flushing log buffer" exception=e
        end
        bot.log_last_flush = time()
    end
end

# Order management methods

"""
Update open orders from exchange
"""
function update_open_orders!(bot::AbstractBot)
    if bot.ts_locked["update_open_orders"] > bot.ts_released["update_open_orders"]
        return
    end
    bot.ts_locked["update_open_orders"] = time()
    try
        # Note: fetch_open_orders will be implemented in exchange-specific subtype
        open_orders = fetch_open_orders(bot)
        
        bot.highest_bid = 0.0
        bot.lowest_ask = 9.9e9
        
        for o in open_orders
            if o["side"] == "buy"
                bot.highest_bid = max(bot.highest_bid, o["price"])
            elseif o["side"] == "sell"
                bot.lowest_ask = min(bot.lowest_ask, o["price"])
            end
        end
        
        if bot.open_orders != open_orders
            dump_log!(bot, Dict("log_type" => "open_orders", "data" => open_orders))
        end
        
        bot.open_orders = open_orders
        bot.ts_released["update_open_orders"] = time()
    catch e
        @error "Error with update open orders" exception=e
    end
end

"""
Update position from exchange
Also updates open orders
"""
function update_position!(bot::AbstractBot)
    if bot.ts_locked["update_position"] > bot.ts_released["update_position"]
        return
    end
    bot.ts_locked["update_position"] = time()
    try
        # Note: fetch_position will be implemented in exchange-specific subtype
        # Fetch position and update orders concurrently
        position = fetch_position(bot)
        update_open_orders!(bot)
        
        # Calculate used margin
        long_cost = if haskey(position, "long") && position["long"]["price"] > 0
            Jitted.calc_cost(position["long"]["size"], position["long"]["price"])
        else
            0.0
        end
        
        shrt_cost = if haskey(position, "shrt") && position["shrt"]["price"] > 0
            Jitted.calc_cost(position["shrt"]["size"], position["shrt"]["price"])
        else
            0.0
        end
        
        position["used_margin"] = (long_cost + shrt_cost) / bot.config["leverage"]
        position["available_margin"] = (position["equity"] - position["used_margin"]) * 0.9
        
        # Debug logging for margin calculation
        if position["available_margin"] <= 0.0
            print_([
                "⚠️  Low/Zero available margin detected!",
                "Wallet Balance: $(round(position["wallet_balance"], digits=2)) USDT,",
                "Equity: $(round(position["equity"], digits=2)) USDT,",
                "Used Margin: $(round(position["used_margin"], digits=2)) USDT,",
                "Available Margin: $(round(position["available_margin"], digits=2)) USDT"
            ], n=true)
        end
        
        if haskey(position, "long") && bot.price > 0.0
            position["long"]["liq_diff"] = Jitted.calc_diff(
                position["long"]["liquidation_price"],
                bot.price
            )
        else
            if haskey(position, "long")
                position["long"]["liq_diff"] = 0.0
            end
        end
        
        if haskey(position, "shrt") && bot.price > 0.0
            position["shrt"]["liq_diff"] = Jitted.calc_diff(
                position["shrt"]["liquidation_price"],
                bot.price
            )
        else
            if haskey(position, "shrt")
                position["shrt"]["liq_diff"] = 0.0
            end
        end
        
        if bot.position != position
            dump_log!(bot, Dict("log_type" => "position", "data" => position))
        end
        
        bot.position = position
        bot.ts_released["update_position"] = time()
    catch e
        @error "Error with update position" exception=e
        # Print stack trace for debugging
        println("Stack trace:")
        for (exc, bt) in Base.catch_stack()
            showerror(stdout, exc, bt)
            println()
        end
        
        # Ensure bot.position has minimal required fields even on error
        if !haskey(bot.position, "available_margin")
            bot.position["available_margin"] = 0.0
            bot.position["wallet_balance"] = 0.0
            bot.position["equity"] = 0.0
            bot.position["used_margin"] = 0.0
        end
    end
end

"""
Create orders on exchange
"""
function create_orders!(bot::AbstractBot, orders_to_create::Vector)
    if isempty(orders_to_create)
        return []
    end
    if bot.ts_locked["create_orders"] > bot.ts_released["create_orders"]
        return []
    end
    bot.ts_locked["create_orders"] = time()
    # Sort by quantity
    sorted_orders = sort(orders_to_create, by=x -> x["qty"])
    
    # Filter orders based on available margin (only for non-reduce_only orders)
    # reduce_only orders (close/take-profit) don't require additional margin
    available_margin = get(bot.position, "available_margin", 0.0)
    leverage = bot.config["leverage"]
    
    filtered_orders = []
    cumulative_margin_needed = 0.0
    total_margin_needed = 0.0
    skipped_orders = 0
    
    for oc in sorted_orders
        is_reduce_only = get(oc, "reduce_only", false)
        
        if is_reduce_only
            # Close orders (reduce_only=true) don't need margin check
            # They reduce position, not increase it
            push!(filtered_orders, oc)
        else
            # Entry orders need margin check
            order_cost = Jitted.calc_cost(oc["qty"], oc["price"])
            order_margin = order_cost / leverage
            total_margin_needed += order_margin
            
            # Check if we have enough margin for this order
            if cumulative_margin_needed + order_margin <= available_margin
                push!(filtered_orders, oc)
                cumulative_margin_needed += order_margin
            else
                skipped_orders += 1
            end
        end
    end
    
    if skipped_orders > 0
        print_([
            "⚠️  Skipped $skipped_orders entry orders due to insufficient margin.",
            "Available: $(round(available_margin, digits=2)) USDT,",
            "Total needed: $(round(total_margin_needed, digits=2)) USDT,",
            "Placed: $(length(filtered_orders)) orders using $(round(cumulative_margin_needed, digits=2)) USDT"
        ], n=true)
    end
    
    # Create tasks for concurrent execution
    creations = []
    for oc in filtered_orders
        try
            # Note: execute_order will be implemented in exchange-specific subtype
            task = @async execute_order(bot, oc)
            push!(creations, (oc, task))
        catch e
            print_(["error creating order a", oc, e], n=true)
        end
    end
    
    created_orders = []
    for (oc, task) in creations
        try
            o = fetch(task)
            push!(created_orders, o)
            
            if haskey(o, "side")
                print_([
                    "  created order",
                    o["symbol"],
                    o["side"],
                    o["position_side"],
                    o["qty"],
                    o["price"]
                ], n=true)
            else
                print_(["error creating order b", o, oc], n=true)
            end
            
            dump_log!(bot, Dict("log_type" => "create_order", "data" => o))
        catch e
            # Extract underlying exception from TaskFailedException
            actual_error = e isa TaskFailedException ? task.exception : e
            error_msg = sprint(showerror, actual_error)
            
            print_(["error creating order c", oc, actual_error], n=true)
            println("  Error details: ", error_msg)
            
            dump_log!(bot, Dict(
                "log_type" => "create_order",
                "data" => Dict(
                    "result" => string(actual_error),
                    "error" => error_msg,
                    "error_type" => string(typeof(actual_error)),
                    "data" => oc
                )
            ))
        end
    end
    
    bot.ts_released["create_orders"] = time()
    return created_orders
end

"""
Cancel orders on exchange
"""
function cancel_orders!(bot::AbstractBot, orders_to_cancel::Vector)
    if isempty(orders_to_cancel)
        return []
    end
    if bot.ts_locked["cancel_orders"] > bot.ts_released["cancel_orders"]
        return []
    end
    bot.ts_locked["cancel_orders"] = time()
    # Create tasks for concurrent execution
    deletions = []
    for oc in orders_to_cancel
        try
            # Note: execute_cancellation will be implemented in exchange-specific subtype
            task = @async execute_cancellation(bot, oc)
            push!(deletions, (oc, task))
        catch e
            print_(["error cancelling order a", oc, e])
        end
    end
    
    canceled_orders = []
    for (oc, task) in deletions
        try
            o = fetch(task)
            push!(canceled_orders, o)
            
            if haskey(o, "side")
                print_([
                    "cancelled order",
                    o["symbol"],
                    o["side"],
                    o["position_side"],
                    o["qty"],
                    o["price"]
                ], n=true)
            else
                print_(["error cancelling order", o], n=true)
            end
            
            dump_log!(bot, Dict("log_type" => "cancel_order", "data" => o))
        catch e
            # Extract underlying exception from TaskFailedException
            actual_error = e isa TaskFailedException ? task.exception : e
            error_msg = sprint(showerror, actual_error)
            
            print_(["error cancelling order b", oc, actual_error], n=true)
            println("  Error details: ", error_msg)
            
            dump_log!(bot, Dict(
                "log_type" => "cancel_order",
                "data" => Dict(
                    "result" => string(actual_error),
                    "error" => error_msg,
                    "error_type" => string(typeof(actual_error)),
                    "data" => oc
                )
            ))
        end
    end
    
    bot.ts_released["cancel_orders"] = time()
    return canceled_orders
end

"""
Stop bot gracefully
"""
function stop!(bot::AbstractBot)
    println("\nStopping passivbot, please wait...")
    try
        bot.stop_websocket = true
        if bot.telegram !== nothing
            # telegram.exit() - will be implemented
        else
            println("No telegram active")
        end
    catch e
        @error "An error occurred during shutdown" exception=e
    end
end

"""
Pause processing websocket ticks
"""
function pause!(bot::AbstractBot)
    bot.process_websocket_ticks = false
end

"""
Resume processing websocket ticks
"""
function resume!(bot::AbstractBot)
    bot.process_websocket_ticks = true
end

# Position management and decision logic

"""
Calculate ideal orders based on current position and market conditions
"""
function calc_orders(bot::AbstractBot)
    balance = bot.position["wallet_balance"]
    long_psize = bot.position["long"]["size"]
    long_pprice = bot.position["long"]["price"]
    shrt_psize = bot.position["shrt"]["size"]
    shrt_pprice = bot.position["shrt"]["price"]
    
    if bot.hedge_mode
        do_long = bot.config["do_long"] || long_psize != 0.0
        do_shrt = bot.config["do_shrt"] || shrt_psize != 0.0
    else
        no_pos = long_psize == 0.0 && shrt_psize == 0.0
        do_long = (no_pos && bot.config["do_long"]) || long_psize != 0.0
        do_shrt = (no_pos && bot.config["do_shrt"]) || shrt_psize != 0.0
    end
    
    bot.xk["do_long"] = do_long
    bot.xk["do_shrt"] = do_shrt
    
    liq_price = if long_psize > abs(shrt_psize)
        bot.position["long"]["liquidation_price"]
    else
        bot.position["shrt"]["liquidation_price"]
    end
    
    # Handle panic mode
    if get(bot.config, "stop_mode", nothing) == "panic"
        panic_orders = []
        
        if long_psize != 0.0
            push!(panic_orders, Dict(
                "side" => "sell",
                "position_side" => "long",
                "qty" => abs(long_psize),
                "price" => bot.ob[2],
                "type" => "market",
                "reduce_only" => true,
                "custom_id" => "long_panic"
            ))
        end
        
        if shrt_psize != 0.0
            push!(panic_orders, Dict(
                "side" => "buy",
                "position_side" => "shrt",
                "qty" => abs(shrt_psize),
                "price" => bot.ob[1],
                "type" => "market",
                "reduce_only" => true,
                "custom_id" => "shrt_panic"
            ))
        end
        
        return panic_orders
    end
    
    long_entry_orders = []
    shrt_entry_orders = []
    long_close_orders = []
    shrt_close_orders = []
    stop_loss_close = false
    
    # Generate entry orders using Jitted functions
    for tpl in Jitted.iter_entries(
        balance,
        long_psize,
        long_pprice,
        shrt_psize,
        shrt_pprice,
        liq_price,
        bot.ob[1],
        bot.ob[2],
        bot.ema,
        bot.price,
        bot.volatility,
        Bool(bot.xk["do_long"]),
        Bool(bot.xk["do_shrt"]),
        bot.xk["qty_step"],
        bot.xk["price_step"],
        bot.xk["min_qty"],
        bot.xk["min_cost"],
        bot.xk["ddown_factor"],
        bot.xk["qty_pct"],
        bot.xk["leverage"],
        bot.xk["n_close_orders"],
        bot.xk["grid_spacing"],
        bot.xk["pos_margin_grid_coeff"],
        bot.xk["volatility_grid_coeff"],
        bot.xk["volatility_qty_coeff"],
        bot.xk["min_markup"],
        bot.xk["markup_range"],
        bot.xk["ema_span"],
        bot.xk["ema_spread"],
        bot.xk["stop_loss_liq_diff"],
        bot.xk["stop_loss_pos_pct"],
        bot.xk["entry_liq_diff_thr"]
    )
        if (length(long_entry_orders) >= bot.n_open_orders_limit &&
            length(shrt_entry_orders) >= bot.n_open_orders_limit) ||
           (Jitted.calc_diff(tpl[2], bot.price) > bot.config["last_price_diff_limit"])
            break
        elseif tpl[5] == "stop_loss_shrt_close"
            push!(shrt_close_orders, Dict(
                "side" => "buy",
                "position_side" => "shrt",
                "qty" => abs(tpl[1]),
                "price" => tpl[2],
                "type" => "limit",
                "reduce_only" => true,
                "custom_id" => tpl[5]
            ))
            shrt_psize = tpl[3]
            stop_loss_close = true
        elseif tpl[5] == "stop_loss_long_close"
            push!(long_close_orders, Dict(
                "side" => "sell",
                "position_side" => "long",
                "qty" => abs(tpl[1]),
                "price" => tpl[2],
                "type" => "limit",
                "reduce_only" => true,
                "custom_id" => tpl[5]
            ))
            long_psize = tpl[3]
            stop_loss_close = true
        elseif tpl[1] == 0.0 || get(bot.config, "stop_mode", nothing) == "freeze"
            continue
        elseif tpl[1] > 0.0
            push!(long_entry_orders, Dict(
                "side" => "buy",
                "position_side" => "long",
                "qty" => tpl[1],
                "price" => tpl[2],
                "type" => "limit",
                "reduce_only" => false,
                "custom_id" => tpl[5]
            ))
        else
            push!(shrt_entry_orders, Dict(
                "side" => "sell",
                "position_side" => "shrt",
                "qty" => abs(tpl[1]),
                "price" => tpl[2],
                "type" => "limit",
                "reduce_only" => false,
                "custom_id" => tpl[5]
            ))
        end
    end
    
    # Generate long close orders
    try
    for (ask_qty, ask_price, _) in Jitted.iter_long_closes(
        balance, long_psize, long_pprice, bot.ob[2],
        Bool(bot.xk["do_long"]),
        Bool(bot.xk["do_shrt"]),
        bot.xk["qty_step"],
        bot.xk["price_step"],
        bot.xk["min_qty"],
        bot.xk["min_cost"],
        bot.xk["ddown_factor"],
        bot.xk["qty_pct"],
        bot.xk["leverage"],
        bot.xk["n_close_orders"],
        bot.xk["grid_spacing"],
        bot.xk["pos_margin_grid_coeff"],
        bot.xk["volatility_grid_coeff"],
        bot.xk["volatility_qty_coeff"],
        bot.xk["min_markup"],
        bot.xk["markup_range"],
        bot.xk["ema_span"],
        bot.xk["ema_spread"],
        bot.xk["stop_loss_liq_diff"],
        bot.xk["stop_loss_pos_pct"],
        bot.xk["entry_liq_diff_thr"]
    )
        if length(long_close_orders) >= bot.n_open_orders_limit ||
           Jitted.calc_diff(ask_price, bot.price) > bot.config["last_price_diff_limit"] ||
           stop_loss_close
            break
        end
        
        push!(long_close_orders, Dict(
            "side" => "sell",
            "position_side" => "long",
            "qty" => abs(ask_qty),
            "price" => Float64(ask_price),
            "type" => "limit",
            "reduce_only" => true,
            "custom_id" => "close"
        ))
    end
    catch e
        @warn "Error in iter_long_closes" exception=(e, catch_backtrace())
    end
    
    # Generate short close orders
    try
    for (bid_qty, bid_price, _) in Jitted.iter_shrt_closes(
        balance, shrt_psize, shrt_pprice, bot.ob[1],
        Bool(bot.xk["do_long"]),
        Bool(bot.xk["do_shrt"]),
        bot.xk["qty_step"],
        bot.xk["price_step"],
        bot.xk["min_qty"],
        bot.xk["min_cost"],
        bot.xk["ddown_factor"],
        bot.xk["qty_pct"],
        bot.xk["leverage"],
        bot.xk["n_close_orders"],
        bot.xk["grid_spacing"],
        bot.xk["pos_margin_grid_coeff"],
        bot.xk["volatility_grid_coeff"],
        bot.xk["volatility_qty_coeff"],
        bot.xk["min_markup"],
        bot.xk["markup_range"],
        bot.xk["ema_span"],
        bot.xk["ema_spread"],
        bot.xk["stop_loss_liq_diff"],
        bot.xk["stop_loss_pos_pct"],
        bot.xk["entry_liq_diff_thr"]
    )
        if length(shrt_close_orders) >= bot.n_open_orders_limit ||
           Jitted.calc_diff(bid_price, bot.price) > bot.config["last_price_diff_limit"] ||
           stop_loss_close
            break
        end
        
        push!(shrt_close_orders, Dict(
            "side" => "buy",
            "position_side" => "shrt",
            "qty" => abs(bid_qty),
            "price" => Float64(bid_price),
            "type" => "limit",
            "reduce_only" => true,
            "custom_id" => "close"
        ))
    end
    catch e
        @warn "Error in iter_shrt_closes" exception=(e, catch_backtrace())
    end
    
    return vcat(long_entry_orders, shrt_entry_orders, long_close_orders, shrt_close_orders)
end

"""
Cancel and create orders to synchronize with ideal state
"""
function cancel_and_create!(bot::AbstractBot)
    sleep(0.005)
    update_position!(bot)
    sleep(0.005)
    
    # Check if any non-decide lock is stuck (matching Python)
    if any(bot.ts_locked[k] > bot.ts_released[k] for k in keys(bot.ts_locked) if k != "decide")
        return []
    end
    
    try
        ideal_orders = calc_orders(bot)
        
        to_cancel, to_create = filter_orders(
            bot.open_orders,
            ideal_orders,
        keys=["side", "position_side", "qty", "price"]
    )
    
    # Sort by price difference from current price
    to_cancel = sort(to_cancel, by=x -> Jitted.calc_diff(x["price"], bot.price))
    to_create = sort(to_create, by=x -> Jitted.calc_diff(x["price"], bot.price))
    
    results = []
    
    if get(bot.config, "stop_mode", nothing) != "manual"
        if !isempty(to_cancel)
            # Cancel orders asynchronously
            task = @async try
                cancel_orders!(bot, to_cancel[1:min(bot.n_orders_per_execution, length(to_cancel))])
            catch e
                @error "Error in async cancel_orders!" exception=(e, catch_backtrace())
            end
            push!(results, task)
            sleep(0.005)  # Sleep 5ms between cancellations and creations
        end
        
        if !isempty(to_create)
            created = create_orders!(bot, to_create[1:min(bot.n_orders_per_execution, length(to_create))])
            push!(results, created)
        end
    end
    
    # Wait for async cancel task to complete
    for r in results
        if r isa Task
            try
                fetch(r)
            catch e
                @error "Error fetching cancel task result" exception=(e, catch_backtrace())
            end
        end
    end
    
    sleep(0.005)
    update_position!(bot)
    
    if !isempty(results)
        println()
    end
    
    return results
    catch e
        @error "Error in cancel_and_create!" exception=(e, catch_backtrace())
        return []
    end
end

"""
Main decision function - creates and cancels orders
Matches Python decide() flow: called on every tick, timeout check is internal.
"""
function decide!(bot::AbstractBot)
    if get(bot.config, "stop_mode", nothing) !== nothing
        println("$(bot.config["stop_mode"]) stop mode is active")
    end
    
    # Check if bid might have been taken
    if bot.price <= bot.highest_bid
        bot.ts_locked["decide"] = time()
        print_(["bid maybe taken"], n=true)
        cancel_and_create!(bot)
        @async try
            check_fills!(bot)
        catch e
            @error "Error in async check_fills!" exception=(e, catch_backtrace())
        end
        bot.ts_released["decide"] = time()
        return
    end
    
    # Check if ask might have been taken
    if bot.price >= bot.lowest_ask
        bot.ts_locked["decide"] = time()
        print_(["ask maybe taken"], n=true)
        cancel_and_create!(bot)
        @async try
            check_fills!(bot)
        catch e
            @error "Error in async check_fills!" exception=(e, catch_backtrace())
        end
        bot.ts_released["decide"] = time()
        return
    end
    
    # Periodic update based on timeout (matching Python branch 3)
    if time() - bot.ts_locked["decide"] > DECIDE_TIMEOUT
        bot.ts_locked["decide"] = time()
        cancel_and_create!(bot)
        bot.ts_released["decide"] = time()
        return
    end
    
    # Print status (fall-through path — no cancel_and_create, matching Python branch 4)
    if time() - bot.ts_released["print"] >= PRINT_THROTTLE_INTERVAL
        update_output_information!(bot)
    end
    
    # Periodic fill check
    if time() - bot.ts_released["check_fills"] > CHECK_FILLS_INTERVAL
        @async try
            check_fills!(bot)
        catch e
            @error "Error in async check_fills!" exception=(e, catch_backtrace())
        end
    end
end

# Fill detection methods

"""
Check for new fills and process them
"""
function check_fills!(bot::AbstractBot)
    # Lock guard: prevent re-entrant calls
    if bot.ts_locked["check_fills"] > bot.ts_released["check_fills"]
        return
    end
    now = time()
    # Min interval guard
    if now - bot.ts_released["check_fills"] < CHECK_FILLS_MIN_INTERVAL
        return
    end
    bot.ts_locked["check_fills"] = now
    print_(["checking if new fills...\n"], n=true)
    
    fills = fetch_fills(bot)
    
    if bot.fills != fills
        check_long_fills!(bot, fills)
        check_shrt_fills!(bot, fills)
    end
    
    bot.fills = fills
    bot.ts_released["check_fills"] = time()
end

"""
Check for new short fills (closes and entries)
"""
function check_shrt_fills!(bot::AbstractBot, fills::Vector)
    # Check for new short close orders
    new_shrt_closes = [
        item for item in fills
        if !(item in bot.fills) &&
           item["side"] == "buy" &&
           item["position_side"] == "shrt"
    ]
    
    if length(new_shrt_closes) > 0
        realized_pnl_shrt = sum(fill["realized_pnl"] for fill in new_shrt_closes)
        
        if bot.telegram !== nothing
            qty_sum = sum(fill["qty"] for fill in new_shrt_closes)
            cost = sum(fill["qty"] * fill["price"] for fill in new_shrt_closes)
            vwap = cost / qty_sum  # Volume weighted average price
            fee = sum(fill["fee_paid"] for fill in new_shrt_closes)
            total_size = bot.position["shrt"]["size"]
            
            # telegram.notify_close_order_filled(...) - will be implemented
            notify_close_order_filled(bot.telegram,
                realized_pnl=realized_pnl_shrt,
                position_side="shrt",
                qty=qty_sum,
                fee=fee,
                wallet_balance=get(bot.position, "wallet_balance", 0.0),
                remaining_size=total_size,
                price=vwap)
        end
        
        # Handle profit transfer if enabled
        if realized_pnl_shrt >= 0 && get(bot.config, "profit_trans_pct", 0.0) > 0.0
            amount = realized_pnl_shrt * bot.config["profit_trans_pct"]
            transfer(bot, type_="UMFUTURE_MAIN", amount=amount)
        end
    end
    
    # Check for new short entry orders
    new_shrt_entries = [
        item for item in fills
        if !(item in bot.fills) &&
           item["side"] == "sell" &&
           item["position_side"] == "shrt"
    ]
    
    if length(new_shrt_entries) > 0
        if bot.telegram !== nothing
            qty_sum = sum(fill["qty"] for fill in new_shrt_entries)
            cost = sum(fill["qty"] * fill["price"] for fill in new_shrt_entries)
            vwap = cost / qty_sum
            fee = sum(fill["fee_paid"] for fill in new_shrt_entries)
            total_size = bot.position["shrt"]["size"]
            
            # telegram.notify_entry_order_filled(...) - will be implemented
            notify_entry_order_filled(bot.telegram,
                position_side="shrt",
                qty=qty_sum,
                fee=fee,
                price=vwap,
                total_size=total_size)
        end
    end
end

"""
Check for new long fills (closes and entries)
"""
function check_long_fills!(bot::AbstractBot, fills::Vector)
    # Check for new long close orders
    new_long_closes = [
        item for item in fills
        if !(item in bot.fills) &&
           item["side"] == "sell" &&
           item["position_side"] == "long"
    ]
    
    if length(new_long_closes) > 0
        realized_pnl_long = sum(fill["realized_pnl"] for fill in new_long_closes)
        
        if bot.telegram !== nothing
            qty_sum = sum(fill["qty"] for fill in new_long_closes)
            cost = sum(fill["qty"] * fill["price"] for fill in new_long_closes)
            vwap = cost / qty_sum  # Volume weighted average price
            fee = sum(fill["fee_paid"] for fill in new_long_closes)
            total_size = bot.position["long"]["size"]
            
            # telegram.notify_close_order_filled(...) - will be implemented
            notify_close_order_filled(bot.telegram,
                realized_pnl=realized_pnl_long,
                position_side="long",
                qty=qty_sum,
                fee=fee,
                wallet_balance=get(bot.position, "wallet_balance", 0.0),
                remaining_size=total_size,
                price=vwap)
        end
        
        # Handle profit transfer if enabled
        if realized_pnl_long >= 0 && get(bot.config, "profit_trans_pct", 0.0) > 0.0
            amount = realized_pnl_long * bot.config["profit_trans_pct"]
            transfer(bot, type_="UMFUTURE_MAIN", amount=amount)
        end
    end
    
    # Check for new long entry orders
    new_long_entries = [
        item for item in fills
        if !(item in bot.fills) &&
           item["side"] == "buy" &&
           item["position_side"] == "long"
    ]
    
    if length(new_long_entries) > 0
        if bot.telegram !== nothing
            qty_sum = sum(fill["qty"] for fill in new_long_entries)
            cost = sum(fill["qty"] * fill["price"] for fill in new_long_entries)
            vwap = cost / qty_sum
            fee = sum(fill["fee_paid"] for fill in new_long_entries)
            total_size = bot.position["long"]["size"]
            
            # telegram.notify_entry_order_filled(...) - will be implemented
            notify_entry_order_filled(bot.telegram,
                position_side="long",
                qty=qty_sum,
                fee=fee,
                price=vwap,
                total_size=total_size)
        end
    end
end

# Indicator methods

"""
Fetch compressed ticks for initialization
"""
function fetch_compressed_ticks!(bot::AbstractBot)
    function drop_consecutive_same_prices(ticks_)
        if isempty(ticks_)
            return ticks_
        end
        
        compressed_ = [ticks_[1]]
        for i in 2:length(ticks_)
            if ticks_[i]["price"] != compressed_[end]["price"] ||
               ticks_[i]["is_buyer_maker"] != compressed_[end]["is_buyer_maker"]
                push!(compressed_, ticks_[i])
            end
        end
        return compressed_
    end
    
    # Note: fetch_ticks will be implemented in exchange-specific subtype
    ticks_unabridged = fetch_ticks(bot, do_print=false)
    ticks_per_fetch = length(ticks_unabridged)
    ticks = drop_consecutive_same_prices(ticks_unabridged)
    delay_between_fetches = 0.55
    
    println()
    while true
        print("\rfetching ticks... $(length(ticks)) of $(bot.ema_span) ")
        sts = time()
        
        new_ticks = fetch_ticks(bot, from_id=ticks[1]["trade_id"] - ticks_per_fetch, do_print=false)
        wait_for = max(0.0, delay_between_fetches - (time() - sts))
        
        ticks = drop_consecutive_same_prices(
            sort(vcat(new_ticks, ticks), by=x -> x["trade_id"])
        )
        
        if length(ticks) > bot.ema_span
            break
        end
        
        sleep(wait_for)
    end
    
    new_ticks = fetch_ticks(bot, do_print=false)
    return drop_consecutive_same_prices(
        sort(vcat(ticks, new_ticks), by=x -> x["trade_id"])
    )
end

"""
Initialize EMA and volatility indicators
"""
function init_indicators!(bot::AbstractBot)
    ticks = fetch_compressed_ticks!(bot)
    ema = ticks[1]["price"]
    bot.tick_prices_deque = Deque{Float64}()
    # Note: sizehint! not supported for Deque
    
    for tick in ticks
        push!(bot.tick_prices_deque, tick["price"])
        ema = ema * bot.ema_alpha_ + tick["price"] * bot.ema_alpha
    end
    
    # Fill deque if insufficient ticks
    if length(bot.tick_prices_deque) < bot.ema_span
        println("\nwarning: insufficient ticks fetched, filling deque with duplicate ticks...")
        println("ema and volatility will be inaccurate until deque is filled with websocket ticks")
        
        while length(bot.tick_prices_deque) < bot.ema_span
            for t in ticks
                push!(bot.tick_prices_deque, t["price"])
                if length(bot.tick_prices_deque) >= bot.ema_span
                    break
                end
            end
        end
    end
    
    bot.ema = ema
    bot.sum_prices = sum(bot.tick_prices_deque)
    bot.sum_prices_squared = sum(e^2 for e in bot.tick_prices_deque)
    bot.price_std = sqrt(
        bot.sum_prices_squared / length(bot.tick_prices_deque) -
        (bot.sum_prices / length(bot.tick_prices_deque))^2
    )
    bot.volatility = bot.price_std / bot.ema
    
    println("\ndebug len ticks, prices deque, ema_span")
    println("$(length(ticks)), $(length(bot.tick_prices_deque)), $(bot.ema_span)")
end

"""
Update EMA and volatility indicators from new ticks
"""
function update_indicators!(bot::AbstractBot, ticks::Vector)
    for tick in ticks
        bot.agg_qty += tick["qty"]
        
        # Skip if same price and buyer_maker flag
        if tick["price"] == bot.price && tick["is_buyer_maker"] == bot.is_buyer_maker
            continue
        end
        
        bot.qty = bot.agg_qty
        bot.agg_qty = 0.0
        bot.price = tick["price"]
        bot.is_buyer_maker = tick["is_buyer_maker"]
        
        # Update order book
        if tick["is_buyer_maker"]
            bot.ob[1] = tick["price"]
        else
            bot.ob[2] = tick["price"]
        end
        
        # Update EMA
        bot.ema = Jitted.calc_ema(
            bot.ema_alpha,
            bot.ema_alpha_,
            bot.ema,
            tick["price"]
        )
        
        # Update rolling statistics for volatility
        bot.sum_prices -= first(bot.tick_prices_deque)
        bot.sum_prices_squared -= first(bot.tick_prices_deque)^2
        popfirst!(bot.tick_prices_deque)
        push!(bot.tick_prices_deque, tick["price"])
        bot.sum_prices += last(bot.tick_prices_deque)
        bot.sum_prices_squared += last(bot.tick_prices_deque)^2
    end
    
    # Calculate volatility
    bot.price_std = sqrt(
        bot.sum_prices_squared / length(bot.tick_prices_deque) -
        (bot.sum_prices / length(bot.tick_prices_deque))^2
    )
    bot.volatility = bot.price_std / bot.ema
end

# WebSocket and utility methods

"""
Update output information for display
"""
function update_output_information!(bot::AbstractBot)
    bot.ts_released["print"] = time()
    
    symbol = get(bot.config, "symbol", "UNKNOWN")
    line = "$symbol "
    line *= "l $(bot.position["long"]["size"]) @ "
    line *= "$(Jitted.round_(bot.position["long"]["price"], bot.config["price_step"])) "
    
    # Long close orders
    long_closes = sort(
        [o for o in bot.open_orders if o["side"] == "sell" && o["position_side"] == "long"],
        by=x -> x["price"]
    )
    long_entries = sort(
        [o for o in bot.open_orders if o["side"] == "buy" && o["position_side"] == "long"],
        by=x -> x["price"]
    )
    
    line *= "c@ $(isempty(long_closes) ? 0.0 : long_closes[1]["price"]) "
    line *= "e@ $(isempty(long_entries) ? 0.0 : long_entries[end]["price"]) "
    line *= "|| s $(bot.position["shrt"]["size"]) @ "
    line *= "$(Jitted.round_(bot.position["shrt"]["price"], bot.config["price_step"])) "
    
    # Short close orders
    shrt_closes = sort(
        [o for o in bot.open_orders 
         if o["side"] == "buy" && 
            (o["position_side"] == "shrt" || 
             (o["position_side"] == "both" && bot.position["shrt"]["size"] != 0.0))],
        by=x -> x["price"]
    )
    shrt_entries = sort(
        [o for o in bot.open_orders 
         if o["side"] == "sell" && 
            (o["position_side"] == "shrt" || 
             (o["position_side"] == "both" && bot.position["shrt"]["size"] != 0.0))],
        by=x -> x["price"]
    )
    
    line *= "c@ $(isempty(shrt_closes) ? 0.0 : shrt_closes[end]["price"]) "
    line *= "e@ $(isempty(shrt_entries) ? 0.0 : shrt_entries[1]["price"]) "
    
    # Liquidation and stop loss info
    if bot.position["long"]["size"] > abs(bot.position["shrt"]["size"])
        liq_price = bot.position["long"]["liquidation_price"]
        sl_trigger_price = liq_price / (1 - bot.config["stop_loss_liq_diff"])
    else
        liq_price = bot.position["shrt"]["liquidation_price"]
        sl_trigger_price = liq_price / (1 + bot.config["stop_loss_liq_diff"])
    end
    
    line *= "|| last $(bot.price) liq $(Jitted.compress_float(liq_price, 5)) "
    line *= "sl trig $(Jitted.compress_float(sl_trigger_price, 5)) "
    line *= "ema $(Jitted.compress_float(bot.ema, 5)) "
    line *= "bal $(Jitted.compress_float(bot.position["wallet_balance"], 3)) "
    line *= "eq $(Jitted.compress_float(bot.position["equity"], 3)) "
    line *= "v. $(Jitted.compress_float(bot.volatility, 5)) "
    
    print_([line], r=true)
end

"""
Flush stuck locks after timeout
"""
function flush_stuck_locks!(bot::AbstractBot, timeout::Float64=4.0)
    now = time()
    for key in keys(bot.ts_locked)
        if bot.ts_locked[key] > bot.ts_released[key]
            if now - bot.ts_locked[key] > timeout
                println("flushing $key")
                bot.ts_released[key] = now
            end
        end
    end
end

"""
Start WebSocket connection and process ticks
"""
function start_websocket!(bot::AbstractBot)
    bot.stop_websocket = false
    bot.process_websocket_ticks = true
    
    print_([bot.endpoints["websocket"]])
    
    # Match Python flow: init (exchange info) → update_position → init_exchange_config → init_indicators → init_order_book
    # init! must come first because it sets coin/quot/margin_coin/price_step/qty_step from exchange info,
    # which are needed by update_position! (fetch_position uses bot.quot)
    try
        @info "Initializing bot (exchange info, xk, fills)..."
        init!(bot)
    catch e
        @error "Error initializing bot" exception=(e, catch_backtrace())
        rethrow(e)
    end
    
    try
        @info "Updating position..."
        update_position!(bot)
    catch e
        @error "Error updating position" exception=(e, catch_backtrace())
        rethrow(e)
    end
    
    try
        @info "Initializing exchange config..."
        init_exchange_config!(bot)
    catch e
        @error "Error initializing exchange config" exception=(e, catch_backtrace())
        rethrow(e)
    end
    
    try
        @info "Initializing indicators..."
        init_indicators!(bot)
    catch e
        @error "Error initializing indicators" exception=(e, catch_backtrace())
        rethrow(e)
    end
    
    try
        @info "Initializing order book..."
        init_order_book!(bot)
    catch e
        @error "Error initializing order book" exception=(e, catch_backtrace())
        rethrow(e)
    end
    
    k = 1
    
    @info "Opening WebSocket connection to $(bot.endpoints["websocket"])..."
    HTTP.WebSockets.open(bot.endpoints["websocket"]) do ws
        @info "WebSocket connected! Subscribing..."
        subscribe_ws!(bot, ws)
        @info "Waiting for messages..."
        
        # Use while loop with explicit read instead of iteration
        while !bot.stop_websocket && bot.new_symbol === nothing
            try
                # Read message from websocket using HTTP.WebSockets.receive
                msg = HTTP.WebSockets.receive(ws)
                
                if msg === nothing || isempty(msg)
                    continue
                end
                
                try
                    ticks = standardize_websocket_ticks(bot, JSON3.read(msg))
                    
                    if bot.process_websocket_ticks
                        if !isempty(ticks)
                            update_indicators!(bot, ticks)
                        end
                        
                        # Call decide! on every tick when not locked (matching Python)
                        if bot.ts_locked["decide"] < bot.ts_released["decide"]
                            @async try
                                decide!(bot)
                            catch e
                                @error "Error in async decide!" exception=(e, catch_backtrace())
                            end
                        end
                    end
                    
                    if k % FLUSH_STUCK_LOCKS_MODULO == 0
                        flush_stuck_locks!(bot)
                        k = 1
                    end
                    
                    k += 1
                catch e
                    if !occursin("success", string(msg))
                        @error "Error processing websocket message" exception=e msg=msg
                    end
                end
            catch e
                # Connection closed or error reading
                if isa(e, EOFError)
                    @warn "WebSocket connection closed"
                    break
                else
                    @error "Error reading from websocket" exception=e
                    rethrow(e)
                end
            end
        end
        
        if bot.telegram !== nothing
            if bot.stop_websocket
                # telegram.send_msg("<pre>Bot stopped</pre>")
            elseif bot.new_symbol !== nothing
                # telegram.send_msg("<pre>Changing symbol to $(bot.new_symbol)</pre>")
            end
        end
    end
end

"""
Start bot with auto-reconnect
"""
function start_bot(bot::AbstractBot)
    # Initialize Telegram bot if configured
    if bot.telegram === nothing
        bot.telegram = create_telegram_bot(bot.config, bot)
    end
    
    while !bot.stop_websocket && bot.new_symbol === nothing
        try
            start_websocket!(bot)
        catch e
            @error "Websocket connection has been lost, attempting to reinitialize the bot..." exception=e
            sleep(10)
        end
    end
end

# Exports are handled by the main PassivBot module
