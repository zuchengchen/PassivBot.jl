"""
    Downloader

Historical data downloader for Binance tick data.
Complete port of Python downloader.py with identical functionality.
"""

using HTTP
using JSON3
using Dates
using DataFrames
using NPZ
using ZipFile
using CSV
using Statistics

export Downloader, get_ticks, prep_config, load_live_config, download_ticks, 
       prepare_files, get_dummy_settings, fetch_market_specific_settings

# Configuration constants - matching Python exactly
const TRADE_ID_BATCH_SIZE = 100000
const TRADE_ID_BATCH_MAX = TRADE_ID_BATCH_SIZE - 1

"""
    Downloader

Manages downloading and caching of historical tick data from Binance.
Matches Python Downloader class exactly.
"""
mutable struct Downloader
    config::Dict{String,Any}
    fetch_delay_seconds::Float64
    price_filepath::String
    buyer_maker_filepath::String
    time_filepath::String
    tick_filepath::String
    start_time::Int
    end_time::Int
    daily_base_url::String
    monthly_base_url::String
    filepath::String  # Directory for CSV files
    bot::Any  # BinanceBot instance for API calls
    
    function Downloader(config::Dict{String,Any})
        d = new()
        d.config = config
        d.fetch_delay_seconds = 0.75
        
        # Setup cache filepaths - matching Python exactly
        session_name = config["session_name"]
        caches_dir = config["caches_dirpath"]
        d.price_filepath = joinpath(caches_dir, "$(session_name)_price_cache.npy")
        d.buyer_maker_filepath = joinpath(caches_dir, "$(session_name)_buyer_maker_cache.npy")
        d.time_filepath = joinpath(caches_dir, "$(session_name)_time_cache.npy")
        d.tick_filepath = joinpath(caches_dir, "$(session_name)_ticks_cache.npy")
        
        # Parse start_date
        try
            start_dt = DateTime(config["start_date"])
            d.start_time = Int(round(datetime2unix(start_dt) * 1000))
        catch e
            println("Unrecognized date format for start time.")
            d.start_time = 0
        end
        
        # Parse end_date
        end_date_val = config["end_date"]
        if end_date_val == -1 || end_date_val == "-1"
            d.end_time = -1
        else
            try
                end_dt = DateTime(string(end_date_val))
                d.end_time = Int(round(datetime2unix(end_dt) * 1000))
            catch e
                println("Unrecognized date format for end time: $e")
                d.end_time = -1
            end
        end
        
        # Binance data URLs
        if config["exchange"] == "binance"
            d.daily_base_url = "https://data.binance.vision/data/futures/um/daily/aggTrades/"
            d.monthly_base_url = "https://data.binance.vision/data/futures/um/monthly/aggTrades/"
        end
        
        d.filepath = ""
        d.bot = nothing
        
        return d
    end
end

"""
    validate_dataframe(downloader::Downloader, df::DataFrame) -> (Bool, DataFrame, DataFrame)

Validates a dataframe and detects gaps in it.
Returns: (has_missing, cleaned_df, gaps_df)
"""
function validate_dataframe(downloader::Downloader, df::DataFrame)
    # Sort and deduplicate
    sort!(df, :trade_id)
    unique!(df, :trade_id)
    
    # Detect gaps: where trade_id diff != 1
    trade_ids = df.trade_id
    diffs = diff(trade_ids)
    missing_end_indices = findall(d -> d != 1, diffs) .+ 1
    
    # Build gaps DataFrame
    gaps = DataFrame(start=Int64[], stop=Int64[])  # 'end' is reserved in Julia
    
    if !isempty(missing_end_indices)
        for idx in missing_end_indices
            gap_start = trade_ids[idx - 1]
            gap_end = trade_ids[idx]
            push!(gaps, (start=gap_start, stop=gap_end))
        end
    end
    
    # Check for missing trades at beginning (should align to TRADE_ID_BATCH_SIZE boundary)
    if !isempty(df)
        first_id = df.trade_id[1]
        missing_ids = first_id % TRADE_ID_BATCH_SIZE
        if missing_ids != 0
            push!(gaps, (start=first_id - missing_ids, stop=first_id - 1))
        end
        
        # Check for missing trades at end
        last_id = df.trade_id[end]
        missing_ids_end = last_id % TRADE_ID_BATCH_SIZE
        if missing_ids_end != TRADE_ID_BATCH_MAX
            push!(gaps, (start=last_id, stop=last_id + (TRADE_ID_BATCH_SIZE - missing_ids_end - 1)))
        end
    end
    
    if isempty(gaps)
        return false, df, gaps
    else
        sort!(gaps, :start)
        # Replace 0 with 1 in start column
        gaps.start = [max(1, s) for s in gaps.start]
        return true, df, gaps
    end
end

