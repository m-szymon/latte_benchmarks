#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def parse_latte_json(path):
    with open(path, 'r') as f:
        d = json.load(f)

    r = d.get('result', {})
    tp = r.get('cycle_throughput', {}).get('value', 0)
    plist = d.get('percentiles', [])
    p99i = plist.index(99.0) if 99.0 in plist else -1

    fn = r.get('cycle_latency_by_fn', {})

    def get_p(name, idx):
        ps = fn.get(name, {}).get('percentiles', [])
        return ps[idx].get('value', 0) if 0 <= idx < len(ps) else 0

    def get_m(name):
        return fn.get(name, {}).get('mean', {}).get('value', 0)

    # Cycle latency per-op
    ga = get_m('get')
    g99 = get_p('get', p99i)
    ua = get_m('update')
    u99 = get_p('update', p99i)

    # Request latency (aggregate only)
    rl = r.get('request_latency', {})
    rl_mean = rl.get('mean', {}).get('value', 0)
    rl_p99_val = 0
    rl_percs = rl.get('percentiles', [])
    if 0 <= p99i < len(rl_percs):
        rl_p99_val = rl_percs[p99i].get('value', 0)

    return {
        "throughput": tp,
        "ga": ga, "g99": g99,
        "ua": ua, "u99": u99,
        "rl_mean": rl_mean, "rl_p99": rl_p99_val
    }


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("outdir", type=Path)
    parser.add_argument("--csv-prefix", help="tool,inflight,rate_str,rep")
    parser.add_argument("--csv-suffix", help="loader_cpu,scylla_cpu,...")
    args = parser.parse_args()

    jsonfile = args.outdir / 'latte_1.json'
    if not jsonfile.exists():
        sys.exit(1)

    res = parse_latte_json(jsonfile)

    if args.csv_prefix:
        print(
            f"{args.csv_prefix},{res['throughput']:.1f},{res['ga']:.3f},{res['g99']:.3f},{res['ua']:.3f},{res['u99']:.3f},{res['rl_mean']:.3f},{res['rl_p99']:.3f},{args.csv_suffix}")
    else:
        print(f"Throughput: {res['throughput']:.1f} ops/s")
        print(f"GET avg/p99: {res['ga']:.3f} / {res['g99']:.3f} ms")
        print(f"UPDATE avg/p99: {res['ua']:.3f} / {res['u99']:.3f} ms")
