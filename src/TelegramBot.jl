"""
    TelegramBot

Telegram bot interface for remote control of PassivBot.
Simplified implementation - full feature parity would require a Telegram.jl package.

Note: This is a stub implementation. For full functionality, you would need to:
1. Find or create a Julia Telegram bot library
2. Implement all command handlers
3. Add conversation flows for configuration changes
"""

using HTTP
using JSON3
using Dates

# ============================================================================
# Struct definitions
# ============================================================================

"""
    TelegramBot

Telegram bot for remote control and monitoring.
"""
mutable struct TelegramBot
    token::String
    chat_id::String
    bot_instance::Any
    config::Dict{String,Any}
    last_update_id::Int
    
    function TelegramBot(token::String, chat_id::String, bot_instance, config::Dict{String,Any})
        new(token, chat_id, bot_instance, config, 0)
    end
end

# ============================================================================
# Helper functions
# ============================================================================

"""
    create_keyboard_markup(buttons::Vector{Vector{String}}; resize_keyboard::Bool=true, one_time_keyboard::Bool=false)

Create a ReplyKeyboardMarkup for Telegram.
buttons is a 2D array of button labels.
"""
function create_keyboard_markup(buttons::Vector{Vector{String}}; resize_keyboard::Bool=true, one_time_keyboard::Bool=false)
    keyboard_buttons = [[Dict("text" => label) for label in row] for row in buttons]
    return Dict(
        "keyboard" => keyboard_buttons,
        "resize_keyboard" => resize_keyboard,
        "one_time_keyboard" => one_time_keyboard
    )
end

"""
    create_inline_keyboard(buttons::Vector{Vector{Dict{String,String}}})

Create an InlineKeyboardMarkup for Telegram.
Each button is a Dict with "text" and "callback_data" keys.
"""
function create_inline_keyboard(buttons::Vector{Vector{Dict{String,String}}})
    return Dict(
        "inline_keyboard" => buttons
    )
end

"""
    answer_callback_query(tg::TelegramBot, callback_query_id::String, text::String="")

Answer a callback query (for inline keyboard button presses).
"""
function answer_callback_query(tg::TelegramBot, callback_query_id::String, text::String="")
    url = "https://api.telegram.org/bot$(tg.token)/answerCallbackQuery"
    
    payload = Dict{String, Any}(
        "callback_query_id" => callback_query_id
    )
    
    if !isempty(text)
        payload["text"] = text
    end
    
    try
        response = HTTP.post(url, 
            ["Content-Type" => "application/json"],
            JSON3.write(payload)
        )
        return true
    catch e
        @error "Failed to answer callback query" exception=e
        return false
    end
end

# ============================================================================
# Export list
# ============================================================================

export TelegramBot, send_message, send_msg, start_telegram_bot, create_telegram_bot
export create_keyboard_markup, answer_callback_query
export notify_entry_order_filled, notify_close_order_filled, log_start

"""
    send_message(tg::TelegramBot, text::String, reply_markup=nothing)

Send a message to the configured chat.
Optionally include a reply markup (keyboard/buttons).
"""
function send_message(tg::TelegramBot, text::String, reply_markup=nothing)
    url = "https://api.telegram.org/bot$(tg.token)/sendMessage"
    
    # Build payload - handle reply_markup separately to avoid type issues
    if reply_markup !== nothing
        payload = Dict{String, Any}(
            "chat_id" => tg.chat_id,
            "text" => text,
            "parse_mode" => "HTML",
            "reply_markup" => reply_markup
        )
    else
        payload = Dict{String, Any}(
            "chat_id" => tg.chat_id,
            "text" => text,
            "parse_mode" => "HTML"
        )
    end
    
    try
        response = HTTP.post(url, 
            ["Content-Type" => "application/json"],
            JSON3.write(payload)
        )
        return true
    catch e
        @error "Failed to send Telegram message" exception=e
        return false
    end
end

"""Alias for send_message (matches Python's send_msg)"""
send_msg(tg::TelegramBot, text::String) = send_message(tg, text)

"""Send startup notification"""
function log_start(tg::TelegramBot)
    bot = tg.bot_instance
    symbol = get(bot.config, "symbol", "UNKNOWN")
    send_message(tg, "<b>Passivbot started!</b>\n<b>$(symbol)</b>")
end