"""
    read_dataframe(downloader::Downloader, path::String) -> DataFrame

Reads a dataframe with correct data types.
"""
function read_dataframe(downloader::Downloader, path::String)
    try
        df = CSV.read(path, DataFrame,
            types=Dict(
                :trade_id => Int64,
                :price => Float64,
                :qty => Float64,
                :timestamp => Int64,
                :is_buyer_maker => Int8
            )
        )
        return df
    catch e
        # Fallback: read and convert
        df = CSV.read(path, DataFrame)
        if hasproperty(df, :side)
            df.is_buyer_maker = Int8.(df.side .== "Sell")
            select!(df, Not(:side))
        end
        df.trade_id = Int64.(df.trade_id)
        df.price = Float64.(df.price)
        df.qty = Float64.(df.qty)
        df.timestamp = Int64.(df.timestamp)
        df.is_buyer_maker = Int8.(df.is_buyer_maker)
        return df
    end
end

"""
    save_dataframe(downloader::Downloader, df::DataFrame, filename::String, missing::Bool) -> String

Saves a processed dataframe with naming based on first/last trade id and timestamp.
"""
function save_dataframe(downloader::Downloader, df::DataFrame, filename::String, missing::Bool)
    if isempty(df)
        return ""
    end
    
    new_name = "$(df.trade_id[1])_$(df.trade_id[end])_$(df.timestamp[1])_$(df.timestamp[end]).csv"
    
    if new_name != filename
        print_("Saving file $new_name")
        CSV.write(joinpath(downloader.filepath, new_name), df)
        new_name_ret = ""
        try
            rm(joinpath(downloader.filepath, filename))
            print_("Removed file $filename")
        catch
        end
    elseif missing
        print_("Replacing file $filename")
        CSV.write(joinpath(downloader.filepath, filename), df)
        new_name_ret = ""
    else
        new_name_ret = ""
    end
    
    return new_name_ret
end

"""
    transform_ticks(downloader::Downloader, ticks::Vector) -> DataFrame

Transforms tick data into a cleaned dataframe with correct data types.
"""
function transform_ticks(downloader::Downloader, ticks::Vector)
    if isempty(ticks)
        return DataFrame(trade_id=Int64[], price=Float64[], qty=Float64[], 
                        timestamp=Int64[], is_buyer_maker=Int8[])
    end
    
    df = DataFrame(
        trade_id = Int64[t["trade_id"] for t in ticks],
        price = Float64[t["price"] for t in ticks],
        qty = Float64[t["qty"] for t in ticks],
        timestamp = Int64[t["timestamp"] for t in ticks],
        is_buyer_maker = Int8[t["is_buyer_maker"] ? 1 : 0 for t in ticks]
    )
    
    sort!(df, :trade_id)
    unique!(df, :trade_id)
    
    return df
end

"""
    get_filenames(downloader::Downloader) -> Vector{String}

Returns a sorted list of all CSV file names in the directory.
"""
function get_filenames(downloader::Downloader)
    if !isdir(downloader.filepath)
        return String[]
    end
    
    files = filter(f -> endswith(f, ".csv"), readdir(downloader.filepath))
    
    # Sort by first trade_id (first number in filename)
    sort!(files, by = f -> begin
        try
            parts = split(replace(f, ".csv" => ""), "_")
            return parse(Int64, parts[1])
        catch
            return typemax(Int64)
        end
    end)
    
    return files
end

"""
    new_id(first_timestamp, last_timestamp, first_trade_id, length, start_time, prev_div)

Calculates a new id based on several parameters. Uses a weighted approach.
"""
function new_id(first_timestamp::Int, last_timestamp::Int, first_trade_id::Int, 
                length::Int, start_time::Int, prev_div::Vector{Float64})
    div = (last_timestamp - first_timestamp) / length
    push!(prev_div, div)
    forward = Int(round((first_timestamp - start_time) / mean(prev_div)))
    return max(1, first_trade_id - forward), prev_div, forward
end

"""
    find_time(downloader::Downloader, start_time::Int) -> DataFrame

Finds the trades according to the time.
"""
function find_time(downloader::Downloader, start_time::Int)
    # Try time-based fetching first
    try
        ticks = fetch_ticks(downloader.bot, start_time=start_time)
        return transform_ticks(downloader, ticks)
    catch
        # Fall back to ID-based search
        print_("Finding id for start time...")
        ticks = fetch_ticks(downloader.bot)
        df = transform_ticks(downloader, ticks)
        
        if isempty(df)
            return df
        end
        
        highest_id = df.trade_id[end]
        prev_div = Float64[]
        first_ts = df.timestamp[1]
        last_ts = df.timestamp[end]
        first_id = df.trade_id[1]
        len = nrow(df)
        
        while !(start_time >= first_ts && start_time <= last_ts)
            loop_start = time()
            nw_id, prev_div, forward = new_id(first_ts, last_ts, first_id, len, start_time, prev_div)
            
            print_("Current time span from $(df.timestamp[1]) to $(df.timestamp[end]) with earliest trade id $(df.trade_id[1]) estimating distance of $forward trades")
            
            if nw_id > highest_id
                nw_id = highest_id
            end
            
            try
                ticks = fetch_ticks(downloader.bot, from_id=nw_id)
                df = transform_ticks(downloader, ticks)
                if !isempty(df)
                    first_ts = df.timestamp[1]
                    last_ts = df.timestamp[end]
                    first_id = df.trade_id[1]
                    len = nrow(df)
                    if nw_id == 1 && first_ts >= start_time
                        break
                    end
                end
            catch
                println("Failed to fetch or transform...")
            end
            
            sleep(max(0.0, downloader.fetch_delay_seconds - (time() - loop_start)))
        end
        
        print_("Found id for start time!")
        return df[df.timestamp .>= start_time, :]
    end
