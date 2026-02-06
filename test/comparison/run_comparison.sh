#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PYTHON_DIR="/home/czc/projects/working/stock/passivbot3.5.6"

CONFIG="configs/live/lev10x_stable.json"
SYMBOL="RIVERUSDT"
START_DATE="2026-02-01"
END_DATE="2026-02-02"

while [[ $# -gt 0 ]]; do
    case $1 in
        --config) CONFIG="$2"; shift 2 ;;
        --symbol) SYMBOL="$2"; shift 2 ;;
        --start-date) START_DATE="$2"; shift 2 ;;
        --end-date) END_DATE="$2"; shift 2 ;;
        --unit-only) UNIT_ONLY=1; shift ;;
        --backtest-only) BACKTEST_ONLY=1; shift ;;
        --compare-only) COMPARE_ONLY=1; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "====================================="
echo "PassivBot Comparison Test"
echo "====================================="
echo "Config: $CONFIG"
echo "Symbol: $SYMBOL"
echo "Period: $START_DATE ~ $END_DATE"
echo ""

mkdir -p "$SCRIPT_DIR/output/python"
mkdir -p "$SCRIPT_DIR/output/julia"

if [[ -z "$COMPARE_ONLY" ]]; then
    if [[ -z "$BACKTEST_ONLY" ]]; then
        echo ">>> Running Python unit tests..."
        cd "$SCRIPT_DIR"
        python3 unit_test_python.py
        echo ""

        echo ">>> Running Julia unit tests..."
        cd "$PROJECT_DIR"
        julia --project=. "$SCRIPT_DIR/unit_test_julia.jl"
        echo ""
    fi

    if [[ -z "$UNIT_ONLY" ]]; then
        echo ">>> Running Python backtest..."
        cd "$PYTHON_DIR"
        python3 "$SCRIPT_DIR/backtest_python.py" \
            "$PROJECT_DIR/$CONFIG" \
            -s "$SYMBOL" \
            --start_date "$START_DATE" \
            --end_date "$END_DATE" \
            -bc "configs/backtest/default.hjson" \
            -oc "configs/optimize/default.hjson"
        echo ""

        echo ">>> Running Julia backtest..."
        cd "$PROJECT_DIR"
        julia --project=. "$SCRIPT_DIR/backtest_julia.jl" \
            "$CONFIG" \
            -s "$SYMBOL" \
            --start-date "$START_DATE" \
            --end-date "$END_DATE"
        echo ""
    fi
fi

echo ">>> Comparing results..."
cd "$PROJECT_DIR"
julia --project=. "$SCRIPT_DIR/compare.jl"

echo ""
echo "====================================="
echo "Comparison complete!"
echo "Report: $SCRIPT_DIR/diff_report.md"
echo "====================================="
