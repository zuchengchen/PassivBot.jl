"""
    PassivBot

A market maker trading bot for cryptocurrency futures (Binance).
Julia port of the Python passivbot with 100% feature parity.

# Modules
- `Core`: Core bot logic and trading engine
- `Binance`: Binance Futures API client
- `Backtest`: Backtesting engine
- `Optimize`: Hyperparameter optimization
- `Utils`: Utility functions
- `Telegram`: Telegram bot interface
- `Analysis`: Trade analysis and metrics
- `Plotting`: Visualization utilities
- `Downloader`: Historical data fetching
"""
module PassivBot

# Import WebSockets at module level
using WebSockets

# Core exports
export AbstractBot, Bot, BinanceBot
export start_bot, start_websocket

# Backtest exports
export backtest, plot_wrap

# Optimize exports
export optimize, backtest_tune

# Utils exports
export load_key_secret, load_user_config, ts_to_date, make_get_filepath
export filter_orders, flatten_dict, sort_dict_keys, get_keys, print_

# Jitted exports (calculation functions) - re-export from Jitted module
export round_, round_up, round_dn, calc_diff
export calc_ema, calc_long_pnl, calc_shrt_pnl
export calc_new_psize_pprice
export calc_min_entry_qty, calc_available_margin, calc_liq_price_binance

# Analysis exports
export analyze_fills, analyze_samples, analyze_backtest
export get_empty_analysis, candidate_to_live_config
export objective_function, result_sampled_default

# Plotting exports
export dump_plots, plot_fills, plot_balance_and_equity
export plot_position_sizes, plot_average_daily_gain

# Downloader exports
export Downloader, get_ticks

# Telegram exports
export TelegramBot, send_message, create_telegram_bot, create_keyboard_markup, answer_callback_query

# Include submodules in correct order (dependencies first)
include("Utils.jl")
include("Jitted.jl")
include("TelegramBot.jl")  # TelegramBot must be included before Core.jl
include("Core.jl")
include("Binance.jl")
include("Backtest.jl")
include("Optimize.jl")
include("Downloader.jl")
include("Analysis.jl")
include("Plotting.jl")

# Re-export Jitted functions at module level
const round_ = Jitted.round_
const round_up = Jitted.round_up
const round_dn = Jitted.round_dn
const calc_diff = Jitted.calc_diff
const calc_ema = Jitted.calc_ema
const calc_long_pnl = Jitted.calc_long_pnl
const calc_shrt_pnl = Jitted.calc_shrt_pnl
const calc_new_psize_pprice = Jitted.calc_new_psize_pprice
const calc_min_entry_qty = Jitted.calc_min_entry_qty
const calc_available_margin = Jitted.calc_available_margin
const calc_liq_price_binance = Jitted.calc_liq_price_binance

end # module PassivBot