end

"""
    get_zip(downloader::Downloader, base_url::String, symbol::String, date::String) -> DataFrame

Fetches a full day/month of trades from the Binance repository.
"""
function get_zip(downloader::Downloader, base_url::String, symbol::String, date::String)
    print_("Fetching $symbol $date")
    url = "$(base_url)$(uppercase(symbol))/$(uppercase(symbol))-aggTrades-$(date).zip"
    
    df = DataFrame(trade_id=Int64[], price=Float64[], qty=Float64[], 
                   timestamp=Int64[], is_buyer_maker=Int8[])
    
    try
        response = HTTP.get(url, readtimeout=60)
        zip_data = IOBuffer(response.body)
        zip_reader = ZipFile.Reader(zip_data)
        
        for contained_file in zip_reader.files
            csv_content = read(contained_file, String)
            
            tf = CSV.read(IOBuffer(csv_content), DataFrame,
                header=["trade_id", "price", "qty", "first", "last", "timestamp", "is_buyer_maker"],
                skipto=2
            )
            
            # Drop first and last columns
            select!(tf, Not([:first, :last]))
            
            # Convert types
            tf.trade_id = Int64.(tf.trade_id)
            tf.price = Float64.(tf.price)
            tf.qty = Float64.(tf.qty)
            tf.timestamp = Int64.(tf.timestamp)
            tf.is_buyer_maker = Int8.(tf.is_buyer_maker)
            
            sort!(tf, :trade_id)
            unique!(tf, :trade_id)
            
            if isempty(df)
                df = tf
            else
                df = vcat(df, tf)
            end
        end
        
        close(zip_reader)
    catch e
        println("Failed to fetch $date: $e")
    end
    
    return df
end

