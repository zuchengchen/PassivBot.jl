"""
Jitted.jl - Performance-critical calculations for PassivBot

Ported from Python+Numba jitted.py to pure Julia.
All functions use Float64 for consistency with Python float type.
No module wrapper needed - Julia's JIT is fast by default.
"""

# Create a module to namespace these functions
module Jitted

# All calculation functions are defined here and exported by the main PassivBot module

# ============================================================================
# Utility Functions
# ============================================================================

"""
    round_dynamic(n::Float64, d::Int)::Float64

Round number dynamically based on its magnitude.
If n == 0.0, returns n unchanged.
Otherwise rounds to d significant digits.
"""
function round_dynamic(n::Float64, d::Int)::Float64
    if n == 0.0
        return n
    end
    return round(n, digits=d - Int(floor(log10(abs(n)))) - 1)
end

"""
    compress_float(n::Float64, d::Int)::String

Compress a float to a short string representation.
Rounds large numbers to integers, small numbers dynamically.
Strips leading/trailing zeros for compactness.
"""
function compress_float(n::Float64, d::Int)::String
    if n / 10.0^d >= 1.0
        n = round(n)
    else
        n = round_dynamic(n, d)
    end
    nstr = string(n)
    # Remove trailing zeros after decimal point, and the dot if nothing follows
    if occursin('.', nstr)
        nstr = rstrip(nstr, '0')
        nstr = rstrip(nstr, '.')
    end
    # Compress leading zero: "0.123" -> ".123"
    if startswith(nstr, "0.")
        nstr = nstr[2:end]
    elseif startswith(nstr, "-0.")
        nstr = "-" * nstr[3:end]
    end
    return nstr
end

"""
    round_up(n::Float64, step::Float64, safety_rounding::Int=10)::Float64

Round up to nearest step increment.
"""
function round_up(n::Float64, step::Float64, safety_rounding::Int=10)::Float64
    return round(ceil(round(n / step, digits=safety_rounding)) * step, digits=safety_rounding)
end

"""
    round_dn(n::Float64, step::Float64, safety_rounding::Int=10)::Float64

Round down to nearest step increment.
"""
function round_dn(n::Float64, step::Float64, safety_rounding::Int=10)::Float64
    return round(floor(round(n / step, digits=safety_rounding)) * step, digits=safety_rounding)
end

"""
    round_(n::Float64, step::Float64, safety_rounding::Int=10)::Float64

Round to nearest step increment.
"""
function round_(n::Float64, step::Float64, safety_rounding::Int=10)::Float64
    return round(round(n / step) * step, digits=safety_rounding)
end

"""
    calc_diff(x::Float64, y::Float64)::Float64

Calculate relative difference between x and y.
"""
function calc_diff(x::Float64, y::Float64)::Float64
    return abs(x - y) / abs(y)
end

"""
    nan_to_0(x::Float64)::Float64

Convert NaN to 0.0, otherwise return x.
"""
function nan_to_0(x::Float64)::Float64
    return isnan(x) ? 0.0 : x
end

# ============================================================================
# EMA and Statistics Functions
# ============================================================================

"""
    calc_ema(alpha::Float64, alpha_::Float64, prev_ema::Float64, new_val::Float64)::Float64

Calculate exponential moving average.
"""
function calc_ema(alpha::Float64, alpha_::Float64, prev_ema::Float64, new_val::Float64)::Float64
    return prev_ema * alpha_ + new_val * alpha
end

"""
    calc_emas(xs::Vector{Float64}, span::Int)::Vector{Float64}

Calculate exponential moving averages for entire array.
"""
function calc_emas(xs::Vector{Float64}, span::Int)::Vector{Float64}
    alpha = 2.0 / (span + 1)
    alpha_ = 1.0 - alpha
    emas = similar(xs)
    emas[1] = xs[1]
    @inbounds for i in 2:length(xs)
        emas[i] = emas[i-1] * alpha_ + xs[i] * alpha
    end
    return emas
end

"""
    calc_stds(xs::Vector{Float64}, span::Int)::Vector{Float64}

Calculate rolling standard deviations.
"""
function calc_stds(xs::Vector{Float64}, span::Int)::Vector{Float64}
    stds = zeros(Float64, length(xs))
    if length(stds) <= span
        return stds
    end
    
    xsum = sum(xs[1:span])
    xsum_sq = sum(xs[1:span] .^ 2)
    stds[span] = sqrt((xsum_sq / span) - (xsum / span)^2)
    
    @inbounds for i in (span+1):length(xs)
        xsum += xs[i] - xs[i-span]
        xsum_sq += xs[i]^2 - xs[i-span]^2
        stds[i] = sqrt((xsum_sq / span) - (xsum / span)^2)
    end
    return stds
