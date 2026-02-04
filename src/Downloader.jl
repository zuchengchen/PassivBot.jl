"""
    Downloader

Historical data downloader for Binance tick data.
Simplified version - focuses on core functionality.
"""

using HTTP
using JSON3
using Dates
using DataFrames
using Serialization
using ZipFile
using CSV

export Downloader, get_ticks, prep_config, load_live_config, download_ticks, compress_ticks

"""
    Downloader

Manages downloading and caching of historical tick data from Binance.
"""
mutable struct Downloader
    config::Dict{String,Any}
    price_filepath::String
    buyer_maker_filepath::String
    time_filepath::String
    tick_filepath::String
    start_time::Int
    end_time::Int
    daily_base_url::String
    monthly_base_url::String
    
    function Downloader(config::Dict{String,Any})
        d = new()
        d.config = config
        
        # Setup cache filepaths
        session_name = config["session_name"]
        caches_dir = config["caches_dirpath"]
        d.price_filepath = joinpath(caches_dir, "$(session_name)_price_cache.bin")
        d.buyer_maker_filepath = joinpath(caches_dir, "$(session_name)_buyer_maker_cache.bin")
        d.time_filepath = joinpath(caches_dir, "$(session_name)_time_cache.bin")
        d.tick_filepath = joinpath(caches_dir, "$(session_name)_ticks_cache.bin")
        
        # Parse dates
        d.start_time = Int(round(datetime2unix(DateTime(config["start_date"])) * 1000))
        if config["end_date"] == -1
            d.end_time = -1
        else
            # Set end_time to end of day (23:59:59.999)
            end_date = DateTime(config["end_date"])
            end_of_day = end_date + Day(1) - Millisecond(1)
            d.end_time = Int(round(datetime2unix(end_of_day) * 1000))
        end
        
        # Binance data URLs
        if config["exchange"] == "binance"
            d.daily_base_url = "https://data.binance.vision/data/futures/um/daily/aggTrades/"
            d.monthly_base_url = "https://data.binance.vision/data/futures/um/monthly/aggTrades/"
        end
        
        return d
    end
end

"""
    download_ticks(downloader::Downloader)::DataFrame

Download tick data from Binance Vision.
Returns DataFrame with columns: trade_id, price, qty, timestamp, is_buyer_maker
"""
function download_ticks(downloader::Downloader)::DataFrame
    symbol = downloader.config["symbol"]
    start_date = DateTime(downloader.config["start_date"])
    end_date_str = downloader.config["end_date"]
    end_date = end_date_str == -1 ? now() : DateTime(end_date_str)
    
    # Generate monthly dates (all complete months in range)
    # Use lastdayofmonth to get month-end dates
    months = []
    curr_month = Date(start_date)
    while curr_month <= Date(end_date)
        month_end = lastdayofmonth(curr_month)
        if month_end <= Date(end_date)
            push!(months, Dates.format(curr_month, "yyyy-mm"))
        end
        curr_month = curr_month + Month(1)
    end
    
    # Calculate start date for daily downloads (after last complete month)
    if !isempty(months)
        last_month_date = Date(months[end] * "-01")
        last_month_end = lastdayofmonth(last_month_date)
        daily_start = last_month_end + Day(1)
    else
        daily_start = Date(start_date)
    end
    
    # Generate daily dates from daily_start to end_date
    days = []
    curr_day = daily_start
    while curr_day <= Date(end_date)
        push!(days, Dates.format(curr_day, "yyyy-mm-dd"))
        curr_day = curr_day + Day(1)
    end
    
    # Combine into download list
    dates_to_download = [(m, "monthly") for m in months]
    append!(dates_to_download, [(d, "daily") for d in days])
    
    println("Downloading $(length(dates_to_download)) files for $symbol...")
    
    all_dfs = DataFrame[]
    
    for (date_str, period_type) in dates_to_download
        # Construct URL
        if period_type == "monthly"
            url = "$(downloader.monthly_base_url)$(symbol)/$(symbol)-aggTrades-$(date_str).zip"
        else
            url = "$(downloader.daily_base_url)$(symbol)/$(symbol)-aggTrades-$(date_str).zip"
        end
        
        try
            # Download ZIP file with timeout
            response = HTTP.get(url, readtimeout=30, connect_timeout=10)
            
            # Read ZIP from memory
            zip_data = IOBuffer(response.body)
            zip_reader = ZipFile.Reader(zip_data)
            
            # Read first (and only) file in ZIP
            if length(zip_reader.files) > 0
                csv_file = zip_reader.files[1]
                csv_content = read(csv_file, String)
                
                # Parse CSV with explicit types, skip header row
                df = CSV.read(IOBuffer(csv_content), DataFrame, 
                             header=1,
                             skipto=2,
                             types=[Int64, Float64, Float64, Int64, Int64, Int64, Bool])
                
                # Rename columns
                rename!(df, [:trade_id, :price, :qty, :first, :last, :timestamp, :is_buyer_maker])
                
                # Drop 'first' and 'last' columns
                select!(df, Not([:first, :last]))
                
                push!(all_dfs, df)
                println("Downloaded $date_str: $(nrow(df)) rows")
            end
            
            close(zip_reader)
            
        catch e
            if isa(e, HTTP.Exceptions.StatusError) && e.status == 404
                @warn "File not found (404): $url"
            else
                @warn "Error downloading $date_str" exception=e
            end
        end
        
        # Rate limiting: sleep 0.75s between requests
        sleep(0.75)
    end
    
    # Concatenate all DataFrames
    if isempty(all_dfs)
        return DataFrame(trade_id=Int[], price=Float64[], qty=Float64[], 
                        timestamp=Int[], is_buyer_maker=Bool[])
    end
    
    combined_df = vcat(all_dfs...)
    
    # Sort by timestamp
    sort!(combined_df, :timestamp)
    
    # Filter by start_time and end_time
    filter!(row -> row.timestamp >= downloader.start_time, combined_df)
    if downloader.end_time != -1
        filter!(row -> row.timestamp <= downloader.end_time, combined_df)
    end
    
    println("Total rows after filtering: $(nrow(combined_df))")
    
    return combined_df
