# AGENTS.md - PassivBot.jl Coding Guide

This file is for agentic coding assistants working in this repository.

> **📌 Note**: This project is converted from the Python version at `/home/czc/projects/working/stock/passivbot3.5.6`. Some functionality may be incomplete. If you need to add or fix features, please refer to the Python version as reference.

## Project Overview

PassivBot.jl is a high-performance cryptocurrency trading bot for Binance Futures, written in Julia. It's a complete port of the Python passivbot with 100% feature parity and 5-10x performance improvements.

**Architecture**: Market making strategy with EMA-based positioning, grid trading, and hyperparameter optimization.

---

## Essential Commands

### Package Installation
```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

### Testing
```bash
# Run all tests
julia --project=. test/integration_test.jl

# Run a single test function directly
julia --project=. -e 'using PassivBot, Test; @test round_(10.12345, 0.01) == 10.12'
```

### Backtesting
```bash
julia --project=. scripts/backtest.jl configs/live/5x.json
julia --project=. scripts/backtest.jl configs/live/5x.json -p  # with plots
```

### Optimization
```bash
julia --project=. scripts/optimize.jl -n 1000
```

### Live Trading
```bash
julia --project=. scripts/start_bot.jl binance_01 BTCUSDT configs/live/5x.json --restart
```

---

## Code Style Guidelines

### File Organization
```
src/
├── PassivBot.jl     # Main module, includes all submodules
├── Utils.jl          # Utility functions
├── Jitted.jl         # Performance-critical calculations
├── TelegramBot.jl    # Telegram interface (must be before Core.jl)
├── Core.jl           # AbstractBot, Bot struct, core logic
├── Binance.jl        # BinanceBot <: AbstractBot
├── Backtest.jl       # Backtesting engine
├── Optimize.jl       # Hyperparameter optimization
├── Analysis.jl       # Metrics and performance analysis
├── Plotting.jl       # Visualization utilities
└── Downloader.jl     # Historical data fetching
```

**Include order matters**: Dependencies first. TelegramBot.jl before Core.jl.

### Naming Conventions
- **Functions**: `snake_case` - `calc_ema`, `update_position!`, `load_key_secret`
- **Types**: `CamelCase` - `AbstractBot`, `Bot`, `BinanceBot`, `TelegramBot`
- **Constants**: `UPPER_CASE` - `MAX_OPEN_ORDERS_LIMIT`, `PERIODS`
- **Variables**: `snake_case` - `open_orders`, `tick_prices_deque`
- **Boolean predicates**: End with `?` (rare) or use `is_` prefix - `is_buyer_maker`

### Type Annotations
- Use explicit types for function parameters and returns where performance matters:
```julia
function round_(n::Float64, step::Float64, safety_rounding::Int=10)::Float64
```
- Use `Dict{String,Any}` for configuration dictionaries
- Use `Float64` for all numeric trading values (consistency with Python)
- Use `Vector{Dict{String,Any}}` for collections of orders/fills

### Mutating Functions
- Follow Julia convention: mutating functions end with `!`
```julia
function update_position!(bot::AbstractBot)
function set_config!(bot::AbstractBot, config::Dict{String, Any})
```

### Docstrings
- Triple-quoted format, Julia style:
```julia
"""
    calc_ema(alpha::Float64, alpha_::Float64, prev_ema::Float64, new_val::Float64)::Float64

Calculate exponential moving average.
"""
function calc_ema(...)
```

---

## Import Patterns

### Standard Module Pattern
```julia
using SomePackage  # For using exported names
import SomePackage  # For extending functions from package
```

### Common Imports
```julia
using JSON3          # JSON parsing (JSON3.read, JSON3.write)
using HTTP           # HTTP requests
using DataFrames     # Data frames
using Statistics    # mean, std
using Dates         # datetime functions
using SHA           # HMAC signing
using ArgParse      # CLI parsing
```

### Accessing Module Functions
All source files are included in main `PassivBot` module, so functions from other source files are available without explicit imports within the module.

### Pattern for Extending Functions
```julia
# In Binance.jl - extending functions from Core.jl
# No import needed - they share the same module via include()
```

---

## Error Handling

### API Errors
```julia
try
    response = HTTP.post(url, headers, body)
catch e
    @error "Request failed" exception=e
    return nothing  # or rethrow()
end
```

### Configuration Errors
```julia
if !isfile(api_keys_path)
    error("API keys file not found: $api_keys_path")
