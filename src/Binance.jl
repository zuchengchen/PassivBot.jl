"""
    Binance

Binance Futures API client for PassivBot.
Handles REST API calls and WebSocket streaming.
"""

using HTTP
using JSON3
using SHA
using Dates
using DataStructures: Deque

# Functions from other files are available in the same module
# No need to import since we're using include() in PassivBot.jl

"""
    BinanceBot

Binance Futures trading bot client.
"""
mutable struct BinanceBot <: AbstractBot
    exchange::String
    symbol::String
    user::String
    config::Dict{String,Any}
    xk::Dict{String, Float64}
    
    # API credentials
    key::String
    secret::String
    
    # Telegram integration
    telegram::Any
    
    # Endpoints
    base_endpoint::String
    spot_base_endpoint::String
    endpoints::Dict{String,String}
    
    # Market info
    coin::String
    quot::String
    margin_coin::String
    pair::String
    market_type::String
    
    # Trading parameters
    min_qty::Float64
    qty_step::Float64
    price_step::Float64
    min_cost::Float64
    max_leverage::Int
    max_pos_size_ito_usdt::Float64
    
    # EMA parameters
    ema_span::Int
    ema_alpha::Float64
    ema_alpha_::Float64
    
    # Timestamps for rate limiting
    ts_locked::Dict{String, Float64}
    ts_released::Dict{String, Float64}
    
    # State
    position::Dict{String,Any}
    open_orders::Vector{Dict{String,Any}}
    fills::Vector{Dict{String, Any}}
    ob::Vector{Float64}  # [bid, ask]
    price::Float64
    highest_bid::Float64
    lowest_ask::Float64
    is_buyer_maker::Bool
    agg_qty::Float64
    qty::Float64
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
    
    # WebSocket control (required by start_bot)
    stop_websocket::Bool
    new_symbol::Union{String, Nothing}
    process_websocket_ticks::Bool
    
    function BinanceBot(config::Dict{String,Any})
        bot = new()
        bot.exchange = "binance"
        bot.config = config
        bot.symbol = config["symbol"]
        bot.user = config["user"]
        bot.xk = Dict{String, Float64}()
        
        # Load API credentials and user config (including telegram)
        bot.key, bot.secret = load_key_secret("binance", config["user"])
        
        # Load telegram config from api-keys.json if not already in config
        if !haskey(config, "telegram")
            try
                user_config = load_user_config("binance", config["user"])
                if haskey(user_config, "telegram")
                    config["telegram"] = user_config["telegram"]
                end
            catch e
                @warn "Could not load telegram config from api-keys.json" exception=e
            end
        end
        
        # Telegram integration
        bot.telegram = nothing
        
        # Initialize EMA parameters
        bot.ema_span = Int(round(get(config, "ema_span", 20)))
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
        
        # Initialize state
        bot.position = Dict{String,Any}()
        bot.open_orders = Vector{Dict{String,Any}}()
        bot.fills = Vector{Dict{String, Any}}()
        bot.ob = [0.0, 0.0]
        bot.price = 0.0
        bot.highest_bid = 0.0
        bot.lowest_ask = 9.9e9
        bot.is_buyer_maker = true
        bot.agg_qty = 0.0
        bot.qty = 0.0
        bot.ema = 0.0
        bot.max_pos_size_ito_usdt = 0.0
        
        # Initialize volatility tracking
        bot.tick_prices_deque = Deque{Float64}()
        bot.sum_prices = 0.0
        bot.sum_prices_squared = 0.0
        bot.price_std = 0.0
        bot.volatility = 0.0
        
        # Order limits
        bot.n_open_orders_limit = 1000  # MAX_OPEN_ORDERS_LIMIT
        bot.n_orders_per_execution = 100  # ORDERS_PER_EXECUTION
        
        # Exchange settings
        bot.hedge_mode = true
        bot.contract_multiplier = 1.0
        
        # Logging
        config_name = get(config, "config_name", "default")
        bot.log_filepath = make_get_filepath("logs/binance/$config_name.log")
        bot.log_level = 0
        bot.log_buffer = String[]
        bot.log_buffer_max_size = 100  # LOG_BUFFER_MAX_SIZE
        bot.log_last_flush = time()
        bot.log_flush_interval = 5.0  # LOG_FLUSH_INTERVAL
        
        # Initialize WebSocket control
        bot.stop_websocket = false
        bot.new_symbol = nothing
        bot.process_websocket_ticks = true
        
        # Initialize market type and endpoints
        init_market_type!(bot)
        
        return bot
    end
