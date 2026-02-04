# PassivBot.jl Backtest System Completion

## TL;DR

> **Quick Summary**: Complete the Julia backtest system by porting Downloader from Python, wiring up the backtest script, and integrating plot_wrap() with existing Analysis/Plotting modules.
> 
> **Deliverables**:
> - Fully functional `src/Downloader.jl` with Binance Vision ZIP downloads and caching
> - Working `scripts/backtest.jl` CLI that runs end-to-end
> - Complete `plot_wrap()` integration with analyze_backtest() and dump_plots()
> - Tests verifying each component
> 
> **Estimated Effort**: Medium (3-5 days)
> **Parallel Execution**: YES - 2 waves
> **Critical Path**: Task 1 → Task 2 → Task 4 → Task 5 → Task 6

---

## Context

### Original Request
Complete the Julia backtest system for PassivBot.jl, referencing the Python version at `/home/czc/projects/working/stock/passivbot3.5.6`.

### Interview Summary
**Key Discussions**:
- Downloader.jl is stubbed (returns empty array) - needs full port from Python
- scripts/backtest.jl blocked by missing tick data loading
- plot_wrap() exists but doesn't call Analysis/Plotting modules
- Analysis.jl and Plotting.jl are COMPLETE and ready to use

**Research Findings**:
- Python uses Binance Vision URLs: `https://data.binance.vision/data/futures/um/{daily|monthly}/aggTrades/{SYMBOL}/...`
- Rate limit: 0.75s fixed delay between requests
- compress_ticks: Groups consecutive same-price/buyer_maker ticks, returns 3 columns only
- Cache format: 3 separate .npy files (Julia will use Serialization)

### Metis Review
**Identified Gaps** (addressed):
- Monthly vs daily URL format switching logic needed
- Cache invalidation when date range changes
- Error handling for 404s and corrupted ZIPs
- DataFrame conversion for dump_plots()

---

## Work Objectives

### Core Objective
Port the Python downloader to Julia and wire up the backtest pipeline so `julia scripts/backtest.jl config.json -p` produces backtest results with plots.

### Concrete Deliverables
- `src/Downloader.jl`: Complete implementation with `get_ticks()`, `download_ticks()`, `compress_ticks()`
- `scripts/backtest.jl`: Functional CLI that loads data, runs backtest, outputs results
- `src/Backtest.jl`: Updated `plot_wrap()` calling analyze_backtest() and dump_plots()
- `test/downloader_test.jl`: Tests for downloader functionality

### Definition of Done
- [ ] `julia --project=. scripts/backtest.jl configs/live/5x.json` completes without error
- [ ] `julia --project=. scripts/backtest.jl configs/live/5x.json -p` generates plots
- [ ] Cache files created and reused on subsequent runs
- [ ] All tests pass: `julia --project=. test/integration_test.jl`

### Must Have
- ZIP download from Binance Vision URLs
- 0.75s rate limiting between requests
- Julia Serialization caching (3 arrays: price, buyer_maker, timestamp)
- compress_ticks() grouping algorithm
- CLI argument parsing for config path and plot flag
- Output directory creation with timestamp

### Must NOT Have (Guardrails)
- ❌ HJSON parsing (use JSON only - out of scope)
- ❌ REST API fallback for tick data (Binance Vision ZIP only)
- ❌ Retry logic or exponential backoff (match Python's simple approach)
- ❌ Multi-symbol parallel downloads (single symbol per run)
- ❌ Checksum validation for ZIPs
- ❌ qty column in compressed output (Python discards it)

---

## Verification Strategy

> **UNIVERSAL RULE: ZERO HUMAN INTERVENTION**
> ALL verification is executed by the agent using tools (Bash, Playwright, etc.).

### Test Decision
- **Infrastructure exists**: YES (`test/integration_test.jl`)
- **Automated tests**: YES (Tests-after)
- **Framework**: Julia Test stdlib

### Agent-Executed QA Scenarios (MANDATORY)

Every task includes specific verification scenarios the executing agent will run directly.

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately):
├── Task 1: Implement Downloader core (download_ticks, compress_ticks)
└── Task 3: Add utility functions to Utils.jl

Wave 2 (After Wave 1):
├── Task 2: Implement get_ticks with caching
└── Task 4: Complete plot_wrap() integration