end
```

### Logging
```julia
@info "Informational message"
@warn "Warning message" key=value
@error "Error message" exception=e
```

---

## Data Structures

### Configuration Dicts
```julia
config = Dict{String,Any}(
    "exchange" => "binance",
    "symbol" => "BTCUSDT",
    "leverage" => 5.0,
    "do_long" => true
)
```

### Order/Fill Dicts
```julia
order = Dict{String,Any}(
    "symbol" => "BTCUSDT",
    "side" => "buy",
    "qty" => 0.001,
    "price" => 50000.0
)
```

### Deque for Rolling Windows
```julia
using DataStructures: Deque
tick_prices_deque = Deque{Float64}()
```

---

## Testing Guidelines

### Test File Structure
```julia
using PassivBot
using Test

@testset "Feature Name" begin
    @test true  # Basic test
    @test approx_value ≈ expected atol=1e-6  # Approximate equality
end
```

### Running Specific Tests
```bash
# Run specific testset (edit test file to only include that testset)
julia --project=. test/integration_test.jl

# Or run inline test
julia --project=. -e 'using PassivBot, Test; @test PassivBot.round_(10.12345, 0.01) == 10.12'
```

---

## JSON Configuration

### Reading JSON
```julia
config = JSON3.read(read("path/to/config.json", String), Dict{String,Any})
```

### Writing JSON
```julia
JSON3.write(config, "path/to/output.json")
```

### String Type Conversion
JSON3 may return `SubString{String}`; convert explicitly:
```julia
key = String(data["key"])  # Ensures String type
```

---

## Constants and Magic Numbers

- **MAX_OPEN_ORDERS_LIMIT**: 1000
- **ORDERS_PER_EXECUTION**: 100
- **PRINT_THROTTLE_INTERVAL**: 0.5 seconds
- **CHECK_FILLS_INTERVAL**: 120 seconds
- **DECIDE_TIMEOUT**: 5 seconds
- **safety_rounding**: 10 (default parameter for rounding functions)

---

## Binance API Patterns

### Request Signing
```julia
function sign_request(bot::BinanceBot, params::Dict)
    query_string = join(["$k=$(params[k])" for k in sort(collect(keys(params)))], '&')
    signature = bytes2hex(hmac_sha256(bot.secret, query_string))
    params["signature"] = signature
    return params
end
```

### Endpoints
- REST: `https://fapi.binance.com`
- WebSocket: `wss://fstream.binance.com`

---

## Performance Notes

- Julia's JIT is fast by default; no Numba equivalent needed
- Use `@inbounds` for tight loops on arrays
- Use `const` for global constants
- Prefer `Float64` for trading calculations (precision matters)
- Use `Vector` over `Dict` for ordered data where possible

---

## Git and Files

### Commit Rule (MANDATORY)

**After completing any file or code modification, you MUST commit the changes immediately.**

Workflow:
1. Complete the modification
2. Run `git add <modified_files>`
3. Commit with a clear message describing what was changed

Commit message format:
```
<type>: <brief description>

- <specific change 1>
- <specific change 2>
- ...
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `refactor`: Code refactoring
- `docs`: Documentation changes
- `style`: Code style/formatting
- `test`: Test additions or modifications
- `chore`: Maintenance tasks

Example:
```bash
git add src/Core.jl
git commit -m "fix: correct position calculation in update_position!

- Fixed rounding error in qty calculation
- Added boundary check for leverage
- Updated related docstring"
```

### .gitignore
- `api-keys.json` - Never commit
- `data/` - Historical data and caches
- `results/` - Backtest and optimization outputs
- `logs/` - Runtime logs
- `*.jl.cov`, `*.jl.mem` - Julia test artifacts

### File Permissions
Scripts use shebang: `#!/usr/bin/env julia`

---

## Common Patterns

### Iterating Dicts
```julia
for (key, value) in dict
    # ...
end
```

### Conditional Key Access
```julia
get(dict, "key", default_value)  # Returns default if key missing
haskey(dict, "key")  # Boolean check
```

### Dict Comprehension
```julia
Dict(k => v for (k, v) in pairs if condition)
```

---

## Telegram Integration

TelegramBot is initialized with token, chat_id, and bot_instance reference:
```julia
telegram = create_telegram_bot(user_config, bot)
```

Commands: `/help`, `/status`, `/balance`, `/position`, `/stop`, `/pause`, `/resume`

---

## Module Exports

Public functions are exported in their respective files. Always add to the export list when making new public APIs. Check `src/PassivBot.jl` for the full export list.