"""
    download_ticks(downloader::Downloader)

Searches for previously downloaded files and fills gaps in them if necessary.
Downloads any missing data based on the specified time frame.
"""
function download_ticks(downloader::Downloader)
    # Setup filepath for CSV storage
    if haskey(downloader.config, "historical_data_path") && !isempty(get(downloader.config, "historical_data_path", ""))
        downloader.filepath = make_get_filepath(joinpath(
            downloader.config["historical_data_path"],
            "data",
            "historical",
            downloader.config["symbol"],
            "agg_trades",
            ""
        ))
    else
        downloader.filepath = make_get_filepath(joinpath(
            "data",
            "historical",
            downloader.config["symbol"],
            "agg_trades",
            ""
        ))
    end
    
    # Create bot for API calls
    if downloader.config["exchange"] == "binance"
        dummy_settings = get_dummy_settings(
            downloader.config["user"],
            downloader.config["exchange"],
            downloader.config["symbol"]
        )
        downloader.bot = BinanceBot(dummy_settings)
        init!(downloader.bot)
    else
        println("$(downloader.config["exchange"]) not found")
        return
    end
    
    filenames = get_filenames(downloader)
    mod_files = String[]
    highest_id = 0
    
    # Process existing files and fill gaps
    for f in filenames
        first_time = typemax(Int64)
        last_time = typemax(Int64)
        try
            parts = split(replace(f, ".csv" => ""), "_")
            first_time = parse(Int64, parts[3])
            last_time = parse(Int64, parts[4])
        catch
            # Keep default values
        end
        
        if (last_time >= downloader.start_time && 
            (downloader.end_time == -1 || first_time <= downloader.end_time)) ||
            last_time == typemax(Int64)
            
            print_("Validating file $f")
            df = read_dataframe(downloader, joinpath(downloader.filepath, f))
            missing, df, gaps = validate_dataframe(downloader, df)
            exists = false
            
            if isempty(gaps)
                first_id = df.trade_id[1]
            else
                first_id = min(df.trade_id[1], gaps.start[1])
            end
            
            # Check if file fragment already exists in another file
            if !isempty(gaps) && (f != filenames[end] || 
                !occursin(string(first_id - first_id % TRADE_ID_BATCH_SIZE), f))
                last_id = df.trade_id[end]
                for i in filenames
                    try
                        tmp_parts = split(replace(i, ".csv" => ""), "_")
                        tmp_first_id = parse(Int64, tmp_parts[1])
                        tmp_last_id = parse(Int64, tmp_parts[2])
                        
                        if ((first_id - first_id % TRADE_ID_BATCH_SIZE) == tmp_first_id &&
                            ((first_id - first_id % TRADE_ID_BATCH_SIZE + TRADE_ID_BATCH_MAX) == tmp_last_id ||
                             highest_id == tmp_first_id || highest_id == tmp_last_id ||
                             highest_id > last_id) &&
                            first_id != 1 && i != f)
                            exists = true
                            break
                        end
                    catch
                    end
                end
            end
            
            # Fill gaps via API
            if missing && df.timestamp[end] > downloader.start_time && !exists
                current_time = df.timestamp[end]
                
                for i in 1:nrow(gaps)
                    print_("Filling gaps from id $(gaps.start[i]) to id $(gaps.stop[i])")
                    current_id = gaps.start[i]
                    
                    while (current_id < gaps.stop[i] && 
                           Int(round(time() * 1000)) - current_time > 10000)
                        loop_start = time()
                        
                        try
                            fetched_new_trades = fetch_ticks(downloader.bot, from_id=Int(current_id))
                            tf = transform_ticks(downloader, fetched_new_trades)
                            
                            if isempty(tf)
                                print_("Response empty. No new trades, exiting...")
                                sleep(max(0.0, downloader.fetch_delay_seconds - (time() - loop_start)))
                                break
                            end
                            
                            if current_id == tf.trade_id[end]
                                print_("Same trade ID again. No new trades, exiting...")
                                sleep(max(0.0, downloader.fetch_delay_seconds - (time() - loop_start)))
                                break
                            end
                            
                            current_id = tf.trade_id[end]
                            df = vcat(df, tf)
                            sort!(df, :trade_id)
                            unique!(df, :trade_id)
                            
                            # Trim to batch boundary
                            max_id = gaps.stop[i] - gaps.stop[i] % TRADE_ID_BATCH_SIZE + TRADE_ID_BATCH_MAX
                            df = df[df.trade_id .<= max_id, :]
                            
                            current_time = df.timestamp[end]
                        catch e
                            println("Failed to fetch or transform: $e")
                        end
                        
                        sleep(max(0.0, downloader.fetch_delay_seconds - (time() - loop_start)))
                    end
                end
            end
            
            if !isempty(df) && df.trade_id[end] > highest_id
                highest_id = df.trade_id[end]
            end
            
            if !exists
                # Split at batch boundaries
                batch_starts = findall(id -> id % TRADE_ID_BATCH_SIZE == 0, df.trade_id)
                if length(batch_starts) > 1
                    df = df[1:batch_starts[end]-1, :]
                end
                nf = save_dataframe(downloader, df, f, missing)
                push!(mod_files, nf)
            elseif df.trade_id[1] != 1
                rm(joinpath(downloader.filepath, f))
                print_("Removed file fragment $f")
            end
        end
    end
    
    # Detect chunk gaps between files
    chunk_gaps = Tuple{Int,Int,Int,Int}[]
    filenames = get_filenames(downloader)
    prev_last_id = 0
    prev_last_time = downloader.start_time
    
    for f in filenames
        parts = split(replace(f, ".csv" => ""), "_")
        first_id = parse(Int64, parts[1])
        last_id = parse(Int64, parts[2])
        first_time = parse(Int64, parts[3])
        last_time = parse(Int64, parts[4])
        
        if first_id - 1 != prev_last_id && !(f in mod_files)
            if first_time >= prev_last_time && first_time >= downloader.start_time
                if downloader.end_time != -1 && downloader.end_time < first_time && !(prev_last_time > downloader.end_time)
                    push!(chunk_gaps, (prev_last_time, downloader.end_time, prev_last_id, 0))
                elseif downloader.end_time == -1 || downloader.end_time > first_time
                    push!(chunk_gaps, (prev_last_time, first_time, prev_last_id, first_id))
                end
            end
        end
        
        if first_time >= downloader.start_time || last_time >= downloader.start_time
            # Only update prev_last_id/time if file is within requested range
            if downloader.end_time == -1 || first_time <= downloader.end_time
                prev_last_id = last_id
                prev_last_time = last_time
            end
        end
    end
    
    # Add final gap if needed
    if length(filenames) < 1
        push!(chunk_gaps, (downloader.start_time, downloader.end_time, 0, 0))
    else
        if downloader.end_time == -1
            push!(chunk_gaps, (prev_last_time, downloader.end_time, prev_last_id, 0))
        elseif prev_last_time < downloader.end_time
            push!(chunk_gaps, (prev_last_time, downloader.end_time, prev_last_id, 0))
        end
    end
    
    # Process chunk gaps
    for gap in chunk_gaps
        start_time, end_time, start_id, end_id = gap
        df = DataFrame(trade_id=Int64[], price=Float64[], qty=Float64[], 
                       timestamp=Int64[], is_buyer_maker=Int8[])
        
        current_id = start_id + 1
        current_time = start_time
        
        if downloader.config["exchange"] == "binance"
            # Get earliest available data
            fetched_new_trades = fetch_ticks(downloader.bot, from_id=1)
            tf = transform_ticks(downloader, fetched_new_trades)
            earliest = isempty(tf) ? start_time : tf.timestamp[1]
            
            if earliest > start_time
                start_time = earliest
                current_time = start_time
            end
            
            # Generate date ranges for bulk download
            start_dt = unix2datetime(start_time / 1000)
            end_dt = end_time == -1 ? now(UTC) : unix2datetime(end_time / 1000)
            
            # Monthly dates
            months = String[]
            curr = Date(start_dt)
            while curr <= Date(end_dt)
                month_end = lastdayofmonth(curr)
                if month_end <= Date(end_dt)
                    push!(months, Dates.format(curr, "yyyy-mm"))
                end
                curr = curr + Month(1)
            end
            
            # Calculate new start for daily downloads
            new_start_time = start_time
            if !isempty(months)
                last_month = Date(months[end] * "-01")
                last_month_end = DateTime(lastdayofmonth(last_month)) + Hour(23) + Minute(59) + Second(59)
                new_start_time = Int(round(datetime2unix(last_month_end) * 1000)) + 1
            end
            
            # Daily dates
            days = String[]
            start_daily = unix2datetime(new_start_time / 1000)
            curr = Date(start_daily)
            while curr <= Date(end_dt)
                push!(days, Dates.format(curr, "yyyy-mm-dd"))
                curr = curr + Day(1)
            end
            
            dates = vcat(months, days)
            
            # Download from Binance Vision
            for date in dates
                if length(split(date, "-")) == 2
                    tf = get_zip(downloader, downloader.monthly_base_url, downloader.config["symbol"], date)
                elseif length(split(date, "-")) == 3
                    tf = get_zip(downloader, downloader.daily_base_url, downloader.config["symbol"], date)
                else
                    println("Something wrong with the date $date")
                    tf = DataFrame()
                end
                
                # Filter by time and ID ranges
                if !isempty(tf)
                    tf = tf[tf.timestamp .>= start_time, :]
                    if end_time != -1
                        tf = tf[tf.timestamp .<= end_time, :]
                    end
                    if start_id != 0
                        tf = tf[tf.trade_id .> start_id, :]
                    end
                    if end_id != 0
                        tf = tf[tf.trade_id .<= end_id, :]
                    end
                end
                
                if isempty(df)
                    df = tf
                else
                    df = vcat(df, tf)
                end
                
                if !isempty(df)
                    sort!(df, :trade_id)
                    unique!(df, :trade_id)
                end
                
                # Save complete batches
                if !isempty(df) && ((df.trade_id[1] % TRADE_ID_BATCH_SIZE == 0 && nrow(df) >= TRADE_ID_BATCH_SIZE) ||
                    df.trade_id[1] % TRADE_ID_BATCH_SIZE != 0)
                    
                    # Find trade IDs that are batch boundaries
                    batch_boundary_ids = filter(id -> id % TRADE_ID_BATCH_SIZE == 0, df.trade_id)
                    for batch_start_id in batch_boundary_ids
                        # Find the row index for this batch boundary
                        batch_idx = findfirst(==(batch_start_id), df.trade_id)
                        if batch_idx !== nothing && batch_idx > 1
                            batch_df = df[(df.trade_id .>= batch_start_id - TRADE_ID_BATCH_SIZE) .& 
                                         (df.trade_id .< batch_start_id), :]
                            save_dataframe(downloader, batch_df, "", true)
                            df = df[df.trade_id .>= batch_start_id, :]
                        end
                    end
                end
                
                if !isempty(df)
                    start_id = df.trade_id[1] - 1
                    start_time = df.timestamp[1]
                    current_time = df.timestamp[end]
                    current_id = df.trade_id[end] + 1
                end
            end
        end
        
        # Find starting point if no data yet
        if start_id == 0 && isempty(df)
            df = find_time(downloader, start_time)
            if !isempty(df)
                current_id = df.trade_id[end] + 1
                current_time = df.timestamp[end]
            end
        end
        
        # Set boundaries
        final_end_id = end_id == 0 ? typemax(Int64) : end_id - 1
        final_end_time = end_time == -1 ? typemax(Int64) : end_time
        
        # Download remaining via API
        if !isempty(df) && current_id <= final_end_id && current_time <= final_end_time &&
           Int(round(time() * 1000)) - current_time > 10000
            
            if final_end_time == typemax(Int64)
                print_("Downloading from $(ts_to_date(Float64(current_time) / 1000)) to current time...")
            else
                print_("Downloading from $(ts_to_date(Float64(current_time) / 1000)) to $(ts_to_date(Float64(final_end_time) / 1000))")
            end
        end
        
        while current_id <= final_end_id && current_time <= final_end_time &&
              Int(round(time() * 1000)) - current_time > 10000
            
            loop_start = time()
            fetched_new_trades = fetch_ticks(downloader.bot, from_id=Int(current_id))
            tf = transform_ticks(downloader, fetched_new_trades)
            
            if isempty(tf)
                print_("Response empty. No new trades, exiting...")
                sleep(max(0.0, downloader.fetch_delay_seconds - (time() - loop_start)))
                break
            end
            
            if current_id == tf.trade_id[end]
                print_("Same trade ID again. No new trades, exiting...")
                sleep(max(0.0, downloader.fetch_delay_seconds - (time() - loop_start)))
                break
            end
            
            df = vcat(df, tf)
            sort!(df, :trade_id)
            unique!(df, :trade_id)
            
            current_time = tf.timestamp[end]
            current_id = tf.trade_id[end] + 1
            
            # Save complete batches
            batch_starts = findall(id -> id % TRADE_ID_BATCH_SIZE == 0, df.trade_id)
            if !isempty(batch_starts) && nrow(df) > 1
                if df.trade_id[1] % TRADE_ID_BATCH_SIZE == 0 && length(batch_starts) > 1
                    save_dataframe(downloader, df[1:batch_starts[end]-1, :], "", true)
                    df = df[batch_starts[end]:end, :]
                elseif df.trade_id[1] % TRADE_ID_BATCH_SIZE != 0 && length(batch_starts) == 1
                    save_dataframe(downloader, df[1:batch_starts[end]-1, :], "", true)
                    df = df[batch_starts[end]:end, :]
                end
            end
            
            sleep(max(0.0, downloader.fetch_delay_seconds - (time() - loop_start)))
        end
        
        # Save remaining data
        if !isempty(df)
            df = df[df.timestamp .>= start_time, :]
            if start_id != 0 && !isempty(df)
                df = df[df.trade_id .> start_id, :]
            elseif final_end_id != typemax(Int64) && !isempty(df)
                df = df[df.trade_id .<= final_end_id, :]
            elseif final_end_time != typemax(Int64) && !isempty(df)
                df = df[df.timestamp .<= final_end_time, :]
            end
            if !isempty(df)
                save_dataframe(downloader, df, "", true)
            end
        end
    end