end

"""
    init_market_type!(bot::BinanceBot)

Initialize market type and API endpoints.
"""
function init_market_type!(bot::BinanceBot)
    if !endswith(bot.symbol, "USDT")
        error("Only USDT-margined perpetuals supported. Symbol $(bot.symbol) is not supported.")
    end
    
    println("linear perpetual")
    bot.market_type = "linear_perpetual"
    bot.base_endpoint = "https://fapi.binance.com"
    bot.endpoints = Dict{String,String}(
        "position" => "/fapi/v2/positionRisk",
        "balance" => "/fapi/v2/balance",
        "exchange_info" => "/fapi/v1/exchangeInfo",
        "leverage_bracket" => "/fapi/v1/leverageBracket",
        "open_orders" => "/fapi/v1/openOrders",
        "ticker" => "/fapi/v1/ticker/bookTicker",
        "fills" => "/fapi/v1/userTrades",
        "income" => "/fapi/v1/income",
        "create_order" => "/fapi/v1/order",
        "cancel_order" => "/fapi/v1/order",
        "ticks" => "/fapi/v1/aggTrades",
        "margin_type" => "/fapi/v1/marginType",
        "leverage" => "/fapi/v1/leverage",
        "position_side" => "/fapi/v1/positionSide/dual",
        "websocket" => "wss://fstream.binance.com/ws/$(lowercase(bot.symbol))@aggTrade"
    )
    
    bot.spot_base_endpoint = "https://api.binance.com"
    bot.endpoints["transfer"] = "/sapi/v1/asset/transfer"
    bot.endpoints["account"] = "/api/v3/account"
end

"""
    public_get(bot::BinanceBot, url::String, params::Dict=Dict())

Make a public GET request to Binance API.
"""
function public_get(bot::BinanceBot, url::String, params::Dict=Dict())
    # Convert all parameter values to strings for HTTP.jl
    string_params = Dict{String,String}()
    for (k, v) in params
        string_params[string(k)] = string(v)
    end
    
    try
        response = HTTP.get(bot.base_endpoint * url, query=string_params)
        return JSON3.read(String(response.body))
    catch e
        @error "public_get failed" url=url exception=(e, catch_backtrace())
        rethrow(e)
    end
end

"""
    sign_request(bot::BinanceBot, params::Dict)

Sign request parameters with HMAC-SHA256.
Matches Python implementation exactly.
"""
function sign_request(bot::BinanceBot, params::Dict)
    # Create a new dict that can hold any type temporarily
    working_params = Dict{String, Any}(params)
    
    # Add timestamp and recvWindow
    working_params["timestamp"] = Int(round(time() * 1000))
    working_params["recvWindow"] = 5000
    
    # Convert ALL values to strings
    string_params = Dict{String, String}()
    for (k, v) in working_params
        if isa(v, Bool)
            string_params[k] = v ? "true" : "false"
        else
            string_params[k] = string(v)
        end
    end
    
    # Sort dict keys recursively (matching Python's sort_dict_keys)
    sorted_params = sort_dict_keys(string_params)
    
    # Create query string manually (key1=value1&key2=value2)
    # Sort keys to ensure consistent ordering
    sorted_keys = sort(collect(keys(sorted_params)))
    query_parts = String[]
    for key in sorted_keys
        push!(query_parts, "$(HTTP.URIs.escapeuri(key))=$(HTTP.URIs.escapeuri(sorted_params[key]))")
    end
    query_string = join(query_parts, "&")
    
    # Generate signature
    signature = bytes2hex(hmac_sha256(Vector{UInt8}(bot.secret), Vector{UInt8}(query_string)))
    sorted_params["signature"] = signature
    
    return sorted_params
end