Wave 3 (After Wave 2):
└── Task 5: Wire up scripts/backtest.jl

Wave 4 (After Wave 3):
└── Task 6: Add tests and final verification

Critical Path: Task 1 → Task 2 → Task 5 → Task 6
Parallel Speedup: ~30% faster than sequential
```

### Dependency Matrix

| Task | Depends On | Blocks | Can Parallelize With |
|------|------------|--------|---------------------|
| 1 | None | 2 | 3 |
| 2 | 1 | 4, 5 | None |
| 3 | None | 4 | 1 |
| 4 | 2, 3 | 5 | None |
| 5 | 2, 4 | 6 | None |
| 6 | 5 | None | None |

---

## TODOs

- [ ] 1. Implement Downloader Core Functions

  **What to do**:
  - Implement `download_ticks(downloader::Downloader)` function
    - Generate date list (monthly for old data, daily for recent)
    - Download ZIP files from Binance Vision URLs
    - Parse CSV with columns: trade_id, price, qty, timestamp, is_buyer_maker
    - Concatenate all DataFrames, sort by timestamp
  - Implement `compress_ticks(df::DataFrame)::Matrix{Float64}`
    - Group consecutive rows with same (price, is_buyer_maker)
    - Return 3-column Matrix: [price, buyer_maker, timestamp]
  - Add HTTP request with 0.75s rate limiting
  - Handle 404 errors gracefully (skip missing dates)

  **Must NOT do**:
  - Add retry logic or exponential backoff
  - Store qty in compressed output
  - Add HJSON parsing

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Core data pipeline implementation requiring careful algorithm porting
  - **Skills**: []
    - No special skills needed - standard Julia development

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Task 3)
  - **Blocks**: Task 2
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `/home/czc/projects/working/stock/passivbot3.5.6/downloader.py:578-626` - Date generation logic (monthly then daily)
  - `/home/czc/projects/working/stock/passivbot3.5.6/downloader.py:865-879` - compress_ticks groupby algorithm
  - `/home/czc/projects/working/stock/passivbot3.5.6/downloader.py:717-755` - Main download loop

  **API/Type References**:
  - `src/Downloader.jl:1-50` - Existing Downloader struct definition
  - URL format: `https://data.binance.vision/data/futures/um/monthly/aggTrades/{SYMBOL}/{SYMBOL}-aggTrades-{YYYY-MM}.zip`
  - URL format: `https://data.binance.vision/data/futures/um/daily/aggTrades/{SYMBOL}/{SYMBOL}-aggTrades-{YYYY-MM-DD}.zip`

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Download single day of tick data
    Tool: Bash (julia REPL)
    Preconditions: Network access, ZipFile.jl and CSV.jl installed
    Steps:
      1. julia --project=. -e '
           using PassivBot, DataFrames
           d = Downloader(Dict("symbol"=>"BTCUSDT","start_date"=>"2024-01-01","end_date"=>"2024-01-01","caches_dirpath"=>"data/caches"))
           df = PassivBot.download_ticks(d)
           println("Rows: ", nrow(df))
           println("Columns: ", names(df))
           @assert nrow(df) > 0 "Should have data"
           @assert "price" in names(df) "Should have price column"
           @assert "timestamp" in names(df) "Should have timestamp column"
         '
      2. Assert: Exit code 0
      3. Assert: Output shows "Rows: " with number > 0
    Expected Result: DataFrame with tick data returned
    Evidence: Terminal output captured

  Scenario: compress_ticks reduces row count
    Tool: Bash (julia REPL)
    Preconditions: download_ticks working
    Steps:
      1. julia --project=. -e '
           using PassivBot, DataFrames
           d = Downloader(Dict("symbol"=>"BTCUSDT","start_date"=>"2024-01-01","end_date"=>"2024-01-01","caches_dirpath"=>"data/caches"))
           df = PassivBot.download_ticks(d)
           raw_rows = nrow(df)
           compressed = PassivBot.compress_ticks(df)
           comp_rows = size(compressed, 1)
           println("Raw: $raw_rows, Compressed: $comp_rows")
           @assert comp_rows < raw_rows "Compression should reduce rows"
           @assert size(compressed, 2) == 3 "Should have 3 columns"
         '
      2. Assert: Exit code 0
      3. Assert: Compressed rows < Raw rows
    Expected Result: Compression ratio > 1
    Evidence: Terminal output showing row counts
  ```

  **Commit**: YES
  - Message: `feat(downloader): implement download_ticks and compress_ticks`
  - Files: `src/Downloader.jl`
  - Pre-commit: QA scenarios pass

---

- [ ] 2. Implement get_ticks with Caching

  **What to do**:
  - Implement `get_ticks(downloader::Downloader, use_cache::Bool=true)::Matrix{Float64}`
    - Check for existing cache files (price, buyer_maker, timestamp arrays)
    - If cache exists and valid: load and return
    - If no cache: call download_ticks(), compress_ticks(), save cache, return
  - Cache file paths: `{caches_dirpath}/{session_name}_{array_name}_cache.bin`
  - Validate cache: all 3 arrays must exist and have equal length
  - Use Julia Serialization for cache format

  **Must NOT do**:
  - Use numpy .npy format (Julia Serialization is fine)
  - Add complex cache invalidation logic

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Straightforward caching wrapper around existing functions
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 2 (sequential after Task 1)
  - **Blocks**: Tasks 4, 5
  - **Blocked By**: Task 1

  **References**:

  **Pattern References**:
  - `/home/czc/projects/working/stock/passivbot3.5.6/downloader.py:955-975` - Cache validation logic
  - `src/Downloader.jl:78-84` - Existing stubbed get_ticks (replace this)

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: First call downloads and caches
    Tool: Bash
    Preconditions: No cache files exist, Task 1 complete
    Steps:
      1. rm -rf data/caches/test_*_cache.bin 2>/dev/null || true
      2. julia --project=. -e '
           using PassivBot
           d = Downloader(Dict("symbol"=>"BTCUSDT","start_date"=>"2024-01-01","end_date"=>"2024-01-01","caches_dirpath"=>"data/caches","session_name"=>"test"))
           ticks = get_ticks(d, true)
           println("Ticks shape: ", size(ticks))
           @assert size(ticks, 1) > 0 "Should have rows"
           @assert size(ticks, 2) == 3 "Should have 3 columns"
         '
      3. ls data/caches/test_*_cache.bin | wc -l
      4. Assert: Count equals 3 (price, buyer_maker, timestamp)
    Expected Result: Cache files created
    Evidence: ls output showing 3 cache files

  Scenario: Second call loads from cache (fast)
    Tool: Bash
    Preconditions: Cache files exist from previous scenario
    Steps:
      1. time julia --project=. -e '
           using PassivBot
           d = Downloader(Dict("symbol"=>"BTCUSDT","start_date"=>"2024-01-01","end_date"=>"2024-01-01","caches_dirpath"=>"data/caches","session_name"=>"test"))
           ticks = get_ticks(d, true)
           println("Loaded from cache: ", size(ticks))
         '
      2. Assert: Execution time < 5 seconds (no network)
    Expected Result: Fast load from cache
    Evidence: time output showing < 5s
  ```

  **Commit**: YES
  - Message: `feat(downloader): add caching to get_ticks`
  - Files: `src/Downloader.jl`
  - Pre-commit: QA scenarios pass