end

"""
    calc_emas_(alpha::Float64, alpha_::Float64, chunk_size::Int, 
               xs_::Vector{Float64}, first_val::Float64, kc_::Int)::Vector{Float64}

Calculate EMAs for a chunk (internal helper for iter_indicator_chunks).
"""
function calc_emas_(alpha::Float64, alpha_::Float64, chunk_size::Int, 
                    xs_::Vector{Float64}, first_val::Float64, kc_::Int)::Vector{Float64}
    emas_ = Vector{Float64}(undef, chunk_size)
    emas_[1] = first_val
    @inbounds for i in 2:min(length(xs_) - kc_, length(emas_))
        emas_[i] = emas_[i-1] * alpha_ + xs_[kc_ + i] * alpha
    end
    return emas_
end

"""
    calc_first_stds(chunk_size::Int, span::Int, xs_::Vector{Float64})::Tuple{Vector{Float64}, Float64, Float64}

Calculate first chunk of standard deviations (internal helper).
"""
function calc_first_stds(chunk_size::Int, span::Int, xs_::Vector{Float64})::Tuple{Vector{Float64}, Float64, Float64}
    stds_ = zeros(Float64, chunk_size)
    xsum_ = sum(xs_[1:span])
    xsum_sq_ = sum(xs_[1:span] .^ 2)
    stds_[span] = sqrt((xsum_sq_ / span) - (xsum_ / span)^2)
    
    @inbounds for i in (span+1):chunk_size
        xsum_ += xs_[i] - xs_[i-span]
        xsum_sq_ += xs_[i]^2 - xs_[i-span]^2
        stds_[i] = sqrt((xsum_sq_ / span) - (xsum_ / span)^2)
    end
    return stds_, xsum_, xsum_sq_
end

"""
    calc_stds_(chunk_size::Int, span::Int, xs_::Vector{Float64}, 
               xsum_::Float64, xsum_sq_::Float64, kc_::Int)::Tuple{Vector{Float64}, Float64, Float64}

Calculate subsequent chunks of standard deviations (internal helper).
"""
function calc_stds_(chunk_size::Int, span::Int, xs_::Vector{Float64}, 
                    xsum_::Float64, xsum_sq_::Float64, kc_::Int)::Tuple{Vector{Float64}, Float64, Float64}
    new_stds = zeros(Float64, chunk_size)
    xsum_ += xs_[kc_+1] - xs_[kc_+1-span]
    xsum_sq_ += xs_[kc_+1]^2 - xs_[kc_+1-span]^2
    new_stds[1] = sqrt((xsum_sq_ / span) - (xsum_ / span)^2)
    
    @inbounds for i in 2:chunk_size
        xsum_ += xs_[kc_+i] - xs_[kc_+i-span]
        xsum_sq_ += xs_[kc_+i]^2 - xs_[kc_+i-span]^2
        new_stds[i] = sqrt((xsum_sq_ / span) - (xsum_ / span)^2)
    end
    return new_stds, xsum_, xsum_sq_
end

"""
    iter_indicator_chunks(xs::Vector{Float64}, span::Int, chunk_size::Int=65536)

Iterator that yields (emas, stds, chunk_index) for processing large arrays in chunks.
"""
function iter_indicator_chunks(xs::Vector{Float64}, span::Int, chunk_size::Int=65536)
    if length(xs) < span
        return Channel{Tuple{Vector{Float64}, Vector{Float64}, Int}}(0)
    end
    
    chunk_size = max(chunk_size, span)
    n_chunks = Int(round_up(Float64(length(xs)) / Float64(chunk_size), 1.0))
    
    alpha = 2.0 / (span + 1)
    alpha_ = 1.0 - alpha
    
    return Channel{Tuple{Vector{Float64}, Vector{Float64}, Int}}() do ch
        emas = calc_emas_(alpha, alpha_, chunk_size, xs, xs[1], 0)
        stds, xsum, xsum_sq = calc_first_stds(chunk_size, span, xs)
        
        put!(ch, (emas, stds, 0))
        
        for k in 1:(n_chunks-1)
            kc = chunk_size * k
            new_emas = calc_emas_(alpha, alpha_, chunk_size, xs, emas[end] * alpha_ + xs[kc+1] * alpha, kc)
            new_stds, xsum, xsum_sq = calc_stds_(chunk_size, span, xs, xsum, xsum_sq, kc)
            put!(ch, (new_emas, new_stds, k))
            emas, stds = new_emas, new_stds
        end
    end