"""
    private_get(bot::BinanceBot, url::String, params::Dict=Dict(); base_endpoint::Union{Nothing,String}=nothing)

Make an authenticated GET request.
"""
function private_get(bot::BinanceBot, url::String, params::Dict=Dict(); base_endpoint::Union{Nothing,String}=nothing)
    endpoint = isnothing(base_endpoint) ? bot.base_endpoint : base_endpoint
    signed_params = sign_request(bot, params)
    
    # Construct query string manually to ensure correct ordering
    sorted_keys = sort(collect(keys(signed_params)))
    query_parts = String[]
    for key in sorted_keys
        push!(query_parts, "$(HTTP.URIs.escapeuri(key))=$(HTTP.URIs.escapeuri(signed_params[key]))")
    end
    query_string = join(query_parts, "&")
    
    # Construct full URL with query string
    full_url = endpoint * url * "?" * query_string
    
    headers = ["X-MBX-APIKEY" => bot.key]
    try
        response = HTTP.get(full_url, headers=headers)
        return JSON3.read(String(response.body))
    catch e
        @error "private_get failed" url=url exception=(e, catch_backtrace())
        rethrow(e)
    end
end

"""
    private_post(bot::BinanceBot, base_endpoint::String, url::String, params::Dict=Dict())

Make an authenticated POST request.
"""
function private_post(bot::BinanceBot, base_endpoint::String, url::String, params::Dict=Dict())
    signed_params = sign_request(bot, params)
    
    # Construct query string manually to ensure correct ordering
    sorted_keys = sort(collect(keys(signed_params)))
    query_parts = String[]
    for key in sorted_keys
        push!(query_parts, "$(HTTP.URIs.escapeuri(key))=$(HTTP.URIs.escapeuri(signed_params[key]))")
    end
    query_string = join(query_parts, "&")
    
    # Construct full URL with query string
    full_url = base_endpoint * url * "?" * query_string
    
    headers = ["X-MBX-APIKEY" => bot.key]
    try
        response = HTTP.post(full_url, headers=headers)
        return JSON3.read(String(response.body))
    catch e
        @error "private_post failed" url=url exception=(e, catch_backtrace())
        rethrow(e)
    end
end

"""
    private_delete(bot::BinanceBot, url::String, params::Dict=Dict())

Make an authenticated DELETE request.
"""
function private_delete(bot::BinanceBot, url::String, params::Dict=Dict())
    signed_params = sign_request(bot, params)
    
    # Construct query string manually to ensure correct ordering
    sorted_keys = sort(collect(keys(signed_params)))
    query_parts = String[]
    for key in sorted_keys
        push!(query_parts, "$(HTTP.URIs.escapeuri(key))=$(HTTP.URIs.escapeuri(signed_params[key]))")
    end
    query_string = join(query_parts, "&")
    
    # Construct full URL with query string
    full_url = bot.base_endpoint * url * "?" * query_string
    
    headers = ["X-MBX-APIKEY" => bot.key]
    try
        response = HTTP.delete(full_url, headers=headers)
        return JSON3.read(String(response.body))
    catch e
        @error "private_delete failed" url=url exception=(e, catch_backtrace())
        rethrow(e)
    end
end

"""
    execute_leverage_change(bot::BinanceBot)

Set leverage to 20 on the exchange. Returns response with maxNotionalValue.
"""
function execute_leverage_change(bot::BinanceBot)
    return private_post(bot, bot.base_endpoint, bot.endpoints["leverage"],
                        Dict("symbol" => bot.symbol, "leverage" => 20))
end

"""
    init_exchange_config!(bot::BinanceBot)

Configure exchange settings: CROSSED margin type, leverage, hedge mode.
Extracts max_pos_size_ito_usdt from leverage response.
"""
function init_exchange_config!(bot::BinanceBot)
    # Set margin type to CROSSED
    try
        result = private_post(bot, bot.base_endpoint, bot.endpoints["margin_type"],
                              Dict("symbol" => bot.symbol, "marginType" => "CROSSED"))
        println(result)
    catch e
        err_str = string(e)
        if occursin("-4046", err_str)
            println("margin type already CROSSED")
        else
            println("margin type error: ", err_str)
        end
    end

    # Set leverage and extract max position size
    try
        lev = execute_leverage_change(bot)
        print_([lev])
        if haskey(lev, "maxNotionalValue")
            bot.max_pos_size_ito_usdt = parse(Float64, string(lev["maxNotionalValue"]))
        elseif haskey(lev, :maxNotionalValue)
            bot.max_pos_size_ito_usdt = parse(Float64, string(lev[:maxNotionalValue]))
        end
        println("max pos size in terms of usdt ", bot.max_pos_size_ito_usdt)
    catch e
        @error "Setting leverage" exception=e
    end

    # Enable hedge mode (dual side position)
    try
        res = private_post(bot, bot.base_endpoint, bot.endpoints["position_side"],
                           Dict("dualSidePosition" => "true"))
        println(res)
    catch e
        err_str = string(e)
        if occursin("-4059", err_str)
            println("hedge mode already enabled")
        else
            @error "Unable to set hedge mode" exception=e
            error("failed to set hedge mode")
        end
    end
