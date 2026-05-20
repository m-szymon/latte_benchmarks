#!/usr/bin/env python3
import re
import sys
from pathlib import Path


def parse_y(path):
    t = path.read_text()

    def g(pat):
        m = re.search(pat, t)
        return float(m.group(1)) if m else 0

    tp = g(r'\[OVERALL\], Throughput\(ops/sec\), ([0-9.]+)')

    # Service-time (request latency) — [READ], [UPDATE]
    ra = g(r'\[READ\], AverageLatency\(us\), ([0-9.]+)') / 1000
    r99 = g(r'\[READ\], 99thPercentileLatency\(us\), ([0-9.]+)') / 1000
    ua = g(r'\[UPDATE\], AverageLatency\(us\), ([0-9.]+)') / 1000
    u99 = g(r'\[UPDATE\], 99thPercentileLatency\(us\), ([0-9.]+)') / 1000

    # Cycle latency (intended / CO-corrected) — [Intended-READ], [Intended-UPDATE]
    ira = g(r'\[Intended-READ\], AverageLatency\(us\), ([0-9.]+)') / 1000
    ir99 = g(r'\[Intended-READ\], 99thPercentileLatency\(us\), ([0-9.]+)') / 1000
    iua = g(r'\[Intended-UPDATE\], AverageLatency\(us\), ([0-9.]+)') / 1000
    iu99 = g(
        r'\[Intended-UPDATE\], 99thPercentileLatency\(us\), ([0-9.]+)') / 1000

    # For YCSB: cycle = intended, request = service-time
    # If no intended block (rate not set), cycle = request
    get_cycle_mean = ira if ira > 0 else ra
    get_cycle_p99 = ir99 if ir99 > 0 else r99
    upd_cycle_mean = iua if iua > 0 else ua
    upd_cycle_p99 = iu99 if iu99 > 0 else u99

    # Aggregate request latency (weighted by operation count)
    r_ops = g(r'\[READ\], Operations, ([0-9]+)')
    u_ops = g(r'\[UPDATE\], Operations, ([0-9]+)')
    total = r_ops + u_ops
    if total > 0:
        agg_req_mean = (r_ops * ra + u_ops * ua) / total
        agg_req_p99 = max(r99, u99)  # conservative: max of per-op p99
    else:
        agg_req_mean = 0
        agg_req_p99 = 0

    return {
        "tp": tp,
        "get_cycle_mean": get_cycle_mean, "get_cycle_p99": get_cycle_p99,
        "upd_cycle_mean": upd_cycle_mean, "upd_cycle_p99": upd_cycle_p99,
        "agg_req_mean": agg_req_mean, "agg_req_p99": agg_req_p99
    }


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("outdir", type=Path)
    parser.add_argument("--csv-prefix", help="tool,inflight,rate_str,rep")
    parser.add_argument("--csv-suffix", help="loader_cpu,scylla_cpu,...")
    args = parser.parse_args()

    logfile = args.outdir / 'ycsb_1.log'
    if not logfile.exists():
        sys.exit(1)

    res = parse_y(logfile)

    if args.csv_prefix:
        print(f"{args.csv_prefix},{res['tp']:.1f},{res['get_cycle_mean']:.3f},{res['get_cycle_p99']:.3f},{res['upd_cycle_mean']:.3f},{res['upd_cycle_p99']:.3f},{res['agg_req_mean']:.3f},{res['agg_req_p99']:.3f},{args.csv_suffix}")
    else:
        print(f"Throughput: {res['tp']:.1f} ops/s")
        print(
            f"READ avg/p99: {res['get_cycle_mean']:.3f} / {res['get_cycle_p99']:.3f} ms")
        print(
            f"UPDATE avg/p99: {res['upd_cycle_mean']:.3f} / {res['upd_cycle_p99']:.3f} ms")
