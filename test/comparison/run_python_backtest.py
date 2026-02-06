#!/usr/bin/env python3
"""Minimal Python backtest for comparison with Julia version."""

import sys
import os
import json
import numpy as np

sys.path.insert(0, '/home/czc/projects/working/stock/passivbot3.5.6')

from backtest import backtest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TICKS_PATH = os.path.join(SCRIPT_DIR, "test_ticks.npy")
CONFIG_PATH = os.path.join(SCRIPT_DIR, "test_config.json")
OUTPUT_FILLS = os.path.join(SCRIPT_DIR, "python_fills.json")
OUTPUT_STATS = os.path.join(SCRIPT_DIR, "python_stats.json")


def convert_fill_for_json(fill):
    result = {}
    for k, v in fill.items():
        if isinstance(v, (np.floating, np.integer)):
            result[k] = float(v)
        elif isinstance(v, np.ndarray):
            result[k] = v.tolist()
        elif isinstance(v, float) and np.isnan(v):
            result[k] = None
        else:
            result[k] = v
    return result


def main():
    print(f"Loading ticks from: {TICKS_PATH}")
    ticks = np.load(TICKS_PATH)
    print(f"Loaded {len(ticks)} ticks")
    
    print(f"Loading config from: {CONFIG_PATH}")
    with open(CONFIG_PATH) as f:
        config = json.load(f)
    
    print("\nConfig:")
    for k in ["symbol", "starting_balance", "leverage", "ema_span", "do_long", "do_shrt"]:
        print(f"  {k}: {config.get(k)}")
    
    print("\nRunning backtest...")
    fills, stats, did_finish = backtest(config, ticks, do_print=False)
    
    print(f"\nBacktest completed:")
    print(f"  Total fills: {len(fills)}")
    print(f"  Did finish: {did_finish}")
    
    if fills:
        print(f"  Final balance: {fills[-1].get('balance', 'N/A')}")
        print(f"  Final equity: {fills[-1].get('equity', 'N/A')}")
        print(f"  Final gain: {fills[-1].get('gain', 'N/A')}")
    
    fills_json = [convert_fill_for_json(f) for f in fills]
    stats_json = [convert_fill_for_json(s) for s in stats]
    
    print(f"\nSaving fills to: {OUTPUT_FILLS}")
    with open(OUTPUT_FILLS, 'w') as f:
        json.dump(fills_json, f, indent=2)
    
    print(f"Saving stats to: {OUTPUT_STATS}")
    with open(OUTPUT_STATS, 'w') as f:
        json.dump(stats_json, f, indent=2)
    
    print("\nDone!")


if __name__ == "__main__":
    main()
