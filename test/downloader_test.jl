#!/usr/bin/env julia

"""
Downloader tests for PassivBot.jl

Tests the tick data downloading and caching functionality.
"""

using PassivBot
using Test
using DataFrames

println("=" ^ 60)
println("PassivBot.jl Downloader Tests")
println("=" ^ 60)

# Test 1: Downloader struct creation
@testset "Downloader Creation" begin
    config = Dict{String,Any}(
        "symbol" => "BTCUSDT",
        "exchange" => "binance",
        "start_date" => "2024-01-01",
        "end_date" => "2024-01-01",
        "caches_dirpath" => "data/caches",
        "session_name" => "test_session"
    )
    
    d = Downloader(config)
    
    @test d.config["symbol"] == "BTCUSDT"
    @test d.start_time > 0
    @test d.end_time > d.start_time
    @test occursin("test_session", d.tick_filepath)
    
    println("✅ Downloader struct created successfully")
end

# Test 2: ts_to_date functions
@testset "Timestamp Conversion" begin
    # 2024-01-01 00:00:00 UTC = 1704067200000 ms
    ts = Int64(1704067200000)
    
    date_str = PassivBot.ts_to_date(ts)
    @test date_str == "2024-01-01"
    
    datetime_str = PassivBot.ts_to_date_time(ts)
    @test datetime_str == "2024-01-01 00:00:00"
    
    println("✅ Timestamp conversion works correctly")
end

# Test 3: compress_ticks algorithm
@testset "Compress Ticks Algorithm" begin
    # Create test DataFrame with consecutive same-price rows
    df = DataFrame(
        trade_id = [1, 2, 3, 4, 5, 6],
        price = [100.0, 100.0, 101.0, 101.0, 101.0, 100.0],
        qty = [1.0, 2.0, 1.0, 1.0, 1.0, 1.0],
        timestamp = [1000, 1001, 1002, 1003, 1004, 1005],
        is_buyer_maker = [true, true, false, false, false, true]
    )
    
    compressed = PassivBot.compress_ticks(df)
    
    # Should compress to 3 groups:
    # Group 1: price=100, buyer_maker=true (rows 1-2)
    # Group 2: price=101, buyer_maker=false (rows 3-5)
    # Group 3: price=100, buyer_maker=true (row 6)
    @test size(compressed, 1) == 3
    @test size(compressed, 2) == 3
    
    # Check first group
    @test compressed[1, 1] == 100.0  # price
    @test compressed[1, 2] == 1.0    # buyer_maker (true)
    @test compressed[1, 3] == 1000.0 # timestamp
    
    # Check second group
    @test compressed[2, 1] == 101.0  # price
    @test compressed[2, 2] == 0.0    # buyer_maker (false)
    @test compressed[2, 3] == 1002.0 # timestamp
    
    println("✅ compress_ticks algorithm works correctly")
end

# Test 4: Empty DataFrame handling
@testset "Empty DataFrame Handling" begin
    empty_df = DataFrame(
        trade_id = Int[],
        price = Float64[],
        qty = Float64[],
        timestamp = Int[],
        is_buyer_maker = Bool[]
    )
    
    compressed = PassivBot.compress_ticks(empty_df)
    
    @test size(compressed, 1) == 0
    @test size(compressed, 2) == 3
    
    println("✅ Empty DataFrame handled correctly")
end

# Test 5: Cache path generation
@testset "Cache Path Generation" begin
    config = Dict{String,Any}(
        "symbol" => "ETHUSDT",
        "exchange" => "binance",
        "start_date" => "2024-06-01",
        "end_date" => "2024-06-30",
        "caches_dirpath" => "/tmp/test_caches",
        "session_name" => "eth_june"
    )
    
    d = Downloader(config)
    
    @test occursin("eth_june", d.tick_filepath)
    @test occursin("/tmp/test_caches", d.tick_filepath)
    @test endswith(d.tick_filepath, ".bin")
    
    println("✅ Cache paths generated correctly")
end

println("\n" * "=" ^ 60)
println("Downloader Tests Summary")
println("=" ^ 60)
println("✅ All downloader tests passed!")
println("\nNote: Network-dependent tests (actual downloads) are skipped in CI.")
println("Run with real data to verify full functionality:")
println("  julia --project=. scripts/backtest.jl configs/live/5x.json")
println("=" ^ 60)