end

"""
    prepare_files(downloader::Downloader; single_file::Bool=false)

Takes downloaded data and prepares numpy arrays for use in backtesting.
"""
function prepare_files(downloader::Downloader; single_file::Bool=false)
    filenames = get_filenames(downloader)
    
    # Find start index
    start_index = 1
    for i in 1:length(filenames)
        parts = split(replace(filenames[i], ".csv" => ""), "_")
        file_start = parse(Int64, parts[3])
        file_end = parse(Int64, parts[4])
        if file_start <= downloader.start_time <= file_end
            start_index = i
            break
        end
    end
    
    # Find end index
    end_index = length(filenames)
    if downloader.end_time != -1
        for i in 1:length(filenames)
            parts = split(replace(filenames[i], ".csv" => ""), "_")
            file_start = parse(Int64, parts[3])
            file_end = parse(Int64, parts[4])
            if file_start <= downloader.end_time <= file_end
                end_index = i
                break
            end
        end
    end
    
    filenames = filenames[start_index:end_index]
    
    if isempty(filenames)
        error("No data files found for the specified date range ($(ts_to_date(Float64(downloader.start_time) / 1000)) to $(ts_to_date(Float64(downloader.end_time) / 1000))). The symbol may not have existed during this period, or data download failed.")
    end
    
    chunks = DataFrame[]
    df = DataFrame()
    
    for (idx, f) in enumerate(filenames)
        if single_file
            chunk = CSV.read(joinpath(downloader.filepath, f), DataFrame,
                select=[:price, :is_buyer_maker, :timestamp, :qty],
                types=Dict(:price => Float64, :is_buyer_maker => Float64, 
                          :timestamp => Float64, :qty => Float64)
            )
        else
            chunk = CSV.read(joinpath(downloader.filepath, f), DataFrame,
                select=[:timestamp, :price, :is_buyer_maker, :qty],
                types=Dict(:timestamp => Int64, :price => Float64, 
                          :is_buyer_maker => Int8, :qty => Float64)
            )
        end
        
        # Filter by time range
        if downloader.end_time != -1
            chunk = chunk[(chunk.timestamp .>= downloader.start_time) .& 
                         (chunk.timestamp .<= downloader.end_time), :]
        else
            chunk = chunk[chunk.timestamp .>= downloader.start_time, :]
        end
        
        push!(chunks, chunk)
        
        # Concatenate in batches of 100
        if length(chunks) >= 100
            if isempty(df)
                df = vcat(chunks...)
            else
                pushfirst!(chunks, df)
                df = vcat(chunks...)
            end
            chunks = DataFrame[]
        end
        
        parts = split(replace(f, ".csv" => ""), "_")
        file_ts = parse(Int64, parts[3])
        print("\rloaded chunk of data $f $(ts_to_date(Float64(file_ts) / 1000))     ")
    end
    
    println()
    
    # Concatenate remaining chunks
    if !isempty(chunks)
        if isempty(df)
            df = vcat(chunks...)
        else
            pushfirst!(chunks, df)
            df = vcat(chunks...)
        end
    end
    
    # Compress ticks: group by (price, is_buyer_maker) changes
    # Create group IDs where price or is_buyer_maker changes
    n = nrow(df)
    if n == 0
        error("No tick data found for the specified date range. Please check if data exists for $(ts_to_date(Float64(downloader.start_time) / 1000)) to $(ts_to_date(Float64(downloader.end_time) / 1000))")
    end
    
    # Identify where (price, is_buyer_maker) changes
    price_changes = vcat([false], df.price[2:end] .!= df.price[1:end-1])
    maker_changes = vcat([false], df.is_buyer_maker[2:end] .!= df.is_buyer_maker[1:end-1])
    changes = price_changes .| maker_changes
    group_ids = cumsum(changes) .+ 1
    
    # Group and aggregate
    df.group_id = group_ids
    compressed_df = combine(groupby(df, :group_id)) do sdf
        DataFrame(
            price = first(sdf.price),
            is_buyer_maker = first(sdf.is_buyer_maker),
            timestamp = first(sdf.timestamp),
            qty = sum(sdf.qty)
        )
    end
    
    # Create compressed ticks array: [price, is_buyer_maker, timestamp]
    compressed_ticks = hcat(
        Float64.(compressed_df.price),
        Float64.(compressed_df.is_buyer_maker),
        Float64.(compressed_df.timestamp)
    )
    
    # Save to numpy files
    mkpath(dirname(downloader.tick_filepath))
    
    if single_file
        print_("Saving single file with $(nrow(compressed_df)) ticks to $(downloader.tick_filepath)...")
        npzwrite(downloader.tick_filepath, compressed_ticks)
        print_("Saved single file!")
    else
        print_("Saving price file with $(nrow(compressed_df)) ticks to $(downloader.price_filepath)...")
        npzwrite(downloader.price_filepath, compressed_ticks[:, 1])
        print_("Saved price file!")
        
        print_("Saving buyer_maker file with $(nrow(compressed_df)) ticks to $(downloader.buyer_maker_filepath)...")
        npzwrite(downloader.buyer_maker_filepath, compressed_ticks[:, 2])
        print_("Saved buyer_maker file!")
        
        print_("Saving timestamp file with $(nrow(compressed_df)) ticks to $(downloader.time_filepath)...")
        npzwrite(downloader.time_filepath, compressed_ticks[:, 3])
        print_("Saved timestamp file!")
    end
