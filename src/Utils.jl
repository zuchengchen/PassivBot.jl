"""
    Utils

Utility functions for PassivBot.
"""

using JSON3
using Dates

export load_key_secret, load_user_config, ts_to_date, make_get_filepath, sort_dict_keys
export print_, flatten_dict, filter_orders, get_keys

"""
    load_key_secret(exchange::String, user::String) -> (String, String)

Load API key and secret from api-keys.json file.
"""
function load_key_secret(exchange::String, user::String)
    api_keys_path = "api-keys.json"
    
    if !isfile(api_keys_path)
        error("API keys file not found: $api_keys_path")
    end
    
    try
        keyfile = JSON3.read(read(api_keys_path, String))
        
        if haskey(keyfile, user) && keyfile[user]["exchange"] == exchange
            return (String(keyfile[user]["key"]), String(keyfile[user]["secret"]))
        else
            error("User $user not found or exchange mismatch in API keys file")
        end
    catch e
        error("Error reading API keys: $e")
    end
end

"""
    load_user_config(exchange::String, user::String) -> Dict{String,Any}

Load complete user configuration from api-keys.json file, including telegram settings.
Ensures all string values are converted to String type (not SubString).
"""
function load_user_config(exchange::String, user::String)
    api_keys_path = "api-keys.json"

    if !isfile(api_keys_path)
        error("API keys file not found: $api_keys_path")
    end

    try
        keyfile = JSON3.read(read(api_keys_path, String), Dict{String,Any})

        if haskey(keyfile, user) && keyfile[user]["exchange"] == exchange
            user_config = keyfile[user]

            # Convert telegram config strings to String type if present
            if haskey(user_config, "telegram")
                tg_config = user_config["telegram"]
                if haskey(tg_config, "token")
                    tg_config["token"] = String(tg_config["token"])
                end
                if haskey(tg_config, "chat_id")
                    tg_config["chat_id"] = String(tg_config["chat_id"])
                end
            end

            return user_config
        else
            error("User $user not found or exchange mismatch in API keys file")
        end
    catch e
        error("Error reading API keys: $e")
    end
end

"""
    ts_to_date(timestamp::Float64) -> String

Convert Unix timestamp to ISO date string.
"""
function ts_to_date(timestamp::Float64)
    dt = unix2datetime(timestamp)
    return replace(string(dt), " " => "T")
end

"""
    make_get_filepath(filepath::String) -> String

Create directory structure for filepath if it doesn't exist.
"""
function make_get_filepath(filepath::String)
    dirpath = endswith(filepath, "/") ? filepath : dirname(filepath)
    
    if !isdir(dirpath)
        mkpath(dirpath)
    end
    
    return filepath
end

"""
    sort_dict_keys(d::Dict) -> Dict

Recursively sort dictionary keys.
"""
function sort_dict_keys(d::Dict)
    sorted = Dict()
    for key in sort(collect(keys(d)))
        value = d[key]
        if isa(value, Dict)
            sorted[key] = sort_dict_keys(value)
        elseif isa(value, Vector)
            sorted[key] = [isa(e, Dict) ? sort_dict_keys(e) : e for e in value]
        else
            sorted[key] = value
        end
    end
    return sorted
end

"""
    flatten_dict(d::Dict, parent_key::String="", sep::String="_") -> Dict

Flatten nested dictionary.
"""
function flatten_dict(d::Dict, parent_key::String="", sep::String="_")
    items = []
    
    for (k, v) in d
        new_key = isempty(parent_key) ? k : parent_key * sep * k
        
        if isa(v, Dict)
            append!(items, collect(flatten_dict(v, new_key, sep)))
        else
            push!(items, new_key => v)
        end
    end
    
    return Dict(items)
end

"""
    print_(args::Vector, r::Bool=false, n::Bool=false) -> String

Print with timestamp prefix.
"""
function print_(args::Vector; r::Bool=false, n::Bool=false)
    line = ts_to_date(time())[1:19] * "  "
    line *= join(string.(args), " ")
    
    if n
        print("\n" * line * " ")
    elseif r
        print("\r" * line * " ")
    else
        println(line)
    end
    
    return line
end

"""
    filter_orders(actual_orders::Vector{Dict}, ideal_orders::Vector{Dict}, 
                  keys::Vector{String}=["symbol", "side", "qty", "price"]) -> (Vector{Dict}, Vector{Dict})

Filter orders to determine which to cancel and which to create.
Returns (orders_to_delete, orders_to_create).
"""
function filter_orders(actual_orders::Vector{Dict{String,Any}}, 
                      ideal_orders::Vector;
                      keys::Vector{String}=["symbol", "side", "qty", "price"])
    if isempty(actual_orders)
        return (Dict{String,Any}[], ideal_orders)
    end
    
    if isempty(ideal_orders)
        return (actual_orders, Dict{String,Any}[])
    end
    
    actual_orders = copy(actual_orders)
    orders_to_create = Dict{String,Any}[]
    
    # Crop orders to specified keys
    ideal_orders_cropped = [Dict(k => o[k] for k in keys) for o in ideal_orders]
    actual_orders_cropped = [Dict(k => o[k] for k in keys) for o in actual_orders]
    
    for (ioc, io) in zip(ideal_orders_cropped, ideal_orders)
        # Find matches
        matches = [(aoc, ao) for (aoc, ao) in zip(actual_orders_cropped, actual_orders) if aoc == ioc]
        
        if !isempty(matches)
            # Remove first match
            idx = findfirst(x -> x == matches[1][1], actual_orders_cropped)
            deleteat!(actual_orders, idx)
            deleteat!(actual_orders_cropped, idx)
        else
            push!(orders_to_create, io)
        end
    end
    
    return (actual_orders, orders_to_create)
end

"""
    get_keys() -> Vector{String}

Get list of configuration keys.
"""
function get_keys()
    return [
        "do_long",
        "do_shrt",
        "qty_step",
        "price_step",
        "min_qty",
        "min_cost",
        "ddown_factor",
        "qty_pct",
        "leverage",
        "n_close_orders",
        "grid_spacing",
        "pos_margin_grid_coeff",
        "volatility_grid_coeff",
        "volatility_qty_coeff",
        "min_markup",
        "markup_range",
        "ema_span",
        "ema_spread",
        "stop_loss_liq_diff",
        "stop_loss_pos_pct",
        "entry_liq_diff_thr"
    ]
end
