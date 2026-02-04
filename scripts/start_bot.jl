#!/usr/bin/env julia

"""
Start PassivBot live trading with auto-restart capability

Usage:
    julia --project=. scripts/start_bot.jl <account_name> <symbol> <config_path> [options]

Example:
    julia --project=. scripts/start_bot.jl binance_01 BTCUSDT configs/live/5x.json --restart
"""

using PassivBot
using ArgParse
using JSON3
using Dates

function parse_commandline()
    s = ArgParseSettings(
        description = "Start PassivBot live trading",
        version = "0.1.0",
        add_version = true
    )

    @add_arg_table! s begin
        "account_name"
            help = "Account name from api-keys.json"
            required = true
        "symbol"
            help = "Trading symbol (e.g., BTCUSDT)"
            required = true
        "config_path"
            help = "Path to live configuration JSON file"
            required = true
        "--restart", "-r"
            help = "Auto-restart on failure"
            action = :store_true
        "--max-restarts"
            help = "Maximum number of restarts (default: 30)"
            arg_type = Int
            default = 30
        "--restart-delay"
            help = "Delay between restarts in seconds (default: 30)"
            arg_type = Int
            default = 30
    end

    return parse_args(s)
end

function main()
    args = parse_commandline()
    
    account_name = args["account_name"]
    symbol = args["symbol"]
    config_path = args["config_path"]
    auto_restart = args["restart"]
    max_restarts = args["max-restarts"]
    restart_delay = args["restart-delay"]
    
    println("=" ^ 60)
    println("PassivBot.jl - Live Trading")
    println("=" ^ 60)
    println("Account: $account_name")
    println("Symbol: $symbol")
    println("Config: $config_path")
    println("Auto-restart: $auto_restart")
    if auto_restart
        println("Max restarts: $max_restarts")
        println("Restart delay: $(restart_delay)s")
    end
    println("=" ^ 60)
    
    # Load configuration
    if !isfile(config_path)
        error("Configuration file not found: $config_path")
    end
    
    config = JSON3.read(read(config_path, String), Dict{String, Any})
    config["user"] = account_name
    config["symbol"] = symbol
    
    # Start bot with optional auto-restart
    if auto_restart
        restart_count = 0
        
        while restart_count < max_restarts
            try
                println("\n[$(now())] Starting bot (attempt $(restart_count + 1)/$max_restarts)...")
                
                # Create fresh bot instance
                bot = BinanceBot(config)
                
                # Start bot (blocking call)
                start_bot(bot)
                
                # If we get here, bot stopped gracefully
                println("\n[$(now())] Bot stopped gracefully")
                break
                
            catch e
                restart_count += 1
                
                if isa(e, InterruptException)
                    println("\n[$(now())] Received interrupt signal, stopping...")
                    break
                end
                
                @error "Bot crashed" exception=(e, catch_backtrace())
                
                if restart_count >= max_restarts
                    println("\n[$(now())] Maximum restart attempts ($max_restarts) reached, aborting")
                    break
                end
                
                # Countdown to restart
                println("\n[$(now())] Restarting in $restart_delay seconds...")
                for i in restart_delay:-1:1
                    print("\rRestarting in $i seconds...   ")
                    sleep(1)
                end
                println("\n")
            end
        end
    else
        # Single run without restart
        try
            bot = BinanceBot(config)
            start_bot(bot)
            println("\n[$(now())] Bot stopped gracefully")
        catch e
            if isa(e, InterruptException)
                println("\n[$(now())] Received interrupt signal, stopping...")
            else
                @error "Bot crashed" exception=(e, catch_backtrace())
                rethrow(e)
            end
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