---

- [ ] 3. Add Utility Functions to Utils.jl

  **What to do**:
  - Add `ts_to_date(ts::Int64)::String` - Convert millisecond timestamp to "YYYY-MM-DD" string
  - Add `ts_to_date_time(ts::Int64)::String` - Convert to "YYYY-MM-DD HH:MM:SS" string
  - Add `make_get_filepath(dirpath::String)::String` - Create directory if not exists, return path
  - Verify `round_` function exists (already in Utils.jl)

  **Must NOT do**:
  - Add functions that already exist
  - Change existing function signatures

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Simple utility functions, minimal logic
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Task 1)
  - **Blocks**: Task 4
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `src/Utils.jl` - Existing utility functions (follow same style)
  - `/home/czc/projects/working/stock/passivbot3.5.6/procedures.py:ts_to_date` - Python reference

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: ts_to_date converts correctly
    Tool: Bash
    Steps:
      1. julia --project=. -e '
           using PassivBot
           # 2024-01-01 00:00:00 UTC = 1704067200000 ms
           result = PassivBot.ts_to_date(1704067200000)
           println("Result: $result")
           @assert result == "2024-01-01" "Expected 2024-01-01, got $result"
         '
      2. Assert: Exit code 0
    Expected Result: Correct date string
    Evidence: Terminal output

  Scenario: make_get_filepath creates directory
    Tool: Bash
    Steps:
      1. rm -rf /tmp/test_passivbot_dir 2>/dev/null || true
      2. julia --project=. -e '
           using PassivBot
           path = PassivBot.make_get_filepath("/tmp/test_passivbot_dir")
           @assert isdir(path) "Directory should exist"
         '
      3. ls -d /tmp/test_passivbot_dir
      4. Assert: Directory exists
    Expected Result: Directory created
    Evidence: ls output
  ```

  **Commit**: YES
  - Message: `feat(utils): add ts_to_date and make_get_filepath`
  - Files: `src/Utils.jl`
  - Pre-commit: QA scenarios pass

---

- [ ] 4. Complete plot_wrap() Integration

  **What to do**:
  - Update `plot_wrap()` in `src/Backtest.jl` to:
    - Call `backtest(config, ticks, do_print)` (already done)
    - Call `analyze_backtest(fills, stats, config)` to get (fdf, sdf, result)
    - Create output directory: `{plots_dirpath}/{session_name}_{timestamp}/`
    - Save fills to CSV: `{output_dir}/fills.csv`
    - Call `dump_plots(result, fdf, sdf, plot)` if plot flag is set
    - Return (fills, stats, did_finish, result)

  **Must NOT do**:
  - Change backtest() function
  - Modify Analysis.jl or Plotting.jl

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Integration glue code, functions already exist
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 2 (after Tasks 2, 3)
  - **Blocks**: Task 5
  - **Blocked By**: Tasks 2, 3

  **References**:

  **Pattern References**:
  - `/home/czc/projects/working/stock/passivbot3.5.6/backtest.py:444-467` - Python plot_wrap implementation
  - `src/Backtest.jl:455-476` - Current stubbed plot_wrap
  - `src/Analysis.jl:analyze_backtest` - Function to call
  - `src/Plotting.jl:dump_plots` - Function to call

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: plot_wrap creates output directory and files
    Tool: Bash
    Preconditions: Tasks 1-3 complete, sample ticks available
    Steps:
      1. julia --project=. -e '
           using PassivBot, JSON3
           # Load a minimal config
           config = JSON3.read(read("configs/live/5x.json", String), Dict{String,Any})
           config["plots_dirpath"] = "/tmp/passivbot_plots"
           config["session_name"] = "test"
           # Create minimal ticks (price, buyer_maker, timestamp)
           ticks = [50000.0 0.0 1704067200000.0; 50001.0 1.0 1704067201000.0]
           fills, stats, did_finish = PassivBot.plot_wrap(config, ticks, config, "False")
           println("Fills: ", length(fills))
         '
      2. Assert: Exit code 0
    Expected Result: plot_wrap executes without error
    Evidence: Terminal output
  ```

  **Commit**: YES
  - Message: `feat(backtest): complete plot_wrap integration with Analysis and Plotting`
  - Files: `src/Backtest.jl`
  - Pre-commit: QA scenarios pass