end

# ============================================================================
# Quantity Calculation Functions
# ============================================================================

"""
    calc_min_entry_qty(price::Float64, qty_step::Float64, min_qty::Float64, min_cost::Float64)::Float64

Calculate minimum entry quantity based on exchange constraints.
"""
function calc_min_entry_qty(price::Float64, qty_step::Float64, min_qty::Float64, min_cost::Float64)::Float64
    return max(
        min_qty,
        round_up(min_cost / price, qty_step)
    )
end

"""
    calc_qty_from_margin(margin::Float64, price::Float64, qty_step::Float64, leverage::Float64)::Float64

Calculate quantity from available margin.
"""
function calc_qty_from_margin(margin::Float64, price::Float64, qty_step::Float64, leverage::Float64)::Float64
    return round_dn(margin * leverage / price, qty_step)
end

"""
    calc_initial_entry_qty(balance::Float64, price::Float64, available_margin::Float64,
                          volatility::Float64, qty_step::Float64, min_qty::Float64,
                          min_cost::Float64, leverage::Float64, qty_pct::Float64,
                          volatility_qty_coeff::Float64)::Float64

Calculate initial entry quantity for opening a position.
"""
function calc_initial_entry_qty(
    balance::Float64,
    price::Float64,
    available_margin::Float64,
    volatility::Float64,
    qty_step::Float64,
    min_qty::Float64,
    min_cost::Float64,
    leverage::Float64,
    qty_pct::Float64,
    volatility_qty_coeff::Float64
)::Float64
    min_entry_qty = calc_min_entry_qty(price, qty_step, min_qty, min_cost)
    qty = round_dn(
        min(
            available_margin * leverage / price,
            max(
                min_entry_qty,
                (balance / price) * leverage * qty_pct * (1.0 + volatility * volatility_qty_coeff)
            )
        ),
        qty_step
    )
    return qty >= min_entry_qty ? qty : 0.0
end

"""
    calc_reentry_qty(psize::Float64, price::Float64, available_margin::Float64,
                    qty_step::Float64, min_qty::Float64, min_cost::Float64,
                    ddown_factor::Float64, leverage::Float64)::Float64

Calculate reentry quantity for adding to existing position.
"""
function calc_reentry_qty(
    psize::Float64,
    price::Float64,
    available_margin::Float64,
    qty_step::Float64,
    min_qty::Float64,
    min_cost::Float64,
    ddown_factor::Float64,
    leverage::Float64
)::Float64
    min_entry_qty = calc_min_entry_qty(price, qty_step, min_qty, min_cost)
    qty = min(
        round_dn(available_margin * leverage / price, qty_step),
        max(min_entry_qty, round_dn(abs(psize) * ddown_factor, qty_step))
    )
    return qty >= min_entry_qty ? qty : 0.0
end

# ============================================================================
# Position and Price Calculation Functions
# ============================================================================

"""
    calc_new_psize_pprice(psize::Float64, pprice::Float64, qty::Float64, 
                         price::Float64, qty_step::Float64)::Tuple{Float64, Float64}

Calculate new position size and average entry price after adding qty at price.
Returns (new_psize, new_pprice).
"""
function calc_new_psize_pprice(
    psize::Float64,
    pprice::Float64,
    qty::Float64,
    price::Float64,
    qty_step::Float64
)::Tuple{Float64, Float64}
    if qty == 0.0
        return psize, pprice
    end
    new_psize = round_(psize + qty, qty_step)
    if new_psize == 0.0
        return 0.0, 0.0
    end
    return new_psize, nan_to_0(pprice) * (psize / new_psize) + price * (qty / new_psize)
end

"""
    calc_long_pnl(entry_price::Float64, close_price::Float64, qty::Float64)::Float64

Calculate profit/loss for long position.
"""
function calc_long_pnl(entry_price::Float64, close_price::Float64, qty::Float64)::Float64
    return abs(qty) * (close_price - entry_price)
end

"""
    calc_shrt_pnl(entry_price::Float64, close_price::Float64, qty::Float64)::Float64

Calculate profit/loss for short position.
"""
function calc_shrt_pnl(entry_price::Float64, close_price::Float64, qty::Float64)::Float64
    return abs(qty) * (entry_price - close_price)
end

"""
    calc_cost(qty::Float64, price::Float64)::Float64

Calculate position cost (notional value).
"""
function calc_cost(qty::Float64, price::Float64)::Float64
    return abs(qty * price)
end

