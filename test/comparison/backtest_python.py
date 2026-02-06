#!/usr/bin/env python3
"""
Python backtest with fill/state output for comparison with Julia version.
"""

import argparse
import asyncio
import json
import os
import sys

import numpy as np

sys.path.insert(0, '/home/czc/projects/working/stock/passivbot3.5.6')

from analyze import analyze_fills
from downloader import Downloader, prep_config, load_live_config
from jitted import (
    calc_diff, round_, iter_entries, iter_long_closes, iter_shrt_closes,
    calc_available_margin, calc_liq_price_binance, calc_new_psize_pprice,
    calc_long_pnl, calc_shrt_pnl, calc_cost, iter_indicator_chunks
)
from passivbot import get_keys


def backtest_with_output(config: dict, ticks: np.ndarray, output_dir: str):
    if len(ticks) <= config["ema_span"]:
        return [], [], False
    
    long_psize, long_pprice = 0.0, 0.0
    shrt_psize, shrt_pprice = 0.0, 0.0
    liq_price, liq_diff = 0.0, 1.0
    balance = config["starting_balance"]
    pbr_limit = 1

    pnl_plus_fees_cumsum, loss_cumsum, profit_cumsum, fee_paid_cumsum = 0.0, 0.0, 0.0, 0.0
    xk = {k: float(config[k]) for k in get_keys()}
    calc_liq_price = calc_liq_price_binance

    prev_long_close_ts, prev_long_entry_ts, prev_long_close_price = 0, 0, 0.0
    prev_shrt_close_ts, prev_shrt_entry_ts, prev_shrt_close_price = 0, 0, 0.0
    latency_simulation_ms = config.get("latency_simulation_ms", 1000)

    next_stats_update = 0
    stats = []
    state_snapshots = []
    snapshot_interval = 1000

    def stats_update():
        upnl_l = calc_long_pnl(long_pprice, tick[0], long_psize) if long_pprice and long_psize else 0.0
        upnl_s = calc_shrt_pnl(shrt_pprice, tick[0], shrt_psize) if shrt_pprice and shrt_psize else 0.0
        stats.append({
            "timestamp": float(tick[2]),
            "balance": balance,
            "equity": balance + upnl_l + upnl_s,
        })

    all_fills = []
    fills = []
    bids, asks = [], []
    ob = [min(ticks[0][0], ticks[1][0]), max(ticks[0][0], ticks[1][0])]
    ema_span = int(round(config["ema_span"]))

    ema_std_iterator = iter_indicator_chunks(ticks[:, 0], ema_span)
    ema_chunk, std_chunk, z = next(ema_std_iterator)
    volatility_chunk = np.nan_to_num(std_chunk / ema_chunk, nan=0.0, posinf=0.0, neginf=0.0)
    zc = 0

    closest_liq = 1.0
    prev_update_plus_delay = ticks[ema_span][2] + latency_simulation_ms
    update_triggered = False
    prev_update_plus_5sec = 0

    tick = ticks[0]
    stats_update()

    for k, tick in enumerate(ticks[ema_span:], start=ema_span):
        chunk_i = k - zc
        if chunk_i >= len(ema_chunk):
            ema_chunk, std_chunk, z = next(ema_std_iterator)
            volatility_chunk = np.nan_to_num(std_chunk / ema_chunk, nan=0.0, posinf=0.0, neginf=0.0)
            zc = z * len(ema_chunk)
            chunk_i = k - zc

        if k % snapshot_interval == 0:
            state_snapshots.append({
                "tick_index": k,
                "timestamp": float(tick[2]),
                "price": float(tick[0]),
                "trigger": "periodic",
                "ema": {
                    "ema": float(ema_chunk[chunk_i]),
                    "ema_span": float(config["ema_span"]),
                    "ema_spread": float(config["ema_spread"]),
                },
                "volatility": {
                    "volatility": float(volatility_chunk[chunk_i]),
                },
                "position": {
                    "long_psize": long_psize,
                    "long_pprice": long_pprice,
                    "shrt_psize": shrt_psize,
                    "shrt_pprice": shrt_pprice,
                },
                "balance": {
                    "balance": balance,
                    "equity": balance + calc_long_pnl(long_pprice, tick[0], long_psize) + calc_shrt_pnl(shrt_pprice, tick[0], shrt_psize) if long_psize or shrt_psize else balance,
                },
                "orders": {
                    "bids": [{"qty": b[0], "price": b[1]} for b in bids[:5]],
                    "asks": [{"qty": a[0], "price": a[1]} for a in asks[:5]],
                },
                "thresholds": {
                    "bid_thr": ob[0],
                    "ask_thr": ob[1],
                },
            })

        if tick[2] > next_stats_update:
            closest_liq = min(closest_liq, calc_diff(liq_price, tick[0]))
            stats_update()
            next_stats_update = tick[2] + 1000 * 60 * 30

        fills = []
        if tick[1]:
            if liq_diff < 0.05 and long_psize > -shrt_psize and tick[0] <= liq_price:
                fills.append({
                    "qty": -long_psize, "price": tick[0], "pside": "long",
                    "type": "long_liquidation", "side": "sel",
                    "pnl": calc_long_pnl(long_pprice, tick[0], long_psize),
                    "fee_paid": -calc_cost(long_psize, tick[0]) * config["taker_fee"],
                    "long_psize": 0.0, "long_pprice": 0.0,
                    "shrt_psize": 0.0, "shrt_pprice": 0.0,
                    "liq_price": 0.0, "liq_diff": 1.0,
                })
                long_psize, long_pprice, shrt_psize, shrt_pprice = 0.0, 0.0, 0.0, 0.0
            else:
                if bids:
                    if tick[0] <= bids[0][1]:
                        update_triggered = True
                    while bids:
                        if tick[0] < bids[0][1]:
                            bid = bids.pop(0)
                            fill = {
                                "qty": bid[0], "price": bid[1], "side": "buy", "type": bid[4],
                                "fee_paid": -calc_cost(bid[0], bid[1]) * config["maker_fee"],
                            }
                            if "close" in bid[4]:
                                fill["pnl"] = calc_shrt_pnl(shrt_pprice, bid[1], bid[0])
                                shrt_psize = min(0.0, round_(shrt_psize + bid[0], config["qty_step"]))
                                fill.update({
                                    "pside": "shrt",
                                    "long_psize": long_psize, "long_pprice": long_pprice,
                                    "shrt_psize": shrt_psize, "shrt_pprice": shrt_pprice,
                                })
                                prev_shrt_close_ts = tick[2]
                            else:
                                fill["pnl"] = 0.0
                                long_psize, long_pprice = calc_new_psize_pprice(
                                    long_psize, long_pprice, bid[0], bid[1], xk["qty_step"]
                                )
                                if long_psize < 0.0:
                                    long_psize, long_pprice = 0.0, 0.0
                                fill.update({
                                    "pside": "long",
                                    "long_psize": bid[2], "long_pprice": bid[3],
                                    "shrt_psize": shrt_psize, "shrt_pprice": shrt_pprice,
                                })
                                prev_long_entry_ts = tick[2]
                            fills.append(fill)
                        else:
                            break
            ob[0] = tick[0]
        else:
            if liq_diff < 0.05 and -shrt_psize > long_psize and tick[0] >= liq_price:
                fills.append({
                    "qty": -shrt_psize, "price": tick[0], "pside": "shrt",
                    "type": "shrt_liquidation", "side": "buy",
                    "pnl": calc_shrt_pnl(shrt_pprice, tick[0], shrt_psize),
                    "fee_paid": -calc_cost(shrt_psize, tick[0]) * config["taker_fee"],
                    "long_psize": 0.0, "long_pprice": 0.0,
                    "shrt_psize": 0.0, "shrt_pprice": 0.0,
                    "liq_price": 0.0, "liq_diff": 1.0,
                })
                long_psize, long_pprice, shrt_psize, shrt_pprice = 0.0, 0.0, 0.0, 0.0
            else:
                if asks:
                    if tick[0] >= asks[0][1]:
                        update_triggered = True
                    while asks:
                        if tick[0] > asks[0][1]:
                            ask = asks.pop(0)
                            fill = {
                                "qty": ask[0], "price": ask[1], "side": "sel", "type": ask[4],
                                "fee_paid": -calc_cost(ask[0], ask[1]) * config["maker_fee"],
                            }
                            if "close" in ask[4]:
                                fill["pnl"] = calc_long_pnl(long_pprice, ask[1], ask[0])
                                long_psize = max(0.0, round_(long_psize + ask[0], config["qty_step"]))
                                fill.update({
                                    "pside": "long",
                                    "long_psize": long_psize, "long_pprice": long_pprice,
                                    "shrt_psize": shrt_psize, "shrt_pprice": shrt_pprice,
                                })
                                prev_long_close_ts = tick[2]
                            else:
                                fill["pnl"] = 0.0
                                shrt_psize, shrt_pprice = calc_new_psize_pprice(
                                    shrt_psize, shrt_pprice, ask[0], ask[1], xk["qty_step"]
                                )
                                if shrt_psize > 0.0:
                                    shrt_psize, shrt_pprice = 0.0, 0.0
                                fill.update({
                                    "pside": "shrt",
                                    "long_psize": long_psize, "long_pprice": long_pprice,
                                    "shrt_psize": shrt_psize, "shrt_pprice": shrt_pprice,
                                })
                                prev_shrt_entry_ts = tick[2]
                            liq_diff = calc_diff(liq_price, tick[0])
                            fill.update({"liq_price": liq_price, "liq_diff": liq_diff})
                            fills.append(fill)
                        else:
                            break
            ob[1] = tick[0]

        if tick[2] > prev_update_plus_delay and (update_triggered or tick[2] > prev_update_plus_5sec):
            prev_update_plus_delay = tick[2] + latency_simulation_ms
            prev_update_plus_5sec = tick[2] + 5000
            update_triggered = False
            bids, asks = [], []
            liq_diff = calc_diff(liq_price, tick[0])
            closest_liq = min(closest_liq, liq_diff)
            for tpl in iter_entries(
                balance, long_psize, long_pprice, shrt_psize, shrt_pprice, liq_price,
                ob[0], ob[1], ema_chunk[k - zc], tick[0], volatility_chunk[k - zc], **xk
            ):
                if len(bids) > 2 and len(asks) > 2:
                    break
                if tpl[0] > 0.0:
                    bids.append(tpl)
                elif tpl[0] < 0.0:
                    asks.append(tpl)
                else:
                    break
            if tick[0] <= shrt_pprice and shrt_pprice > 0.0:
                for tpl in iter_shrt_closes(balance, shrt_psize, shrt_pprice, ob[0], **xk):
                    bids.append(list(tpl) + [shrt_pprice, "shrt_close"])
            if tick[0] >= long_pprice and long_pprice > 0.0:
                for tpl in iter_long_closes(balance, long_psize, long_pprice, ob[1], **xk):
                    asks.append(list(tpl) + [long_pprice, "long_close"])
            bids = sorted(bids, key=lambda x: x[1], reverse=True)
            asks = sorted(asks, key=lambda x: x[1])

        if len(fills) > 0:
            for fill in fills:
                balance += fill["pnl"] + fill["fee_paid"]
                upnl_l = calc_long_pnl(long_pprice, tick[0], long_psize)
                upnl_s = calc_shrt_pnl(shrt_pprice, tick[0], shrt_psize)

                liq_price = calc_liq_price(
                    balance, long_psize, long_pprice, shrt_psize, shrt_pprice, config["max_leverage"]
                )
                liq_diff = calc_diff(liq_price, tick[0])
                fill.update({"liq_price": liq_price, "liq_diff": liq_diff})

                fill["equity"] = balance + upnl_l + upnl_s
                fill["available_margin"] = calc_available_margin(
                    balance, long_psize, long_pprice, shrt_psize, shrt_pprice, tick[0], xk["leverage"]
                )
                for side_ in ["long", "shrt"]:
                    if fill[f"{side_}_pprice"] == 0.0:
                        fill[f"{side_}_pprice"] = None
                fill["balance"] = balance
                fill["timestamp"] = float(tick[2])
                fill["trade_id"] = k
                fill["tick_index"] = k
                fill["gain"] = fill["equity"] / config["starting_balance"]
                fill["n_days"] = (tick[2] - ticks[ema_span][2]) / (1000 * 60 * 60 * 24)
                fill["closest_liq"] = closest_liq
                try:
                    fill["average_daily_gain"] = (
                        fill["gain"] ** (1 / fill["n_days"])
                        if (fill["n_days"] > 0.5 and fill["gain"] > 0.0)
                        else 0.0
                    )
                except (ValueError, ZeroDivisionError):
                    fill["average_daily_gain"] = 0.0
                all_fills.append(fill)

                state_snapshots.append({
                    "tick_index": k,
                    "timestamp": float(tick[2]),
                    "price": float(tick[0]),
                    "trigger": "fill",
                    "fill_type": fill["type"],
                    "ema": {"ema": float(ema_chunk[chunk_i])},
                    "volatility": {"volatility": float(volatility_chunk[chunk_i])},
                    "position": {
                        "long_psize": long_psize, "long_pprice": long_pprice,
                        "shrt_psize": shrt_psize, "shrt_pprice": shrt_pprice,
                    },
                    "balance": {"balance": balance, "equity": fill["equity"]},
                })

                if balance <= 0.0 or "liquidation" in fill["type"]:
                    return all_fills, stats, state_snapshots, False

    tick = ticks[-1]
    stats_update()
    
    os.makedirs(output_dir, exist_ok=True)
    with open(os.path.join(output_dir, "fills.json"), 'w') as f:
        json.dump(all_fills, f, indent=2, default=str)
    with open(os.path.join(output_dir, "states.json"), 'w') as f:
        json.dump(state_snapshots, f, indent=2, default=str)
    with open(os.path.join(output_dir, "stats.json"), 'w') as f:
        json.dump(stats, f, indent=2, default=str)
    
    return all_fills, stats, state_snapshots, True