"""
Notify when an entry order is filled.
"""
function notify_entry_order_filled(tg::TelegramBot; position_side::String, qty::Float64,
                                    fee::Float64, price::Float64, total_size::Float64)
    config = tg.config
    if get(config, "notify_entry_fill", true) == false
        return
    end
    bot = tg.bot_instance
    qty_step = get(bot.config, "qty_step", 0.001)
    price_step = get(bot.config, "price_step", 0.01)
    margin_coin = get(bot.config, "margin_coin", "USDT")
    exchange = get(bot.config, "exchange", "binance")
    symbol = get(bot.config, "symbol", "")
    fee_pct = qty * price > 0 ? round_(fee / (qty * price) * 100, price_step) : 0.0
    
    msg = "<b>🔵 $(titlecase(exchange)) $(symbol)</b> Opened $(position_side)\n" *
          "<b>Amount: </b><pre>$(round_(qty, qty_step))</pre>\n" *
          "<b>Total size: </b><pre>$(round_(total_size, qty_step))</pre>\n" *
          "<b>Price: </b><pre>$(round_(price, price_step))</pre>\n" *
          "<b>Fee: </b><pre>$(round_(fee, price_step)) $(margin_coin) ($(fee_pct)%)</pre>"
    send_message(tg, msg)
end

"""
Notify when a close order is filled.
"""
function notify_close_order_filled(tg::TelegramBot; realized_pnl::Float64, position_side::String,
                                    qty::Float64, fee::Float64, wallet_balance::Float64,
                                    remaining_size::Float64, price::Float64)
    config = tg.config
    if get(config, "notify_close_fill", true) == false
        return
    end
    bot = tg.bot_instance
    qty_step = get(bot.config, "qty_step", 0.001)
    price_step = get(bot.config, "price_step", 0.01)
    margin_coin = get(bot.config, "margin_coin", "USDT")
    exchange = get(bot.config, "exchange", "binance")
    symbol = get(bot.config, "symbol", "")
    icon = realized_pnl >= 0 ? "✅" : "❌"
    pnl_pct = wallet_balance > 0 ? round_(realized_pnl / wallet_balance * 100, price_step) : 0.0
    fee_pct = realized_pnl != 0 ? round_(fee / abs(realized_pnl) * 100, price_step) : 0.0
    
    msg = "<b>$(icon) $(titlecase(exchange)) $(symbol)</b> Closed $(position_side)\n" *
          "<b>PNL: </b><pre>$(round_(realized_pnl, price_step)) $(margin_coin) ($(pnl_pct)%)</pre>\n" *
          "<b>Amount: </b><pre>$(round_(qty, qty_step))</pre>\n" *
          "<b>Remaining size: </b><pre>$(round_(remaining_size, qty_step))</pre>\n" *
          "<b>Price: </b><pre>$(round_(price, price_step))</pre>\n" *
          "<b>Fee: </b><pre>$(round_(fee, price_step)) $(margin_coin) ($(fee_pct)%)</pre>"
    send_message(tg, msg)
end

"""
    get_updates(tg::TelegramBot)

Get new updates from Telegram.
Uses long-polling with retry mechanism for transient network errors.
"""
function get_updates(tg::TelegramBot)
    url = "https://api.telegram.org/bot$(tg.token)/getUpdates"

    params = Dict(
        "offset" => tg.last_update_id + 1,
        "timeout" => 10  # Long-polling timeout
    )

    try
        # Enable retry for transient errors, with reasonable timeouts
        # readtimeout should be > polling timeout to allow long-poll to complete
        # connect_timeout handles initial connection issues
        response = HTTP.get(url; 
            query=params, 
            retry=true,           # Enable retry for transient errors
            retries=2,            # Max 2 retries
            readtimeout=20,       # Allow time for long-poll (> timeout param)
            connect_timeout=10    # Connection timeout
        )
        data = JSON3.read(String(response.body))

        if data["ok"]
            return data["result"]
        else
            @error "Telegram API error" error_code=get(data, "error_code", "unknown") description=get(data, "description", "unknown")
            return []
        end
    catch e
        # Classify errors: transient network errors are expected, use @warn
        # Only use @error for unexpected issues
        if e isa HTTP.ConnectError || e isa HTTP.RequestError
            # Transient network errors - expected in long-polling scenarios
            @warn "Telegram connection issue (will retry)" error_type=typeof(e).name.name
        else
            @error "Failed to get Telegram updates" exception=(e, catch_backtrace())
        end
        return []
    end
end