---

- [ ] 5. Wire Up scripts/backtest.jl

  **What to do**:
  - Replace placeholder tick loading with Downloader integration:
    - Create Downloader from config
    - Call `get_ticks(downloader, true)` to load tick data
  - Load live config from CLI argument
  - Call `plot_wrap(backtest_config, ticks, live_config, plot_flag)`
  - Print summary results
  - Handle errors gracefully with informative messages

  **Must NOT do**:
  - Add HJSON support (JSON only)
  - Change CLI argument structure

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Wiring existing components together
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 3 (after Task 4)
  - **Blocks**: Task 6
  - **Blocked By**: Tasks 2, 4

  **References**:

  **Pattern References**:
  - `/home/czc/projects/working/stock/passivbot3.5.6/backtest.py:470-508` - Python main() flow
  - `scripts/backtest.jl:76-86` - Current placeholder to replace

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: backtest.jl runs end-to-end without plots
    Tool: Bash
    Preconditions: All previous tasks complete
    Steps:
      1. julia --project=. scripts/backtest.jl configs/live/5x.json
      2. Assert: Exit code 0
      3. Assert: Output contains backtest results (fills count, balance, etc.)
    Expected Result: Backtest completes successfully
    Evidence: Terminal output with results

  Scenario: backtest.jl generates plots with -p flag
    Tool: Bash
    Preconditions: Previous scenario passed
    Steps:
      1. rm -rf plots/test_* 2>/dev/null || true
      2. julia --project=. scripts/backtest.jl configs/live/5x.json -p
      3. Assert: Exit code 0
      4. ls plots/*.png 2>/dev/null | wc -l
      5. Assert: PNG count > 0
    Expected Result: Plot files generated
    Evidence: ls output showing PNG files
  ```

  **Commit**: YES
  - Message: `feat(scripts): wire up backtest.jl with Downloader and plot_wrap`
  - Files: `scripts/backtest.jl`
  - Pre-commit: QA scenarios pass

---

- [ ] 6. Add Tests and Final Verification

  **What to do**:
  - Create `test/downloader_test.jl` with tests for:
    - `compress_ticks()` algorithm correctness
    - `get_ticks()` cache round-trip
    - `ts_to_date()` conversion
  - Add downloader tests to `test/integration_test.jl`
  - Run full test suite
  - Verify end-to-end backtest with real data

  **Must NOT do**:
  - Modify existing passing tests
  - Add tests that require network in CI (mock or skip)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-low`
    - Reason: Standard test writing, following existing patterns
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 4 (final)
  - **Blocks**: None
  - **Blocked By**: Task 5

  **References**:

  **Pattern References**:
  - `test/integration_test.jl` - Existing test structure to follow

  **Acceptance Criteria**:

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: All tests pass
    Tool: Bash
    Steps:
      1. julia --project=. test/integration_test.jl
      2. Assert: Exit code 0
      3. Assert: Output shows "Test Summary" with all passes
    Expected Result: All tests green
    Evidence: Test output

  Scenario: End-to-end backtest with real data
    Tool: Bash
    Steps:
      1. julia --project=. scripts/backtest.jl configs/live/5x.json -p
      2. Assert: Exit code 0
      3. Assert: plots/ directory contains PNG files
      4. Assert: Output shows performance metrics
    Expected Result: Complete backtest pipeline works
    Evidence: Terminal output + plot files
  ```

  **Commit**: YES
  - Message: `test: add downloader tests and verify end-to-end backtest`
  - Files: `test/downloader_test.jl`, `test/integration_test.jl`
  - Pre-commit: All tests pass

---

## Commit Strategy

| After Task | Message | Files | Verification |
|------------|---------|-------|--------------|
| 1 | `feat(downloader): implement download_ticks and compress_ticks` | src/Downloader.jl | QA scenarios |
| 2 | `feat(downloader): add caching to get_ticks` | src/Downloader.jl | QA scenarios |
| 3 | `feat(utils): add ts_to_date and make_get_filepath` | src/Utils.jl | QA scenarios |
| 4 | `feat(backtest): complete plot_wrap integration` | src/Backtest.jl | QA scenarios |
| 5 | `feat(scripts): wire up backtest.jl` | scripts/backtest.jl | QA scenarios |
| 6 | `test: add downloader tests` | test/*.jl | All tests pass |

---

## Success Criteria

### Verification Commands
```bash
# Unit test
julia --project=. test/integration_test.jl  # Expected: All tests pass

# End-to-end test
julia --project=. scripts/backtest.jl configs/live/5x.json -p  # Expected: Completes, generates plots

# Cache verification
ls data/caches/*.bin  # Expected: 3 cache files per symbol/date range
```

### Final Checklist
- [ ] `get_ticks()` returns non-empty Matrix for valid date range
- [ ] Cache files created and reused on subsequent runs
- [ ] `compress_ticks()` reduces row count (compression ratio > 1)
- [ ] `scripts/backtest.jl` runs without error
- [ ] `-p` flag generates plot PNG files
- [ ] All tests pass
- [ ] No HJSON parsing added (JSON only)
- [ ] No retry logic added (matches Python behavior)