end

"""
    get_ticks(downloader::Downloader; single_file::Bool=false)

Main entry point for backtester. Checks if numpy arrays exist and loads them.
If they don't exist or lengths don't match, downloads and creates them.
"""
function get_ticks(downloader::Downloader; single_file::Bool=false)
    if single_file
        if isfile(downloader.tick_filepath)
            print_("Loading cached tick data from $(downloader.tick_filepath)")
            tick_data = npzread(downloader.tick_filepath)
            return tick_data
        end
        download_ticks(downloader)
        prepare_files(downloader, single_file=true)
        tick_data = npzread(downloader.tick_filepath)
        return tick_data
    else
        if isfile(downloader.price_filepath) && 
           isfile(downloader.buyer_maker_filepath) && 
           isfile(downloader.time_filepath)
            
            print_("Loading cached tick data from $(downloader.tick_filepath)")
            price_data = npzread(downloader.price_filepath)
            buyer_maker_data = npzread(downloader.buyer_maker_filepath)
            time_data = npzread(downloader.time_filepath)
            
            if length(price_data) == length(buyer_maker_data) == length(time_data)
                return price_data, buyer_maker_data, time_data
            else
                print_("Tick data does not match, starting over...")
            end
        end
        
        download_ticks(downloader)
        prepare_files(downloader, single_file=false)
        price_data = npzread(downloader.price_filepath)
        buyer_maker_data = npzread(downloader.buyer_maker_filepath)
        time_data = npzread(downloader.time_filepath)
        return price_data, buyer_maker_data, time_data
    end