"""
    handle_command(tg::TelegramBot, command::String, args::Vector{String})

Handle a bot command.
"""
function handle_command(tg::TelegramBot, command::String, args::Vector{String})
    bot = tg.bot_instance

    # Helper function to get config value
    getcfg(key) = get(bot.config, key, get(bot.xk, key, nothing))
    # Helper function to set config value (updates both config and xk)
    function setcfg!(key, value)
        bot.config[key] = value
        bot.xk[key] = value
    end

    # Get current values
    do_long = Bool(getcfg("do_long"))
    do_shrt = Bool(getcfg("do_shrt"))

    # Create keyboard with main buttons
    keyboard_buttons = [
        ["/status", "/balance", "/position"],
        ["/do_long", "/stop_long", "/do_shrt"],
        ["/stop_shrt", "/config", "/help"]
    ]
    keyboard = create_keyboard_markup(keyboard_buttons, resize_keyboard=true)

    if command == "/start" || command == "/help"
        help_text = """
        <b>PassivBot Telegram Interface</b>

        Available commands:
        /help - Show this help message
        /status - Show bot status
        /balance - Show current balance
        /position - Show current position
        /config - Show current configuration
        /do_long - Enable long trading
        /stop_long - Disable long trading
        /do_shrt - Enable short trading
        /stop_shrt - Disable short trading
        /stop - Stop the bot gracefully

        Use the buttons below for quick access!
        """
        send_message(tg, help_text, keyboard)

    elseif command == "/status"
        status_text = """
        <b>Bot Status</b>
        Symbol: $(bot.symbol)
        Exchange: $(bot.exchange)
        Long: $(do_long ? "✅ Enabled" : "❌ Disabled")
        Short: $(do_shrt ? "✅ Enabled" : "❌ Disabled")
        """
        send_message(tg, status_text, keyboard)

    elseif command == "/balance"
        # Safely get balance values with defaults
        balance = round(get(bot.position, "balance", 0.0), digits=2)
        equity = round(get(bot.position, "equity", 0.0), digits=2)
        available = round(get(bot.position, "available_margin", 0.0), digits=2)
        balance_text = """
        <b>Balance Information</b>
        Balance: $balance
        Equity: $equity
        Available: $available
        """
        send_message(tg, balance_text, keyboard)

    elseif command == "/position"
        # Safely get position values with defaults
        # position structure: position["long"]["size"], position["long"]["price"]
        long_psize = if haskey(bot.position, "long") && bot.position["long"] !== nothing
            get(bot.position["long"], "size", 0.0)
        else
            0.0
        end
        long_pprice = if haskey(bot.position, "long") && bot.position["long"] !== nothing
            get(bot.position["long"], "price", 0.0)
        else
            0.0
        end
        shrt_psize = if haskey(bot.position, "shrt") && bot.position["shrt"] !== nothing
            get(bot.position["shrt"], "size", 0.0)
        else
            0.0
        end
        shrt_pprice = if haskey(bot.position, "shrt") && bot.position["shrt"] !== nothing
            get(bot.position["shrt"], "price", 0.0)
        else
            0.0
        end
        position_text = """
        <b>Position Information</b>
        Long Position: $long_psize @ $long_pprice
        Short Position: $shrt_psize @ $shrt_pprice
        """
        send_message(tg, position_text, keyboard)

    elseif command == "/config"
        leverage = getcfg("leverage")
        ema_span = getcfg("ema_span")
        grid_spacing = getcfg("grid_spacing")
        config_text = """
        <b>Configuration</b>
        Leverage: $leverage
        EMA Span: $ema_span
        Grid Spacing: $grid_spacing
        """
        send_message(tg, config_text, keyboard)

    elseif command == "/do_long"
        if do_long
            send_message(tg, "Long trading is already enabled.", keyboard)
        else
            setcfg!("do_long", true)
            send_message(tg, "✅ Long trading enabled.", keyboard)
        end

    elseif command == "/stop_long"
        if !do_long
            send_message(tg, "Long trading is already disabled.", keyboard)
        else
            setcfg!("do_long", false)
            send_message(tg, "⛔ Long trading disabled.", keyboard)
        end

    elseif command == "/do_shrt"
        if do_shrt
            send_message(tg, "Short trading is already enabled.", keyboard)
        else
            setcfg!("do_shrt", true)
            send_message(tg, "✅ Short trading enabled.", keyboard)
        end

    elseif command == "/stop_shrt"
        if !do_shrt
            send_message(tg, "Short trading is already disabled.", keyboard)
        else
            setcfg!("do_shrt", false)
            send_message(tg, "⛔ Short trading disabled.", keyboard)
        end

    elseif command == "/stop"
        send_message(tg, "🛑 Stopping bot gracefully...")
        bot.stop_websocket = true
        
    else
        send_message(tg, "Unknown command: $command\nUse /help for available commands.", keyboard)
    end
end