end

"""
    check_if_other_positions(bot::BinanceBot; abort::Bool=true)

Check if other symbols have positions or open orders sharing the margin wallet.
"""
function check_if_other_positions(bot::BinanceBot; abort::Bool=true)
    positions = private_get(bot, bot.endpoints["position"])
    open_orders = private_get(bot, bot.endpoints["open_orders"])
    do_abort = false

    for e in positions
        if parse(Float64, string(get(e, "positionAmt", "0"))) != 0.0
            sym = String(get(e, "symbol", ""))
            if sym != bot.symbol && occursin(bot.margin_coin, sym)
                println("\n\nWARNING\n")
                println("account has position in other symbol: ", e)
                println()
                do_abort = true
            end
        end
    end

    for e in open_orders
        sym = String(get(e, "symbol", ""))
        if sym != bot.symbol && occursin(bot.margin_coin, sym)
            println("\n\nWARNING\n")
            println("account has open orders in other symbol: ", e)
            println()
            do_abort = true
        end
    end

    if do_abort
        if abort
            error("please close other positions and cancel other open orders")
        end
    else
        println("no positions or open orders in other symbols sharing margin wallet")
    end
end

"""
    fetch_income(bot::BinanceBot; limit::Int=1000, start_time=nothing, end_time=nothing)

Fetch funding rate income from Binance.
"""
function fetch_income(bot::BinanceBot; limit::Int=1000, start_time=nothing, end_time=nothing)
    params = Dict{String,Any}("symbol" => bot.symbol, "limit" => limit)
    if !isnothing(start_time)
        params["startTime"] = start_time
    end
    if !isnothing(end_time)
        params["endTime"] = end_time
    end
    try
        fetched = private_get(bot, bot.endpoints["income"], params)
        income = Vector{Dict{String,Any}}()
        for x in fetched
            push!(income, Dict{String,Any}(
                "symbol" => String(x["symbol"]),
                "incomeType" => String(x["incomeType"]),
                "income" => parse(Float64, string(x["income"])),
                "asset" => String(x["asset"]),
                "info" => String(get(x, "info", "")),
                "timestamp" => Int(x["time"]),
                "tranId" => get(x, "tranId", 0),
                "tradeId" => get(x, "tradeId", "")
            ))
        end
        return income
    catch e
        @error "Error fetching income" exception=(e, catch_backtrace())
        return Vector{Dict{String,Any}}()
    end
end

"""
    fetch_account(bot::BinanceBot)

Fetch spot account balances.
"""
function fetch_account(bot::BinanceBot)
    try
        return private_get(bot, bot.endpoints["account"]; base_endpoint=bot.spot_base_endpoint)
    catch e
        @error "Error fetching account" exception=(e, catch_backtrace())
        return Dict{String,Any}("balances" => [])
    end
end

"""
    transfer(bot::BinanceBot; type_::String, amount::Float64, asset::String="USDT")

Transfer funds between futures and spot wallets.
type_ can be "UMFUTURE_MAIN" (futures→spot) or "MAIN_UMFUTURE" (spot→futures).
"""
function transfer(bot::BinanceBot; type_::String, amount::Float64, asset::String="USDT")
    params = Dict{String,Any}(
        "type" => type_,
        "asset" => asset,
        "amount" => string(amount)
    )
    try
        return private_post(bot, bot.spot_base_endpoint, bot.endpoints["transfer"], params)
    catch e
        @error "Error transferring" exception=(e, catch_backtrace())
        return Dict{String,Any}("code" => -1, "msg" => string(e))
    end
end