end

"""
    get_dummy_settings(user::String, exchange::String, symbol::String) -> Dict{String,Any}

Create dummy settings for API initialization.
"""
function get_dummy_settings(user::String, exchange::String, symbol::String)
    keys_list = get_keys()
    settings = Dict{String,Any}(k => 1.0 for k in keys_list)
    settings["user"] = user
    settings["exchange"] = exchange
    settings["symbol"] = symbol
    settings["config_name"] = ""
    settings["logging_level"] = 0
    return settings
end

"""
    fetch_market_specific_settings(user::String, exchange::String, symbol::String) -> Dict{String,Any}

Fetch market-specific settings from exchange.
"""
function fetch_market_specific_settings(user::String, exchange::String, symbol::String)
    tmp_live_settings = get_dummy_settings(user, exchange, symbol)
    settings_from_exchange = Dict{String,Any}()
    
    if exchange == "binance"
        bot = BinanceBot(tmp_live_settings)
        init!(bot)
        settings_from_exchange["maker_fee"] = 0.00018
        settings_from_exchange["taker_fee"] = 0.00036
        settings_from_exchange["exchange"] = "binance"
        settings_from_exchange["max_leverage"] = bot.max_leverage
        settings_from_exchange["min_qty"] = bot.min_qty
        settings_from_exchange["min_cost"] = bot.min_cost
        settings_from_exchange["qty_step"] = bot.qty_step
        settings_from_exchange["price_step"] = bot.price_step
    else
        error("unknown exchange $exchange")
    end
    
    return settings_from_exchange
