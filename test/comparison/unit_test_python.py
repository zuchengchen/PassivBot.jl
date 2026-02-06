#!/usr/bin/env python3
"""
Unit test for Python jitted functions - outputs results to JSON for comparison with Julia.
"""

import sys
import os
import json
import numpy as np

sys.path.insert(0, '/home/czc/projects/working/stock/passivbot3.5.6')

from jitted import (
    round_, round_up, round_dn, calc_diff,
    calc_ema, calc_new_psize_pprice,
    calc_long_pnl, calc_shrt_pnl,
    calc_cost, calc_margin_cost,
    calc_available_margin, calc_liq_price_binance,
    iter_entries, iter_long_closes, iter_shrt_closes
)

np.random.seed(42)

def generate_test_cases():
    cases = {
        "round_": [],
        "round_up": [],
        "round_dn": [],
        "calc_diff": [],
        "calc_ema": [],
        "calc_new_psize_pprice": [],
        "calc_long_pnl": [],
        "calc_shrt_pnl": [],
        "calc_cost": [],
        "calc_margin_cost": [],
        "calc_available_margin": [],
        "calc_liq_price": [],
        "iter_entries": [],
        "iter_closes": [],
    }
    
    for _ in range(100):
        n = np.random.uniform(0.001, 100000)
        step = 10 ** np.random.randint(-8, 2)
        cases["round_"].append({"n": n, "step": step})
    
    for _ in range(100):
        n = np.random.uniform(0.001, 100000)
        step = 10 ** np.random.randint(-8, 2)
        cases["round_up"].append({"n": n, "step": step})
    
    for _ in range(100):
        n = np.random.uniform(0.001, 100000)
        step = 10 ** np.random.randint(-8, 2)
        cases["round_dn"].append({"n": n, "step": step})
    
    for _ in range(100):
        x = np.random.uniform(0.001, 1000)
        y = np.random.uniform(0.001, 1000)
        cases["calc_diff"].append({"x": x, "y": y})
    
    for _ in range(100):
        alpha = np.random.uniform(0.0001, 0.1)
        alpha_ = 1.0 - alpha
        prev_ema = np.random.uniform(10, 100)
        new_val = np.random.uniform(10, 100)
        cases["calc_ema"].append({
            "alpha": alpha, "alpha_": alpha_,
            "prev_ema": prev_ema, "new_val": new_val
        })
    
    for _ in range(50):
        psize = np.random.uniform(0, 1000)
        pprice = np.random.uniform(10, 100)
        qty = np.random.uniform(1, 100)
        price = np.random.uniform(10, 100)
        cases["calc_new_psize_pprice"].append({
            "psize": psize, "pprice": pprice,
            "qty": qty, "price": price
        })
    
    for _ in range(50):
        entry_price = np.random.uniform(10, 100)
        close_price = np.random.uniform(10, 100)
        qty = np.random.uniform(1, 100)
        cases["calc_long_pnl"].append({
            "entry_price": entry_price,
            "close_price": close_price,
            "qty": qty
        })
    
    for _ in range(50):
        entry_price = np.random.uniform(10, 100)
        close_price = np.random.uniform(10, 100)
        qty = np.random.uniform(1, 100)
        cases["calc_shrt_pnl"].append({
            "entry_price": entry_price,
            "close_price": close_price,
            "qty": qty
        })
    
    for _ in range(50):
        qty = np.random.uniform(1, 1000)
        price = np.random.uniform(10, 100)
        cases["calc_cost"].append({"qty": qty, "price": price})
    
    for _ in range(50):
        qty = np.random.uniform(1, 1000)
        price = np.random.uniform(10, 100)
        leverage = np.random.uniform(1, 20)
        cases["calc_margin_cost"].append({
            "qty": qty, "price": price, "leverage": leverage
        })
    
    for _ in range(50):
        balance = np.random.uniform(1000, 10000)
        long_psize = np.random.uniform(0, 100)
        long_pprice = np.random.uniform(10, 100)
        shrt_psize = np.random.uniform(0, 100)
        shrt_pprice = np.random.uniform(10, 100)
        leverage = np.random.uniform(1, 20)
        cases["calc_available_margin"].append({
            "balance": balance,
            "long_psize": long_psize, "long_pprice": long_pprice,
            "shrt_psize": shrt_psize, "shrt_pprice": shrt_pprice,
            "leverage": leverage
        })
    
    for _ in range(50):
        balance = np.random.uniform(1000, 10000)
        psize = np.random.uniform(10, 500)
        pprice = np.random.uniform(10, 100)
        leverage = np.random.uniform(2, 20)
        long = np.random.choice([True, False])
        cases["calc_liq_price"].append({
            "balance": balance, "psize": psize,
            "pprice": pprice, "leverage": leverage, "long": long
        })
    
    for _ in range(50):
        ema = np.random.uniform(10, 100)
        ema_spread = np.random.uniform(0.001, 0.01)
        volatility = np.random.uniform(0.001, 0.05)
        volatility_grid_coeff = np.random.uniform(0, 1)
    
    for _ in range(30):
        balance = np.random.uniform(1000, 10000)
        psize = np.random.uniform(0, 100)
        pprice = np.random.uniform(10, 100) if psize > 0 else 0.0
        entry_price = np.random.uniform(10, 100)
        ema = np.random.uniform(10, 100)
        volatility = np.random.uniform(0.001, 0.05)
        
        cases["iter_entries"].append({
            "balance": balance,
            "psize": psize,
            "pprice": pprice,
            "entry_price": entry_price,
            "ema": ema,
            "volatility": volatility,
            "leverage": 10.0,
            "qty_pct": 0.1,
            "ddown_factor": 0.5,
            "grid_spacing": 0.01,
            "pos_margin_grid_coeff": 0.5,
            "volatility_grid_coeff": 0.5,
            "volatility_qty_coeff": 0.5,
            "min_qty": 1.0,
            "qty_step": 1.0,
            "price_step": 0.0001,
            "min_cost": 5.0,
            "max_leverage": 20.0,
            "entry_liq_diff_thr": 0.1,
            "long": True
        })
    
    for _ in range(30):
        balance = np.random.uniform(1000, 10000)
        psize = np.random.uniform(10, 200)
        pprice = np.random.uniform(10, 100)
        close_price = pprice * np.random.uniform(1.001, 1.05)
        
        cases["iter_closes"].append({
            "balance": balance,
            "psize": psize,
            "pprice": pprice,
            "close_price": close_price,
            "leverage": 10.0,
            "min_markup": 0.002,
            "markup_range": 0.005,
            "n_close_orders": 5,
            "min_qty": 1.0,
            "qty_step": 1.0,
            "price_step": 0.0001,
            "long": True
        })
    
    return cases