"""
    handle_callback_query(tg::TelegramBot, callback_query::Dict, callback_data::String)

Handle a callback query from inline keyboard buttons.
"""
function handle_callback_query(tg::TelegramBot, callback_query::Dict, callback_data::String)
    bot = tg.bot_instance
    message = callback_query["message"]

    # Create keyboard for response messages
    keyboard_buttons = [
        ["/status", "/balance", "/position"],
        ["/do_long", "/stop_long", "/do_shrt"],
        ["/stop_shrt", "/config", "/help"]
    ]
    keyboard = create_keyboard_markup(keyboard_buttons, resize_keyboard=true)

    # Convert to proper types - JSON3 returns SubString and needs conversion
    chat_id = string(message["chat"]["id"])
    message_id = Int(message["message_id"])

    if callback_data == "confirm"
        # Generic confirm handler
        edit_message_text(tg, chat_id, message_id, "✅ Action confirmed.", keyboard)
    elseif callback_data == "abort"
        # Generic abort handler
        edit_message_text(tg, chat_id, message_id, "❌ Action aborted.", keyboard)
    else
        edit_message_text(tg, chat_id, message_id, "Unknown callback: $callback_data", keyboard)
    end
end

"""
    handle_text_message(tg::TelegramBot, text::String)

Handle non-command text messages (e.g., button responses).
"""
function handle_text_message(tg::TelegramBot, text::String)
    bot = tg.bot_instance

    # Create keyboard
    keyboard_buttons = [
        ["/status", "/balance", "/position"],
        ["/do_long", "/stop_long", "/do_shrt"],
        ["/stop_shrt", "/config", "/help"]
    ]
    keyboard = create_keyboard_markup(keyboard_buttons, resize_keyboard=true)

    # Handle button responses
    if text == "confirm"
        send_message(tg, "✅ Action confirmed.", keyboard)
    elseif text == "abort"
        send_message(tg, "❌ Action aborted.", keyboard)
    else
        send_message(tg, "Received: $text\nUse /help for available commands.", keyboard)
    end
end

"""
    edit_message_text(tg::TelegramBot, chat_id::String, message_id::Int, text::String, reply_markup=nothing)

Edit a message's text (for callback query responses).
"""
function edit_message_text(tg::TelegramBot, chat_id::String, message_id::Int, text::String, reply_markup=nothing)
    url = "https://api.telegram.org/bot$(tg.token)/editMessageText"
    
    # Build payload - handle reply_markup separately to avoid type issues
    if reply_markup !== nothing
        payload = Dict{String, Any}(
            "chat_id" => chat_id,
            "message_id" => message_id,
            "text" => text,
            "parse_mode" => "HTML",
            "reply_markup" => reply_markup
        )
    else
        payload = Dict{String, Any}(
            "chat_id" => chat_id,
            "message_id" => message_id,
            "text" => text,
            "parse_mode" => "HTML"
        )
    end
    
    try
        response = HTTP.post(url, 
            ["Content-Type" => "application/json"],
            JSON3.write(payload)
        )
        return true
    catch e
        @error "Failed to edit message" exception=e
        return false
    end
end

"""
    process_updates(tg::TelegramBot)

Process new Telegram updates.
"""
function process_updates(tg::TelegramBot)
    updates = get_updates(tg)

    if isempty(updates)
        return
    end

    @debug "Received $(length(updates)) updates from Telegram"

    for update in updates
        try
            tg.last_update_id = update["update_id"]

            # Handle callback queries (inline button presses)
            if haskey(update, "callback_query")
                callback_query = update["callback_query"]
                
                # Only process callback queries from the configured chat
                if string(callback_query["message"]["chat"]["id"]) != tg.chat_id
                    @debug "Ignoring callback query from chat $(callback_query["message"]["chat"]["id"]) (not configured chat)"
                    continue
                end
                
                # Answer the callback query to stop the loading animation
                callback_query_id = string(callback_query["id"])
                answer_callback_query(tg, callback_query_id)
                
                # Process the callback data
                if haskey(callback_query, "data")
                    callback_data = String(callback_query["data"])  # Convert SubString to String
                    @info "Processing callback query: $callback_data"
                    handle_callback_query(tg, callback_query, callback_data)
                end
                
            # Handle regular messages
            elseif haskey(update, "message")
                message = update["message"]

                # Only process messages from the configured chat
                if string(message["chat"]["id"]) != tg.chat_id
                    @debug "Ignoring message from chat $(message["chat"]["id"]) (not configured chat)"
                    continue
                end

                if haskey(message, "text")
                    text = String(message["text"])  # Convert SubString to String

                    # Parse command
                    if startswith(text, "/")
                        parts = split(text)
                        command = String(first(parts))  # Convert SubString to String
                        args = length(parts) > 1 ? [String(a) for a in parts[2:end]] : String[]

                        @info "Processing command: $command"
                        handle_command(tg, command, args)
                    else
                        # Handle non-command text (e.g., button responses)
                        @info "Processing text message: $text"
                        handle_text_message(tg, text)
                    end
                end
            end
        catch e
            @error "Error processing update" exception=(e, catch_backtrace()) update=update
        end
    end