end

"""
    prep_config(args) -> Dict{String,Any}

Prepare configuration from command-line arguments.
"""
function prep_config(args)
    # Load backtest config
    backtest_config_path = get(args, :backtest_config_path, "configs/backtest/default.json")
    optimize_config_path = get(args, :optimize_config_path, "configs/optimize/default.json")
    
    bc = Dict{String,Any}()
    oc = Dict{String,Any}()
    
    try
        bc = JSON3.read(read(backtest_config_path, String), Dict{String,Any})
    catch e
        error("failed to load backtest config $backtest_config_path: $e")
    end
    
    try
        oc = JSON3.read(read(optimize_config_path, String), Dict{String,Any})
    catch e
        error("failed to load optimize config $optimize_config_path: $e")
    end
    
    config = merge(oc, bc)
    
    # Override with command line args
    for key in ["symbol", "user", "start_date", "end_date"]
        if haskey(args, Symbol(key)) && args[Symbol(key)] != "none"
            config[key] = args[Symbol(key)]
        end
    end
    
    # Generate session name
    end_date = (haskey(config, "end_date") && config["end_date"] != nothing && config["end_date"] != -1) ?
               config["end_date"] : ts_to_date(time())[1:16]
    
    start_clean = replace(replace(replace(config["start_date"], " " => ""), ":" => ""), "." => "")
    end_clean = replace(replace(replace(string(end_date), " " => ""), ":" => ""), "." => "")
    config["session_name"] = "$(start_clean)_$(end_clean)"
    
    # Setup directories
    config["caches_dirpath"] = make_get_filepath(joinpath("data", "caches", config["exchange"], config["symbol"], ""))
    config["optimize_dirpath"] = make_get_filepath(joinpath("results", "optimize", ""))
    config["plots_dirpath"] = make_get_filepath(joinpath("results", "backtests", ""))
    
    # Load or fetch market specific settings
    mss_path = joinpath(config["caches_dirpath"], "market_specific_settings.json")
    if isfile(mss_path)
        market_specific_settings = JSON3.read(read(mss_path, String), Dict{String,Any})
    else
        market_specific_settings = fetch_market_specific_settings(
            config["user"], config["exchange"], config["symbol"]
        )
        open(mss_path, "w") do f
            JSON3.write(f, market_specific_settings)
        end
    end
    
    merge!(config, market_specific_settings)
    
    # Set absolute min/max ranges
    if haskey(config, "ranges")
        for key in ["qty_pct", "ddown_factor", "ema_span", "grid_spacing"]
            if haskey(config["ranges"], key)
                config["ranges"][key][1] = max(0.0, config["ranges"][key][1])
            end
        end
        for key in ["qty_pct"]
            if haskey(config["ranges"], key)
                config["ranges"][key][2] = min(1.0, config["ranges"][key][2])
            end
        end
        if haskey(config["ranges"], "leverage")
            config["ranges"]["leverage"][2] = min(config["ranges"]["leverage"][2], config["max_leverage"])
            config["ranges"]["leverage"][1] = min(config["ranges"]["leverage"][1], config["ranges"]["leverage"][2])
        end
    end
    
    return config
end

"""
    load_live_config(live_config_path::String) -> Dict{String,Any}

Load live configuration from JSON file.
"""
function load_live_config(live_config_path::String)
    try
        live_config = JSON3.read(read(live_config_path, String), Dict{String,Any})
        if !haskey(live_config, "entry_liq_diff_thr")
            live_config["entry_liq_diff_thr"] = get(live_config, "stop_loss_liq_diff", 0.1)
        end
        return live_config
    catch e
        error("failed to load live config $live_config_path: $e")
    end
end

# Helper function for printing (matches Python print_)
function print_(args)
    if isa(args, Vector)
        println(join(string.(args), " "))
    else
        println(args)
    end
end