"""
    calc_margin_cost(qty::Float64, price::Float64, leverage::Float64)::Float64

Calculate margin required for position.
"""
function calc_margin_cost(qty::Float64, price::Float64, leverage::Float64)::Float64
    return calc_cost(qty, price) / leverage
end

"""
    calc_available_margin(balance::Float64, long_psize::Float64, long_pprice::Float64,
                         shrt_psize::Float64, shrt_pprice::Float64, last_price::Float64,
                         leverage::Float64)::Float64

Calculate available margin considering current positions and unrealized PnL.
"""
function calc_available_margin(
    balance::Float64,
    long_psize::Float64,
    long_pprice::Float64,
    shrt_psize::Float64,
    shrt_pprice::Float64,
    last_price::Float64,
    leverage::Float64
)::Float64
    used_margin = 0.0
    equity = balance
    
    if long_pprice != 0.0 && long_psize != 0.0
        equity += calc_long_pnl(long_pprice, last_price, long_psize)
        used_margin += calc_cost(long_psize, long_pprice) / leverage
    end
    
    if shrt_pprice != 0.0 && shrt_psize != 0.0
        equity += calc_shrt_pnl(shrt_pprice, last_price, shrt_psize)
        used_margin += calc_cost(shrt_psize, shrt_pprice) / leverage
    end
    
    return max(0.0, equity - used_margin)
end

# ============================================================================
# Liquidation Price Functions
# ============================================================================

"""
    calc_liq_price_binance(balance::Float64, long_psize::Float64, long_pprice::Float64,
                          shrt_psize::Float64, shrt_pprice::Float64, leverage::Float64)::Float64

Calculate liquidation price for Binance futures positions.
"""
function calc_liq_price_binance(
    balance::Float64,
    long_psize::Float64,
    long_pprice::Float64,
    shrt_psize::Float64,
    shrt_pprice::Float64,
    leverage::Float64
)::Float64
    abs_long_psize = abs(long_psize)
    abs_shrt_psize = abs(shrt_psize)
    long_pprice = nan_to_0(long_pprice)
    shrt_pprice = nan_to_0(shrt_pprice)
    
    mml = 0.01
    mms = 0.01
    
    numerator = balance - abs_long_psize * long_pprice + abs_shrt_psize * shrt_pprice
    denom = abs_long_psize * mml + abs_shrt_psize * mms - abs_long_psize + abs_shrt_psize
    
    if denom == 0.0
        return 0.0
    end
    
    return max(0.0, numerator / denom)
end

"""
    calc_bankruptcy_price(balance::Float64, long_psize::Float64, long_pprice::Float64,
                         shrt_psize::Float64, shrt_pprice::Float64)::Float64

Calculate bankruptcy price (price at which equity becomes zero).
"""
function calc_bankruptcy_price(
    balance::Float64,
    long_psize::Float64,
    long_pprice::Float64,
    shrt_psize::Float64,
    shrt_pprice::Float64
)::Float64
    long_pprice = nan_to_0(long_pprice)
    shrt_pprice = nan_to_0(shrt_pprice)
    abs_shrt_psize = abs(shrt_psize)
    
    denominator = long_psize - abs_shrt_psize
    if denominator == 0.0
        return 0.0
    end
    
    liq_price = (-balance + long_psize * long_pprice - abs_shrt_psize * shrt_pprice) / denominator
    return max(0.0, liq_price)
end

# ============================================================================
# Stop Loss Function
# ============================================================================