"""
    init!(bot::BinanceBot)

Async initialization of the bot.
"""
function init!(bot::BinanceBot)
    # Set config defaults
    if !haskey(bot.config, "entry_liq_diff_thr")
        bot.config["entry_liq_diff_thr"] = get(bot.config, "stop_loss_liq_diff", 0.1)
    end
    if !haskey(bot.config, "last_price_diff_limit")
        bot.config["last_price_diff_limit"] = 10.0
    end
    
    # Fetch exchange info and leverage bracket
    exchange_info = public_get(bot, bot.endpoints["exchange_info"])
    leverage_bracket = private_get(bot, bot.endpoints["leverage_bracket"])
    
    # Parse exchange info
    for e in exchange_info["symbols"]
        if e["symbol"] == bot.symbol
            bot.coin = e["baseAsset"]
            bot.quot = e["quoteAsset"]
            bot.margin_coin = e["marginAsset"]
            bot.pair = e["pair"]
            
            for q in e["filters"]
                if q["filterType"] == "LOT_SIZE"
                    bot.min_qty = parse(Float64, q["minQty"])
                    bot.config["min_qty"] = bot.min_qty
                elseif q["filterType"] == "MARKET_LOT_SIZE"
                    bot.qty_step = parse(Float64, q["stepSize"])
                    bot.config["qty_step"] = bot.qty_step
                elseif q["filterType"] == "PRICE_FILTER"
                    bot.price_step = parse(Float64, q["tickSize"])
                    bot.config["price_step"] = bot.price_step
                elseif q["filterType"] == "MIN_NOTIONAL"
                    bot.min_cost = parse(Float64, q["notional"])
                    bot.config["min_cost"] = bot.min_cost
                end
            end
            
            if !isdefined(bot, :min_cost)
                bot.min_cost = 0.0
                bot.config["min_cost"] = 0.0
            end
            break
        end
    end
    
    # Parse leverage bracket
    max_lev = 20
    for e in leverage_bracket
        if (haskey(e, "pair") && e["pair"] == bot.pair) || 
           (haskey(e, "symbol") && e["symbol"] == bot.symbol)
            for br in e["brackets"]
                lev_value = br["initialLeverage"]
                lev_int = isa(lev_value, Integer) ? Int(lev_value) : parse(Int, string(lev_value))
                max_lev = max(max_lev, lev_int)
            end
            break
        end
    end
    bot.max_leverage = max_lev
    
    # Fill xk dictionary with config values
    bot.xk = Dict{String, Float64}(
        k => Float64(bot.config[k]) for k in PassivBot.get_keys()
    )
    
    # Initialize order book and position
    init_order_book!(bot)
    update_position!(bot)
end

"""
    init_order_book!(bot::BinanceBot)

Initialize order book with current bid/ask.
"""
function init_order_book!(bot::BinanceBot)
    ticker = public_get(bot, bot.endpoints["ticker"], Dict("symbol" => bot.symbol))
    bot.ob = [parse(Float64, ticker["bidPrice"]), parse(Float64, ticker["askPrice"])]
    bot.price = rand() < 0.5 ? bot.ob[1] : bot.ob[2]
end

"""
    fetch_open_orders(bot::BinanceBot)

Fetch current open orders.
"""
function fetch_open_orders(bot::BinanceBot)
    orders = private_get(bot, bot.endpoints["open_orders"], Dict("symbol" => bot.symbol))
    
    return [Dict{String,Any}(
        "order_id" => parse(Int, string(e["orderId"])),
        "symbol" => e["symbol"],
        "price" => parse(Float64, string(e["price"])),
        "qty" => parse(Float64, string(e["origQty"])),
        "type" => lowercase(e["type"]),
        "side" => lowercase(e["side"]),
        "position_side" => replace(lowercase(e["positionSide"]), "short" => "shrt"),
        "timestamp" => parse(Int, string(e["time"]))
    ) for e in orders]
end

