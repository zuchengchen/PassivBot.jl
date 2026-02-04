# Draft: PassivBot.jl Backtest System Completion

## Requirements (confirmed)
- Complete Downloader.jl - port from Python downloader.py
- Fix scripts/backtest.jl - make it functional end-to-end
- Complete plot_wrap() in Backtest.jl
- Add missing utility functions

## Technical Decisions
- Use Julia Serialization for caching (instead of numpy)
- Use HTTP.jl for downloads
- Support both HJSON and JSON configs
- Maintain compatibility with existing backtest() function

## Research Findings

### Julia Implementation State
- **Backtest engine (src/Backtest.jl)**: ✅ COMPLETE - 442 lines, full tick simulation
- **Analysis (src/Analysis.jl)**: ✅ COMPLETE - analyze_fills(), analyze_samples(), analyze_backtest()
- **Plotting (src/Plotting.jl)**: ✅ COMPLETE - dump_plots(), all chart functions
- **Downloader (src/Downloader.jl)**: ❌ STUBBED - get_ticks() returns empty array
- **scripts/backtest.jl**: ❌ BLOCKED - prints error, exits (needs Downloader)
- **plot_wrap()**: ⚠️ PARTIAL - calls backtest() but doesn't integrate Analysis/Plotting

### Python Downloader Patterns
- **URL format**: `https://data.binance.vision/data/futures/um/{monthly|daily}/aggTrades/{SYMBOL}/...`
- **ZIP handling**: In-memory download → BytesIO → ZipFile → CSV parse
- **Caching**: 3 separate .npy files (price, buyer_maker, timestamp)
- **compress_ticks()**: Groups consecutive same-price/side ticks, sums qty
- **Rate limiting**: 0.75s delay between requests (sequential, not parallel)
- **Batch size**: 100k trades per CSV file

### Python backtest.py Flow
- main() → prep_config(args) → Downloader.get_ticks() → plot_wrap()
- plot_wrap() → backtest() → analyze_fills() → dump_plots()

## Open Questions
- Test strategy: TDD, tests-after, or none?

## Scope Boundaries
- INCLUDE: Downloader, backtest script, plot_wrap, utility functions
- EXCLUDE: Live trading changes, optimization changes, new features beyond Python parity