end

"""
    compress_ticks(df::DataFrame)::Matrix{Float64}

Compress ticks by grouping consecutive rows with same (price, is_buyer_maker).
Returns 3-column Matrix{Float64}: [price, buyer_maker, timestamp]
"""
function compress_ticks(df::DataFrame)::Matrix{Float64}
    if nrow(df) == 0
        return Matrix{Float64}(undef, 0, 3)
    end
    
    # Create grouping column: increment when (price, is_buyer_maker) changes
    group_ids = zeros(Int, nrow(df))
    group_ids[1] = 1
    current_group = 1
    
    for i in 2:nrow(df)
        if df.price[i] != df.price[i-1] || df.is_buyer_maker[i] != df.is_buyer_maker[i-1]
            current_group += 1
        end
        group_ids[i] = current_group
    end
    
    # Add group column
    df.group_id = group_ids
    
    # Group and aggregate: take first of each group
    compressed_df = combine(groupby(df, :group_id)) do sdf
        DataFrame(
            price = first(sdf.price),
            is_buyer_maker = first(sdf.is_buyer_maker),
            timestamp = first(sdf.timestamp)
        )
    end
    
    # Convert to Matrix{Float64} with 3 columns: [price, buyer_maker, timestamp]
    result = Matrix{Float64}(undef, nrow(compressed_df), 3)
    result[:, 1] = compressed_df.price
    result[:, 2] = Float64.(compressed_df.is_buyer_maker)
    result[:, 3] = Float64.(compressed_df.timestamp)
    
    return result
end

"""
    get_ticks(downloader::Downloader, use_cache::Bool=true) -> Matrix{Float64}

Get historical tick data, either from cache or by downloading.
Returns matrix with columns: [price, buyer_maker, timestamp]
"""
function get_ticks(downloader::Downloader, use_cache::Bool=true)
    # Try to load from cache
    if use_cache && isfile(downloader.tick_filepath)
        println("Loading ticks from cache: $(downloader.tick_filepath)")
        try
            ticks = deserialize(downloader.tick_filepath)
            println("Loaded $(size(ticks, 1)) ticks from cache")
            return ticks
        catch e
            @warn "Failed to load cache, will download" exception=e
        end
    end
    
    # Download data
    println("Downloading tick data from Binance...")
    df = download_ticks(downloader)
    
    # Compress ticks
    println("Compressing ticks...")
    ticks = compress_ticks(df)
    
    # Cache the result
    if !isempty(ticks)
        mkpath(dirname(downloader.tick_filepath))
        serialize(downloader.tick_filepath, ticks)
        println("Cached $(size(ticks, 1)) ticks")
    end
    
    return ticks
end

"""
    prep_config(args) -> Dict{String,Any}

Prepare configuration from command-line arguments.
"""
function prep_config(args)
    # Load backtest config
    backtest_config_path = get(args, :backtest_config_path, "configs/backtest/default.hjson")
    
    # Simplified - would need HJSON parsing
    config = Dict{String,Any}(
        "exchange" => "binance",
        "symbol" => get(args, :symbol, "BTCUSDT"),
        "start_date" => get(args, :start_date, "2023-01-01"),
        "end_date" => get(args, :end_date, "2023-12-31"),
        "session_name" => "backtest_session",
        "caches_dirpath" => "caches",
        "starting_balance" => 1000.0,
        "maker_fee" => 0.0002,
        "taker_fee" => 0.0004,
        "latency_simulation_ms" => 1000
    )
    
    return config
end

"""
    load_live_config(path::String) -> Dict{String,Any}

Load live configuration from JSON file.
"""
function load_live_config(path::String)
    return JSON3.read(read(path, String), Dict{String,Any})
end
