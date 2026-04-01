#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path


def parse_latte_json(path):
    """Parse Latte JSON report file"""
    with open(path, 'r') as f:
        data = json.load(f)

    result = data.get('result', {})

    cycle_throughput = result.get('cycle_throughput', {})
    throughput = cycle_throughput.get('value', 0)

    percentiles_list = data.get('percentiles', [])
    p95_idx = percentiles_list.index(95.0)
    p99_idx = percentiles_list.index(99.0)

    cycle_latency_by_fn = result.get('cycle_latency_by_fn', {})

    def get_percentile_value(fn_name, percentile_idx):
        """Extract percentile value for a specific function"""
        fn_latency = cycle_latency_by_fn.get(fn_name, {})
        percentiles = fn_latency.get('percentiles', [])

        if percentile_idx < len(percentiles):
            return percentiles[percentile_idx].get('value', 0)
        return 0.0

    def get_mean_value(fn_name):
        """Extract mean latency value for a specific function"""
        fn_latency = cycle_latency_by_fn.get(fn_name, {})
        mean = fn_latency.get('mean', {})
        return mean.get('value', 0)

    log_path = path.with_suffix('.log')
    cpu_usage = 0.0
    if log_path.exists():
        log_text = log_path.read_text()
        time_match = re.search(
            r"TIMEFORMAT\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)", log_text)
        if time_match:
            real, user, sys_time = map(float, time_match.groups())
            if real > 0:
                cpu_usage = (user + sys_time) / real * 100

    return {
        'throughput': throughput,
        'get_avg_ms': get_mean_value('get'),
        'get_p95_ms': get_percentile_value('get', p95_idx),
        'get_p99_ms': get_percentile_value('get', p99_idx),
        'update_avg_ms': get_mean_value('update'),
        'update_p95_ms': get_percentile_value('update', p95_idx),
        'update_p99_ms': get_percentile_value('update', p99_idx),
        'cpu_usage': cpu_usage,
    }


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: analyze_latte_results.py <output_dir>")
        sys.exit(1)

    outdir = Path(sys.argv[1])
    report_file = outdir / 'latte_1.json'

    if not report_file.exists():
        print(f"No Latte report found: {report_file}")
        sys.exit(1)

    report = parse_latte_json(report_file)

    print('=== Latte Alternator Results ===')
    print(f'Throughput: {round(report["throughput"], 3)} ops/s')
    print(
        f'GET avg/p95/p99: {round(report["get_avg_ms"], 3)} / {round(report["get_p95_ms"], 3)} / {round(report["get_p99_ms"], 3)} ms')
    print(
        f'UPDATE avg/p95/p99: {round(report["update_avg_ms"], 3)} / {round(report["update_p95_ms"], 3)} / {round(report["update_p99_ms"], 3)} ms')
    print(f'CPU usage: {round(report["cpu_usage"], 1)}%')