end

"""
    start_telegram_bot(tg::TelegramBot)

Start the Telegram bot polling loop.
"""
function start_telegram_bot(tg::TelegramBot)
    @info "Starting Telegram bot polling loop..."

    # Create keyboard for startup message
    keyboard_buttons = [
        ["/status", "/balance", "/position"],
        ["/do_long", "/stop_long", "/do_shrt"],
        ["/stop_shrt", "/config", "/help"]
    ]
    keyboard = create_keyboard_markup(keyboard_buttons, resize_keyboard=true)
    
    startup_message = """
    🤖 <b>PassivBot started and connected to Telegram</b>
    
    Use the buttons below to control the bot, or send /help for available commands.
    """
    
    # Send startup message with keyboard
    if send_message(tg, startup_message, keyboard)
        @info "Telegram startup message sent successfully"
    else
        @warn "Failed to send Telegram startup message"
    end

    # Start polling in an async task
    @async begin
        @info "Telegram polling task started"
        consecutive_errors = 0
        max_consecutive_errors = 5

        while !tg.bot_instance.stop_websocket
            try
                process_updates(tg)
                consecutive_errors = 0  # Reset error counter on success
            catch e
                consecutive_errors += 1
                @error "Error in Telegram bot loop (consecutive errors: $consecutive_errors)" exception=(e, catch_backtrace())

                if consecutive_errors >= max_consecutive_errors
                    @error "Too many consecutive errors, pausing for 30 seconds"
                    for _ in 1:30  # Sleep in 1-second increments to check stop flag
                        tg.bot_instance.stop_websocket && break
                        sleep(1)
                    end
                    consecutive_errors = 0
                else
                    for _ in 1:5  # Sleep in 1-second increments to check stop flag
                        tg.bot_instance.stop_websocket && break
                        sleep(1)
                    end
                end
            end

            # Check stop flag before sleeping
            if tg.bot_instance.stop_websocket
                break
            end

            # Sleep in an interruptible way
            try
                sleep(1)
            catch
                # Task is being interrupted, exit cleanly
                @info "Telegram polling task interrupted, exiting..."
                break
            end
        end

        @info "Telegram polling task stopped"
    end
end

"""
    create_telegram_bot(config::Dict, bot_instance) -> Union{TelegramBot, Nothing}

Create a Telegram bot instance from configuration.
"""
function create_telegram_bot(config::Dict{String,Any}, bot_instance)
    if !haskey(config, "telegram")
        @info "Telegram not configured (no 'telegram' key in config)"
        return nothing
    end

    tg_config = config["telegram"]

    # Check if telegram is enabled
    if haskey(tg_config, "enabled") && !tg_config["enabled"]
        @info "Telegram is disabled in configuration (enabled=false)"
        return nothing
    end

    if !haskey(tg_config, "token") || !haskey(tg_config, "chat_id")
        @warn "Telegram token or chat_id missing from configuration"
        return nothing
    end

    # Check for empty token or chat_id
    token = strip(string(tg_config["token"]))
    chat_id = strip(string(tg_config["chat_id"]))

    if isempty(token) || isempty(chat_id)
        @warn "Telegram token or chat_id is empty"
        return nothing
    end

    # Check for placeholder values
    if occursin("YOUR_", token) || occursin("YOUR_", chat_id)
        @info "Telegram token or chat_id contains placeholder values, skipping initialization"
        @info "Please replace YOUR_TELEGRAM_BOT_TOKEN and YOUR_TELEGRAM_CHAT_ID with actual values"
        return nothing
    end

    @info "Initializing Telegram bot..."
    @debug "Token: $(token[1:min(10, length(token))]...)..."
    @debug "Chat ID: $chat_id"

    tg = TelegramBot(
        String(token),  # Ensure String type, not SubString
        String(chat_id),  # Ensure String type, not SubString
        bot_instance,
        config
    )

    start_telegram_bot(tg)

    @info "Telegram bot initialized and polling started"
    return tg
end

# Export the create function
export create_telegram_bot