def run_tests(cases):
    results = {}
    
    results["round_"] = [
        {"input": c, "output": round_(c["n"], c["step"])}
        for c in cases["round_"]
    ]
    
    results["round_up"] = [
        {"input": c, "output": round_up(c["n"], c["step"])}
        for c in cases["round_up"]
    ]
    
    results["round_dn"] = [
        {"input": c, "output": round_dn(c["n"], c["step"])}
        for c in cases["round_dn"]
    ]
    
    results["calc_diff"] = [
        {"input": c, "output": calc_diff(c["x"], c["y"])}
        for c in cases["calc_diff"]
    ]
    
    results["calc_ema"] = [
        {"input": c, "output": calc_ema(c["alpha"], c["alpha_"], c["prev_ema"], c["new_val"])}
        for c in cases["calc_ema"]
    ]
    
    results["calc_new_psize_pprice"] = []
    for c in cases["calc_new_psize_pprice"]:
        psize, pprice = calc_new_psize_pprice(c["psize"], c["pprice"], c["qty"], c["price"], 1.0)
        results["calc_new_psize_pprice"].append({
            "input": c, "output": {"psize": psize, "pprice": pprice}
        })
    
    results["calc_long_pnl"] = [
        {"input": c, "output": calc_long_pnl(c["entry_price"], c["close_price"], c["qty"])}
        for c in cases["calc_long_pnl"]
    ]
    
    results["calc_shrt_pnl"] = [
        {"input": c, "output": calc_shrt_pnl(c["entry_price"], c["close_price"], c["qty"])}
        for c in cases["calc_shrt_pnl"]
    ]
    
    results["calc_cost"] = [
        {"input": c, "output": calc_cost(c["qty"], c["price"])}
        for c in cases["calc_cost"]
    ]
    
    results["calc_margin_cost"] = [
        {"input": c, "output": calc_margin_cost(c["qty"], c["price"], c["leverage"])}
        for c in cases["calc_margin_cost"]
    ]
    
    results["calc_available_margin"] = [
        {"input": c, "output": calc_available_margin(
            c["balance"], c["long_psize"], c["long_pprice"],
            c["shrt_psize"], c["shrt_pprice"], 50.0, c["leverage"]
        )}
        for c in cases["calc_available_margin"]
    ]
    
    results["calc_liq_price"] = []
    for c in cases["calc_liq_price"]:
        if c["long"]:
            liq = calc_liq_price_binance(c["balance"], c["psize"], c["pprice"], 0.0, 0.0, c["leverage"])
        else:
            liq = calc_liq_price_binance(c["balance"], 0.0, 0.0, -c["psize"], c["pprice"], c["leverage"])
        results["calc_liq_price"].append({"input": c, "output": liq})
    
    results["iter_entries"] = []
    for c in cases["iter_entries"]:
        entries_list = []
        try:
            for entry in iter_entries(
                c["balance"], c["psize"], c["pprice"], 0.0, 0.0, 0.0,
                c["entry_price"], c["entry_price"] * 1.001, c["ema"],
                c["entry_price"], c["volatility"], c["long"], False,
                c["qty_step"], c["price_step"], c["min_qty"], c["min_cost"],
                c["ddown_factor"], c["qty_pct"], c["leverage"], 5.0,
                c["grid_spacing"], c["pos_margin_grid_coeff"],
                c["volatility_grid_coeff"], c["volatility_qty_coeff"],
                0.002, 0.005, 5000.0, 0.002, 0.1, 0.1, c["entry_liq_diff_thr"]
            ):
                entries_list.append({"qty": entry[0], "price": entry[1], "type": entry[4]})
                if len(entries_list) >= 10:
                    break
        except Exception:
            pass
        results["iter_entries"].append({"input": c, "output": entries_list})
    
    results["iter_closes"] = []
    for c in cases["iter_closes"]:
        closes = list(iter_long_closes(
            c["balance"], c["psize"], c["pprice"], c["close_price"],
            True, False, c["qty_step"], c["price_step"],
            c["min_qty"], 5.0, 0.5, 0.1, c["leverage"],
            float(c["n_close_orders"]), 0.01, 0.5, 0.5, 0.5,
            c["min_markup"], c["markup_range"], 5000.0, 0.002,
            0.1, 0.1, 0.1
        ))
        closes_list = [{"qty": cl[0], "price": cl[1], "type": "long_close"} for cl in closes]
        results["iter_closes"].append({"input": c, "output": closes_list})
    
    return results


class NumpyEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, (np.integer,)):
            return int(o)
        elif isinstance(o, (np.floating,)):
            return float(o)
        elif isinstance(o, (np.bool_,)):
            return bool(o)
        elif isinstance(o, np.ndarray):
            return o.tolist()
        return super().default(o)


def main():
    output_dir = os.path.dirname(os.path.abspath(__file__))
    output_path = os.path.join(output_dir, "output", "python", "unit_tests.json")
    cases_path = os.path.join(output_dir, "output", "shared_test_cases.json")
    
    print("Generating test cases...")
    cases = generate_test_cases()
    
    # Save shared test cases for Julia to read
    os.makedirs(os.path.dirname(cases_path), exist_ok=True)
    with open(cases_path, 'w') as f:
        json.dump(cases, f, indent=2, cls=NumpyEncoder)
    print(f"Shared test cases saved to {cases_path}")
    
    print("Running Python unit tests...")
    results = run_tests(cases)
    
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, 'w') as f:
        json.dump(results, f, indent=2, cls=NumpyEncoder)
    
    print(f"Results saved to {output_path}")
    
    for func_name, func_results in results.items():
        print(f"  {func_name}: {len(func_results)} tests")


if __name__ == "__main__":
    main()