async def main():
    parser = argparse.ArgumentParser(prog="Backtest Python", description="Backtest with output for comparison")
    parser.add_argument("live_config_path", type=str, help="path to live config")
    parser.add_argument("-s", "--symbol", type=str, default="none", help="symbol")
    parser.add_argument("--start_date", type=str, default="none", help="start date")
    parser.add_argument("--end_date", type=str, default="none", help="end date")
    parser.add_argument("-u", "--user", type=str, default="none", help="user")
    parser.add_argument("-bc", "--backtest_config_path", type=str, default="configs/backtest/default.hjson")
    parser.add_argument("-oc", "--optimize_config_path", type=str, default="configs/optimize/default.hjson")
    args = parser.parse_args()

    config = await prep_config(args)
    live_config = load_live_config(args.live_config_path)
    config = {**config, **live_config}
    
    print(f"Symbol: {config['symbol']}")
    print(f"Start: {config['start_date']}")
    print(f"End: {config['end_date']}")
    
    downloader = Downloader(config)
    ticks = await downloader.get_ticks(True)
    
    output_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output", "python")
    
    print(f"Running backtest with {len(ticks)} ticks...")
    fills, stats, state_snapshots, did_finish = backtest_with_output(config, ticks, output_dir)
    
    # Always save output (backtest_with_output may return early on liquidation)
    os.makedirs(output_dir, exist_ok=True)
    with open(os.path.join(output_dir, "fills.json"), 'w') as f:
        json.dump(fills, f, indent=2, default=str)
    with open(os.path.join(output_dir, "states.json"), 'w') as f:
        json.dump(state_snapshots, f, indent=2, default=str)
    with open(os.path.join(output_dir, "stats.json"), 'w') as f:
        json.dump(stats, f, indent=2, default=str)
    
    print(f"Fills: {len(fills)}")
    print(f"State snapshots: {len(state_snapshots)}")
    print(f"Did finish: {did_finish}")
    print(f"Output saved to: {output_dir}")


if __name__ == "__main__":
    asyncio.run(main())
