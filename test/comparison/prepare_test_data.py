#!/usr/bin/env python3
"""Prepare multi-day test data from RIVERUSDT zip files for backtest comparison."""

import os
import glob
import numpy as np
import pandas as pd
from zipfile import ZipFile

ZIP_DIR = "/home/czc/projects/working/stock/Passivbot.jl/data/cache/zip/RIVERUSDT"
OUTPUT_DIR = "/home/czc/projects/working/stock/PassivBot.jl/test/comparison"
DAYS = 7


def load_ticks_from_zip(zip_path):
    with ZipFile(zip_path, 'r') as zf:
        filename = zf.namelist()[0]
        with zf.open(filename) as f:
            df = pd.read_csv(f)
    
    df = df.rename(columns={
        'agg_trade_id': 'trade_id',
        'quantity': 'qty',
        'transact_time': 'timestamp'
    })
    df['is_buyer_maker'] = df['is_buyer_maker'].astype(int)
    return df


def compress_ticks(ticks: np.ndarray) -> np.ndarray:
    """Group consecutive ticks with same (price, is_buyer_maker) into single tick."""
    price_changes = np.concatenate([[True], ticks[1:, 0] != ticks[:-1, 0]])
    maker_changes = np.concatenate([[True], ticks[1:, 1] != ticks[:-1, 1]])
    change_indices = np.where(price_changes | maker_changes)[0]
    return ticks[change_indices]


def main():
    zip_files = sorted(glob.glob(os.path.join(ZIP_DIR, "RIVERUSDT-aggTrades-*.zip")))
    print(f"Found {len(zip_files)} zip files")
    print(f"Loading {DAYS} days of data...")
    
    all_dfs = []
    for i, zip_path in enumerate(zip_files[:DAYS]):
        print(f"  [{i+1}/{DAYS}] {os.path.basename(zip_path)}")
        df = load_ticks_from_zip(zip_path)
        all_dfs.append(df)
    
    df_combined = pd.concat(all_dfs, ignore_index=True)
    df_combined = df_combined.sort_values('timestamp').reset_index(drop=True)
    print(f"\nTotal rows: {len(df_combined)}")
    
    ticks = df_combined[['price', 'is_buyer_maker', 'timestamp']].to_numpy().astype(np.float64)
    compressed_ticks = compress_ticks(ticks)
    print(f"Compressed: {len(ticks)} -> {len(compressed_ticks)} ticks")
    
    npy_path = os.path.join(OUTPUT_DIR, "test_ticks.npy")
    np.save(npy_path, compressed_ticks)
    print(f"Saved: {npy_path}")
    
    print("\n" + "="*60)
    print("Test Data Summary")
    print("="*60)
    print(f"Total ticks: {len(compressed_ticks)}")
    duration_hours = (compressed_ticks[-1, 2] - compressed_ticks[0, 2]) / (1000 * 60 * 60)
    print(f"Duration: {duration_hours:.2f} hours ({duration_hours/24:.2f} days)")
    print(f"Price range: {compressed_ticks[:, 0].min():.4f} - {compressed_ticks[:, 0].max():.4f}")


if __name__ == "__main__":
    main()