"""
    calc_stop_loss(balance::Float64, long_psize::Float64, long_pprice::Float64,
                  shrt_psize::Float64, shrt_pprice::Float64, liq_price::Float64,
                  highest_bid::Float64, lowest_ask::Float64, last_price::Float64,
                  available_margin::Float64, do_long::Bool, do_shrt::Bool,
                  qty_step::Float64, min_qty::Float64, min_cost::Float64,
                  leverage::Float64, stop_loss_liq_diff::Float64,
                  stop_loss_pos_pct::Float64)::Tuple{Float64, Float64, Float64, Float64, String}

Calculate stop loss order if liquidation risk is too high.
Returns (qty, price, psize_if_taken, pprice_if_taken, comment).
"""
function calc_stop_loss(
    balance::Float64,
    long_psize::Float64,
    long_pprice::Float64,
    shrt_psize::Float64,
    shrt_pprice::Float64,
    liq_price::Float64,
    highest_bid::Float64,
    lowest_ask::Float64,
    last_price::Float64,
    available_margin::Float64,
    do_long::Bool,
    do_shrt::Bool,
    qty_step::Float64,
    min_qty::Float64,
    min_cost::Float64,
    leverage::Float64,
    stop_loss_liq_diff::Float64,
    stop_loss_pos_pct::Float64
)::Tuple{Float64, Float64, Float64, Float64, String}
    abs_shrt_psize = abs(shrt_psize)
    
    if calc_diff(liq_price, last_price) < stop_loss_liq_diff
        if long_psize > abs_shrt_psize
            stop_loss_qty = min(
                long_psize,
                max(
                    calc_min_entry_qty(lowest_ask, qty_step, min_qty, min_cost),
                    round_dn(long_psize * stop_loss_pos_pct, qty_step)
                )
            )
            
            margin_cost = calc_margin_cost(stop_loss_qty, lowest_ask, leverage)
            if margin_cost < available_margin && do_shrt
                # Add to short position
                shrt_psize, shrt_pprice = calc_new_psize_pprice(
                    shrt_psize, shrt_pprice, -stop_loss_qty, lowest_ask, qty_step
                )
                return (-stop_loss_qty, lowest_ask, shrt_psize, shrt_pprice, "stop_loss_shrt_entry")
            else
                # Reduce long position
                long_psize = round_(long_psize - stop_loss_qty, qty_step)
                return (-stop_loss_qty, lowest_ask, long_psize, long_pprice, "stop_loss_long_close")
            end
        else
            stop_loss_qty = min(
                abs_shrt_psize,
                max(
                    calc_min_entry_qty(highest_bid, qty_step, min_qty, min_cost),
                    round_dn(abs_shrt_psize * stop_loss_pos_pct, qty_step)
                )
            )
            
            margin_cost = calc_margin_cost(stop_loss_qty, highest_bid, leverage)
            if margin_cost < available_margin && do_long
                # Add to long position
                long_psize, long_pprice = calc_new_psize_pprice(
                    long_psize, long_pprice, stop_loss_qty, highest_bid, qty_step
                )
                return (stop_loss_qty, highest_bid, long_psize, long_pprice, "stop_loss_long_entry")
            else
                # Reduce short position
                shrt_psize = round_(shrt_psize + stop_loss_qty, qty_step)
                return (stop_loss_qty, highest_bid, shrt_psize, shrt_pprice, "stop_loss_shrt_close")
            end
        end
    end
    
    return (0.0, 0.0, 0.0, 0.0, "")
end

# ============================================================================
# Close Order Iterator Functions
# ============================================================================

"""
    iter_long_closes(balance::Float64, psize::Float64, pprice::Float64, lowest_ask::Float64,
                    do_long::Bool, do_shrt::Bool, qty_step::Float64, price_step::Float64,
                    min_qty::Float64, min_cost::Float64, ddown_factor::Float64,
                    qty_pct::Float64, leverage::Float64, n_close_orders::Float64,
                    grid_spacing::Float64, pos_margin_grid_coeff::Float64,
                    volatility_grid_coeff::Float64, volatility_qty_coeff::Float64,
                    min_markup::Float64, markup_range::Float64, ema_span::Float64,
                    ema_spread::Float64, stop_loss_liq_diff::Float64,
                    stop_loss_pos_pct::Float64, entry_liq_diff_thr::Float64)

Iterator that yields long close orders as (qty, price, psize_if_taken).
"""
function iter_long_closes(
    balance::Float64,
    psize::Float64,
    pprice::Float64,
    lowest_ask::Float64,
    do_long::Bool,
    do_shrt::Bool,
    qty_step::Float64,
    price_step::Float64,
    min_qty::Float64,
    min_cost::Float64,
    ddown_factor::Float64,
    qty_pct::Float64,
    leverage::Float64,
    n_close_orders::Float64,
    grid_spacing::Float64,
    pos_margin_grid_coeff::Float64,
    volatility_grid_coeff::Float64,
    volatility_qty_coeff::Float64,
    min_markup::Float64,
    markup_range::Float64,
    ema_span::Float64,
    ema_spread::Float64,
    stop_loss_liq_diff::Float64,
    stop_loss_pos_pct::Float64,
    entry_liq_diff_thr::Float64
)
    if psize == 0.0 || pprice == 0.0
        # Return an empty channel that's already closed
        ch = Channel{Tuple{Float64, Float64, Float64}}(0)
        close(ch)
        return ch
    end
    
    return Channel{Tuple{Float64, Float64, Float64}}() do ch
        minm = pprice * (1.0 + min_markup)
        
        # Handle single order case
        if Int(n_close_orders) == 1
            prices_raw = [minm]
        else
            prices_raw = range(minm, pprice * (1.0 + min_markup + markup_range), length=Int(n_close_orders))
        end
        
        prices = sort(unique([round_up(p, price_step) for p in prices_raw]))
        prices = filter(p -> p >= lowest_ask, prices)
        
        if length(prices) == 0
            put!(ch, (-psize, max(lowest_ask, round_up(minm, price_step)), 0.0))
        else
            n_orders = Int(min(n_close_orders, length(prices), floor(psize / min_qty)))
            local_psize = psize
            local_lowest_ask = lowest_ask
            
            for price in prices
                if n_orders == 0
                    break
                end
                
                qty = min(
                    local_psize,
                    max(
                        calc_initial_entry_qty(
                            balance, local_lowest_ask, balance, 0.0,
                            qty_step, min_qty, min_cost, leverage,
                            qty_pct, volatility_qty_coeff
                        ),
                        round_up(local_psize / n_orders, qty_step)
                    )
                )
                
                if local_psize != 0.0 && qty / local_psize > 0.75
                    qty = local_psize
                end
                
                if qty == 0.0
                    break
                end
                
                local_psize = round_(local_psize - qty, qty_step)
                put!(ch, (-qty, price, local_psize))
                local_lowest_ask = price
                n_orders -= 1
            end
            
            if local_psize > 0.0
                put!(ch, (-local_psize, max(local_lowest_ask, round_up(minm, price_step)), 0.0))
            end
        end
    end