"""
    fetch_position(bot::BinanceBot)

Fetch current position and balance.
"""
function fetch_position(bot::BinanceBot)
    # Fetch position and balance concurrently (matching Python asyncio.gather)
    positions_task = @async private_get(bot, bot.endpoints["position"], Dict("symbol" => bot.symbol))
    balance_task = @async private_get(bot, bot.endpoints["balance"], Dict())
    positions = fetch(positions_task)
    balance = fetch(balance_task)
    
    position = Dict{String,Any}()
    
    # Initialize default empty positions
    position["long"] = Dict{String,Any}(
        "size" => 0.0,
        "price" => 0.0,
        "liquidation_price" => 0.0,
        "upnl" => 0.0,
        "leverage" => 0.0
    )
    position["shrt"] = Dict{String,Any}(
        "size" => 0.0,
        "price" => 0.0,
        "liquidation_price" => 0.0,
        "upnl" => 0.0,
        "leverage" => 0.0
    )
    
    if !isempty(positions)
        for p in positions
            if p["positionSide"] == "LONG"
                position["long"] = Dict{String,Any}(
                    "size" => parse(Float64, string(p["positionAmt"])),
                    "price" => parse(Float64, string(p["entryPrice"])),
                    "liquidation_price" => parse(Float64, string(p["liquidationPrice"])),
                    "upnl" => parse(Float64, string(p["unRealizedProfit"])),
                    "leverage" => parse(Float64, string(p["leverage"]))
                )
            elseif p["positionSide"] == "SHORT"
                position["shrt"] = Dict{String,Any}(
                    "size" => parse(Float64, string(p["positionAmt"])),
                    "price" => parse(Float64, string(p["entryPrice"])),
                    "liquidation_price" => parse(Float64, string(p["liquidationPrice"])),
                    "upnl" => parse(Float64, string(p["unRealizedProfit"])),
                    "leverage" => parse(Float64, string(p["leverage"]))
                )
            end
        end
    end
    
    # Initialize default balance
    position["wallet_balance"] = 0.0
    position["equity"] = 0.0
    
    for e in balance
        if e["asset"] == bot.quot
            position["wallet_balance"] = parse(Float64, string(e["balance"]))
            position["equity"] = position["wallet_balance"] + parse(Float64, string(e["crossUnPnl"]))
            break
        end
    end
    
    return position
end

"""
    execute_order(bot::BinanceBot, order::Dict)

Execute a single order.
"""
function execute_order(bot::BinanceBot, order::Dict)
    params = Dict{String,Any}(
        "symbol" => bot.symbol,
        "side" => uppercase(order["side"]),
        "positionSide" => uppercase(replace(order["position_side"], "shrt" => "short")),
        "type" => uppercase(order["type"]),
        "quantity" => string(order["qty"])
    )
    
    if params["type"] == "LIMIT"
        params["timeInForce"] = "GTX"
        params["price"] = string(order["price"])
    end
    
    if haskey(order, "custom_id")
        params["newClientOrderId"] = "$(order["custom_id"])_$(string(Int(round(time() * 1000)))[9:end])_$(Int(round(rand() * 1000)))"
    end
    
    o = private_post(bot, bot.base_endpoint, bot.endpoints["create_order"], params)
    
    if haskey(o, "side")
        return Dict{String,Any}(
            "symbol" => bot.symbol,
            "side" => lowercase(o["side"]),
            "position_side" => replace(lowercase(o["positionSide"]), "short" => "shrt"),
            "type" => lowercase(o["type"]),
            "qty" => parse(Float64, o["origQty"]),
            "price" => parse(Float64, o["price"])
        )
    else
        return o
    end
end

"""
    execute_cancellation(bot::BinanceBot, order::Dict)

Cancel a single order.
"""
function execute_cancellation(bot::BinanceBot, order::Dict)
    cancellation = private_delete(bot, bot.endpoints["cancel_order"], 
                                  Dict("symbol" => bot.symbol, "orderId" => order["order_id"]))
    
    if haskey(cancellation, "side")
        return Dict{String,Any}(
            "symbol" => bot.symbol,
            "side" => lowercase(cancellation["side"]),
            "position_side" => replace(lowercase(cancellation["positionSide"]), "short" => "shrt"),
            "qty" => parse(Float64, cancellation["origQty"]),
            "price" => parse(Float64, cancellation["price"])
        )
    else
        return cancellation
    end
end

