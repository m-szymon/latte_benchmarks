#!/usr/bin/env python3
import re
import sys
from pathlib import Path


def g(text, pat):
    m = re.search(pat, text, re.S)
    return float(m.group(1)) if m else None


def parse_y(path):
    t = Path(path).read_text()
    time_match = re.search(
        r"TIMEFORMAT\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)", t)
    cpu_usage = 0.0
    if time_match:
        real, user, sys_time = map(float, time_match.groups())
        if real > 0:
            cpu_usage = (user + sys_time) / real * 100

    return {
        'throughput': g(t, r"\[OVERALL\], Throughput\(ops/sec\), ([0-9.]+)"),
        'read_avg_ms': (g(t, r"\[READ\], AverageLatency\(us\), ([0-9.]+)") or 0) / 1000,
        'read_p95_ms': (g(t, r"\[READ\], 95thPercentileLatency\(us\), ([0-9.]+)") or 0) / 1000,
        'read_p99_ms': (g(t, r"\[READ\], 99thPercentileLatency\(us\), ([0-9.]+)") or 0) / 1000,
        'update_avg_ms': (g(t, r"\[UPDATE\], AverageLatency\(us\), ([0-9.]+)") or 0) / 1000,
        'update_p95_ms': (g(t, r"\[UPDATE\], 95thPercentileLatency\(us\), ([0-9.]+)") or 0) / 1000,
        'update_p99_ms': (g(t, r"\[UPDATE\], 99thPercentileLatency\(us\), ([0-9.]+)") or 0) / 1000,
        'cpu_usage': cpu_usage,
    }


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: analyze_ycsb_results.py <output_dir>")
        sys.exit(1)

    outdir = Path(sys.argv[1])
    report_file = outdir / 'ycsb_1.log'

    if not report_file.exists():
        print(f"No YCSB report found: {report_file}")
        sys.exit(1)

    report = parse_y(report_file)

    print('=== YCSB Alternator Results ===')

    def fmt(val):
        """Format value, returning 'N/A' if None"""
        return round(val, 3) if val is not None else 'N/A'

    throughput = report.get("throughput")
    if throughput:
        print(f'Throughput: {fmt(throughput)} ops/s')
    else:
        print('Throughput: N/A')

    print(
        f'READ avg/p95/p99: {fmt(report["read_avg_ms"])} / {fmt(report["read_p95_ms"])} / {fmt(report["read_p99_ms"])} ms')
    print(
        f'UPDATE avg/p95/p99: {fmt(report["update_avg_ms"])} / {fmt(report["update_p95_ms"])} / {fmt(report["update_p99_ms"])} ms')

    cpu_usage = report.get("cpu_usage")
    if cpu_usage is not None:
        print(f'CPU usage: {round(cpu_usage, 1)}%')
    else:
        print('CPU usage: N/A')