end

"""
    iter_shrt_closes(balance::Float64, psize::Float64, pprice::Float64, highest_bid::Float64,
                    do_long::Bool, do_shrt::Bool, qty_step::Float64, price_step::Float64,
                    min_qty::Float64, min_cost::Float64, ddown_factor::Float64,
                    qty_pct::Float64, leverage::Float64, n_close_orders::Float64,
                    grid_spacing::Float64, pos_margin_grid_coeff::Float64,
                    volatility_grid_coeff::Float64, volatility_qty_coeff::Float64,
                    min_markup::Float64, markup_range::Float64, ema_span::Float64,
                    ema_spread::Float64, stop_loss_liq_diff::Float64,
                    stop_loss_pos_pct::Float64, entry_liq_diff_thr::Float64)

Iterator that yields short close orders as (qty, price, psize_if_taken).
"""
function iter_shrt_closes(
    balance::Float64,
    psize::Float64,
    pprice::Float64,
    highest_bid::Float64,
    do_long::Bool,
    do_shrt::Bool,
    qty_step::Float64,
    price_step::Float64,
    min_qty::Float64,
    min_cost::Float64,
    ddown_factor::Float64,
    qty_pct::Float64,
    leverage::Float64,
    n_close_orders::Float64,
    grid_spacing::Float64,
    pos_margin_grid_coeff::Float64,
    volatility_grid_coeff::Float64,
    volatility_qty_coeff::Float64,
    min_markup::Float64,
    markup_range::Float64,
    ema_span::Float64,
    ema_spread::Float64,
    stop_loss_liq_diff::Float64,
    stop_loss_pos_pct::Float64,
    entry_liq_diff_thr::Float64
)
    abs_psize = abs(psize)
    if psize == 0.0
        # Return an empty channel that's already closed
        ch = Channel{Tuple{Float64, Float64, Float64}}(0)
        close(ch)
        return ch
    end
    
    return Channel{Tuple{Float64, Float64, Float64}}() do ch
        minm = pprice * (1.0 - min_markup)
        
        # Handle single order case
        if Int(n_close_orders) == 1
            prices_raw = [minm]
        else
            prices_raw = range(minm, pprice * (1.0 - (min_markup + markup_range)), length=Int(n_close_orders))
        end
        
        prices = sort(unique([round_dn(p, price_step) for p in prices_raw]), rev=true)
        prices = filter(p -> p <= highest_bid, prices)
        
        if length(prices) == 0
            put!(ch, (abs_psize, min(highest_bid, round_dn(minm, price_step)), 0.0))
        else
            n_orders = Int(min(n_close_orders, length(prices), floor(abs_psize / min_qty)))
            local_abs_psize = abs_psize
            local_highest_bid = highest_bid
            
            for price in prices
                if n_orders == 0
                    break
                end
                
                qty = min(
                    local_abs_psize,
                    max(
                        calc_initial_entry_qty(
                            balance, local_highest_bid, balance, 0.0,
                            qty_step, min_qty, min_cost, leverage,
                            qty_pct, volatility_qty_coeff
                        ),
                        round_up(local_abs_psize / n_orders, qty_step)
                    )
                )
                
                if local_abs_psize != 0.0 && qty / local_abs_psize > 0.75
                    qty = local_abs_psize
                end
                
                if qty == 0.0
                    break
                end
                
                local_abs_psize = round_(local_abs_psize - qty, qty_step)
                put!(ch, (qty, price, local_abs_psize))
                local_highest_bid = price
                n_orders -= 1
            end
            
            if local_abs_psize > 0.0
                put!(ch, (local_abs_psize, min(local_highest_bid, round_dn(minm, price_step)), 0.0))
            end
        end
    end