"""
    fetch_fills(bot::BinanceBot; limit::Int=1000, from_id::Union{Nothing,Int}=nothing,
                start_time::Union{Nothing,Int}=nothing, end_time::Union{Nothing,Int}=nothing)

Fetch recent fills (user trades) from Binance.
"""
function fetch_fills(bot::BinanceBot; limit::Int=1000, from_id::Union{Nothing,Int}=nothing,
                     start_time::Union{Nothing,Int}=nothing, end_time::Union{Nothing,Int}=nothing)
    params = Dict{String,Any}("symbol" => bot.symbol, "limit" => limit)
    if !isnothing(from_id)
        params["fromId"] = max(0, from_id)
    end
    if !isnothing(start_time)
        params["startTime"] = start_time
    end
    if !isnothing(end_time)
        params["endTime"] = end_time
    end
    try
        fetched = private_get(bot, bot.endpoints["fills"], params)
        fills = Vector{Dict{String,Any}}()
        for x in fetched
            push!(fills, Dict{String,Any}(
                "symbol" => String(x["symbol"]),
                "order_id" => Int(x["orderId"]),
                "side" => lowercase(String(x["side"])),
                "price" => parse(Float64, string(x["price"])),
                "qty" => parse(Float64, string(x["qty"])),
                "realized_pnl" => parse(Float64, string(x["realizedPnl"])),
                "cost" => parse(Float64, string(x["quoteQty"])),
                "fee_paid" => parse(Float64, string(x["commission"])),
                "fee_token" => String(x["commissionAsset"]),
                "timestamp" => Int(x["time"]),
                "position_side" => replace(lowercase(String(x["positionSide"])), "short" => "shrt"),
                "is_maker" => x["maker"]
            ))
        end
        return fills
    catch e
        @error "Error fetching fills" exception=(e, catch_backtrace())
        return Vector{Dict{String,Any}}()
    end
end

"""
    calc_max_pos_size(bot::BinanceBot, balance::Float64, price::Float64)

Calculate maximum position size.
"""
function calc_max_pos_size(bot::BinanceBot, balance::Float64, price::Float64)
    leverage = get(bot.config, "leverage", 20)
    return min(
        (balance / price) * leverage,
        bot.max_pos_size_ito_usdt / price
    ) * 0.92
end

"""
    fetch_ticks(bot::BinanceBot; from_id::Union{Nothing,Int}=nothing, 
                start_time::Union{Nothing,Int}=nothing, 
                end_time::Union{Nothing,Int}=nothing, 
                do_print::Bool=true)

Fetch historical tick data from Binance.
"""
function fetch_ticks(bot::BinanceBot; from_id::Union{Nothing,Int}=nothing, 
                     start_time::Union{Nothing,Int}=nothing, 
                     end_time::Union{Nothing,Int}=nothing, 
                     do_print::Bool=true)
    params = Dict{String,Any}("symbol" => bot.symbol, "limit" => 1000)
    
    if !isnothing(from_id)
        params["fromId"] = max(0, from_id)
    end
    if !isnothing(start_time)
        params["startTime"] = start_time
    end
    if !isnothing(end_time)
        params["endTime"] = end_time
    end
    
    try
        fetched = private_get(bot, bot.endpoints["ticks"], params)
        
        ticks = [Dict{String,Any}(
            "trade_id" => isa(t["a"], Integer) ? Int(t["a"]) : parse(Int, string(t["a"])),
            "price" => parse(Float64, string(t["p"])),
            "qty" => parse(Float64, string(t["q"])),
            "timestamp" => isa(t["T"], Integer) ? Int(t["T"]) : parse(Int, string(t["T"])),
            "is_buyer_maker" => t["m"]
        ) for t in fetched]
        
        if do_print
            println("Fetched $(length(ticks)) ticks")
        end
        
        return ticks
    catch e
        @error "Error fetching ticks" exception=e
        return Dict{String,Any}[]
    end
end

"""
    standardize_websocket_ticks(bot::BinanceBot, data)

Standardize websocket tick data from Binance aggTrade format.
"""
function standardize_websocket_ticks(bot::BinanceBot, data)
    try
        # Convert JSON3.Object to Dict if needed
        if !isa(data, Dict)
            data = Dict(data)
        end
        
        # Handle both Symbol and String keys
        price_key = haskey(data, "p") ? "p" : :p
        qty_key = haskey(data, "q") ? "q" : :q
        maker_key = haskey(data, "m") ? "m" : :m
        
        return [Dict{String,Any}(
            "price" => parse(Float64, string(data[price_key])),
            "qty" => parse(Float64, string(data[qty_key])),
            "is_buyer_maker" => data[maker_key]
        )]
    catch e
        @error "Error in websocket tick" exception=e data=data
        return Dict{String,Any}[]
    end
end

"""
    subscribe_ws!(bot::BinanceBot, ws)

Subscribe to websocket streams (no-op for Binance aggTrade).
"""
function subscribe_ws!(bot::BinanceBot, ws)
    # No subscription needed for aggTrade stream
    nothing
end