end

# ============================================================================
# Entry Order Iterator Function
# ============================================================================

"""
    iter_entries(balance::Float64, long_psize::Float64, long_pprice::Float64,
                shrt_psize::Float64, shrt_pprice::Float64, liq_price::Float64,
                highest_bid::Float64, lowest_ask::Float64, ema::Float64,
                last_price::Float64, volatility::Float64, do_long::Bool, do_shrt::Bool,
                qty_step::Float64, price_step::Float64, min_qty::Float64,
                min_cost::Float64, ddown_factor::Float64, qty_pct::Float64,
                leverage::Float64, n_close_orders::Float64, grid_spacing::Float64,
                pos_margin_grid_coeff::Float64, volatility_grid_coeff::Float64,
                volatility_qty_coeff::Float64, min_markup::Float64,
                markup_range::Float64, ema_span::Float64, ema_spread::Float64,
                stop_loss_liq_diff::Float64, stop_loss_pos_pct::Float64,
                entry_liq_diff_thr::Float64)

Iterator that yields entry orders as (qty, price, new_psize, new_pprice, comment).
"""
function iter_entries(
    balance::Float64,
    long_psize::Float64,
    long_pprice::Float64,
    shrt_psize::Float64,
    shrt_pprice::Float64,
    liq_price::Float64,
    highest_bid::Float64,
    lowest_ask::Float64,
    ema::Float64,
    last_price::Float64,
    volatility::Float64,
    do_long::Bool,
    do_shrt::Bool,
    qty_step::Float64,
    price_step::Float64,
    min_qty::Float64,
    min_cost::Float64,
    ddown_factor::Float64,
    qty_pct::Float64,
    leverage::Float64,
    n_close_orders::Float64,
    grid_spacing::Float64,
    pos_margin_grid_coeff::Float64,
    volatility_grid_coeff::Float64,
    volatility_qty_coeff::Float64,
    min_markup::Float64,
    markup_range::Float64,
    ema_span::Float64,
    ema_spread::Float64,
    stop_loss_liq_diff::Float64,
    stop_loss_pos_pct::Float64,
    entry_liq_diff_thr::Float64
)
    return Channel{Tuple{Float64, Float64, Float64, Float64, String}}() do ch
        available_margin = calc_available_margin(
            balance, long_psize, long_pprice, shrt_psize, shrt_pprice, last_price, leverage
        )
        
        stop_loss_order = calc_stop_loss(
            balance, long_psize, long_pprice, shrt_psize, shrt_pprice, liq_price,
            highest_bid, lowest_ask, last_price, available_margin, do_long, do_shrt,
            qty_step, min_qty, min_cost, leverage, stop_loss_liq_diff, stop_loss_pos_pct
        )
        
        local_long_psize = long_psize
        local_long_pprice = long_pprice
        local_shrt_psize = shrt_psize
        local_shrt_pprice = shrt_pprice
        local_available_margin = available_margin
        
        if stop_loss_order[1] != 0.0
            put!(ch, stop_loss_order)
            if occursin("long", stop_loss_order[5])
                local_long_psize, local_long_pprice = stop_loss_order[3], stop_loss_order[4]
            elseif occursin("shrt", stop_loss_order[5])
                local_shrt_psize, local_shrt_pprice = stop_loss_order[3], stop_loss_order[4]
            end
            if occursin("entry", stop_loss_order[5])
                local_available_margin = max(
                    0.0,
                    local_available_margin - calc_margin_cost(stop_loss_order[1], stop_loss_order[2], leverage)
                )
            elseif occursin("close", stop_loss_order[5])
                local_available_margin += calc_margin_cost(stop_loss_order[1], stop_loss_order[2], leverage)
            end
        end
        
        while true
            local long_entry::Tuple{Float64, Float64, Float64, Float64, String}
            local shrt_entry::Tuple{Float64, Float64, Float64, Float64, String}
            
            if do_long
                if local_long_psize == 0.0
                    price = min(highest_bid, round_dn(ema * (1.0 - ema_spread), price_step))
                    qty = calc_initial_entry_qty(
                        balance, price, local_available_margin, volatility,
                        qty_step, min_qty, min_cost, leverage, qty_pct, volatility_qty_coeff
                    )
                    long_entry = (qty, price, qty, price, "initial_long_entry")
                else
                    modifier = (
                        1.0 + (calc_margin_cost(local_long_psize, local_long_pprice, leverage) / balance) * pos_margin_grid_coeff
                    ) * (1.0 + volatility * volatility_grid_coeff)
                    price = min(
                        round_(highest_bid, price_step),
                        round_dn(local_long_pprice * (1.0 - grid_spacing * modifier), price_step)
                    )
                    if price <= 0.0
                        long_entry = (0.0, 0.0, local_long_psize, local_long_pprice, "long_reentry")
                    else
                        qty = calc_reentry_qty(
                            local_long_psize, price, local_available_margin,
                            qty_step, min_qty, min_cost, ddown_factor, leverage
                        )
                        new_long_psize, new_long_pprice = calc_new_psize_pprice(
                            local_long_psize, local_long_pprice, qty, price, qty_step
                        )
                        bankruptcy_price = calc_bankruptcy_price(
                            balance, new_long_psize, new_long_pprice, local_shrt_psize, local_shrt_pprice
                        )
                        if calc_diff(bankruptcy_price, last_price) < entry_liq_diff_thr
                            long_entry = (0.0, 0.0, local_long_psize, local_long_pprice, "")
                        else
                            long_entry = (qty, price, new_long_psize, new_long_pprice, "long_reentry")
                        end
                    end
                end
            else
                long_entry = (0.0, 0.0, local_long_psize, local_long_pprice, "")
            end
            
            if do_shrt
                if local_shrt_psize == 0.0
                    price = max(lowest_ask, round_up(ema * (1.0 + ema_spread), price_step))
                    qty = -calc_initial_entry_qty(
                        balance, price, local_available_margin, volatility,
                        qty_step, min_qty, min_cost, leverage, qty_pct, volatility_qty_coeff
                    )
                    shrt_entry = (qty, price, qty, price, "initial_shrt_entry")
                else
                    modifier = (
                        1.0 + (calc_margin_cost(local_shrt_psize, local_shrt_pprice, leverage) / balance) * pos_margin_grid_coeff
                    ) * (1.0 + volatility * volatility_grid_coeff)
                    price = max(
                        round_(lowest_ask, price_step),
                        round_dn(local_shrt_pprice * (1.0 + grid_spacing * modifier), price_step)
                    )
                    qty = -calc_reentry_qty(
                        local_shrt_psize, price, local_available_margin,
                        qty_step, min_qty, min_cost, ddown_factor, leverage
                    )
                    new_shrt_psize, new_shrt_pprice = calc_new_psize_pprice(
                        local_shrt_psize, local_shrt_pprice, qty, price, qty_step
                    )
                    bankruptcy_price = calc_bankruptcy_price(
                        balance, local_long_psize, local_long_pprice, new_shrt_psize, new_shrt_pprice
                    )
                    if calc_diff(bankruptcy_price, last_price) < entry_liq_diff_thr
                        shrt_entry = (0.0, 0.0, local_shrt_psize, local_shrt_pprice, "")
                    else
                        shrt_entry = (qty, price, new_shrt_psize, new_shrt_pprice, "shrt_reentry")
                    end
                end
            else
                shrt_entry = (0.0, 0.0, local_shrt_psize, local_shrt_pprice, "")
            end
            
            local long_first::Bool
            if long_entry[1] > 0.0
                if shrt_entry[1] == 0.0
                    long_first = true
                else
                    long_first = calc_diff(long_entry[2], last_price) < calc_diff(shrt_entry[2], last_price)
                end
            elseif shrt_entry[1] < 0.0
                long_first = false
            else
                break
            end
            
            if long_first
                put!(ch, long_entry)
                local_long_psize, local_long_pprice = long_entry[3], long_entry[4]
                if long_entry[2] != 0.0
                    local_available_margin = max(
                        0.0,
                        local_available_margin - calc_margin_cost(long_entry[1], long_entry[2], leverage)
                    )
                end
            else
                put!(ch, shrt_entry)
                local_shrt_psize, local_shrt_pprice = shrt_entry[3], shrt_entry[4]
                if shrt_entry[2] != 0.0
                    local_available_margin = max(
                        0.0,
                        local_available_margin - calc_margin_cost(shrt_entry[1], shrt_entry[2], leverage)
                    )
                end
            end
        end
    end
end

end # module Jitted
