#!/usr/bin/env python3
"""
analyze_scylla_metrics.py — Parse Prometheus scrape log from Scylla node.

Input: a file with repeated blocks separated by "---TIMESTAMP <epoch>---" lines,
each block containing Prometheus text exposition format from localhost:9180/metrics.

Output: JSON dict to stdout with aggregated server-side metrics:
  ops_per_sec        — Alternator request rate (derived from counter deltas)
  p99_ms             — Alternator operation p99 latency (from summary quantiles)
  reactor_util_pct   — Max-over-shards reactor utilization percentage
  cache_hit_rate     — Row cache hit ratio (0-1)

Usage:
  python3 analyze_scylla_metrics.py <scylla_prometheus.log>
  python3 analyze_scylla_metrics.py --dry-run <scylla_prometheus.log>   # list matched metrics
"""
import json
import re
import sys
from collections import defaultdict


def parse_snapshots(path):
    """Parse prometheus log into list of (timestamp, {metric_line: value}) dicts."""
    snapshots = []
    current_ts = None
    current_lines = []

    with open(path) as f:
        for line in f:
            m = re.match(r'^---TIMESTAMP (\d+)---', line)
            if m:
                if current_ts is not None and current_lines:
                    snapshots.append((int(current_ts), current_lines))
                current_ts = m.group(1)
                current_lines = []
            elif current_ts is not None and not line.startswith('#') and line.strip():
                current_lines.append(line.strip())

    if current_ts is not None and current_lines:
        snapshots.append((int(current_ts), current_lines))

    return snapshots


def extract_metric(lines, pattern):
    """Extract all values matching a metric name pattern. Returns list of (labels, value)."""
    results = []
    for line in lines:
        m = re.match(r'^(' + pattern + r'(?:\{[^}]*\})?)\s+([0-9eE.+\-]+)', line)
        if m:
            try:
                results.append((m.group(1), float(m.group(2))))
            except ValueError:
                pass
    return results


def analyze(path, dry_run=False):
    snapshots = parse_snapshots(path)

    if not snapshots:
        print(json.dumps({"error": "no snapshots found"}))
        return

    if dry_run:
        # List all unique metric names from last snapshot
        _, lines = snapshots[-1]
        names = set()
        for line in lines:
            m = re.match(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)', line)
            if m:
                names.add(m.group(1))
        for name in sorted(names):
            # Highlight metrics likely relevant to Alternator benchmarking
            tag = ""
            for kw in ['alternator', 'reactor', 'cache', 'storage_proxy', 'transport']:
                if kw in name:
                    tag = "  <-- relevant"
                    break
            print(f"{name}{tag}")
        return

    result = {
        "ops_per_sec": "0",
        "p99_ms": "0",
        "reactor_util_pct": "0",
        "cache_hit_rate": "0",
        "snapshots": len(snapshots),
    }

    # --- Throughput: counter delta ---
    # Try scylla_alternator_operation first, then scylla_transport_requests_served
    op_counter_patterns = [
        r'scylla_alternator_operation_total',
        r'scylla_alternator_operation',
        r'scylla_transport_requests_served',
    ]

    for pat in op_counter_patterns:
        if len(snapshots) >= 2:
            first_ts, first_lines = snapshots[0]
            last_ts, last_lines = snapshots[-1]
            dt = last_ts - first_ts
            if dt <= 0:
                continue

            first_vals = extract_metric(first_lines, pat)
            last_vals = extract_metric(last_lines, pat)

            if first_vals and last_vals:
                first_total = sum(v for _, v in first_vals)
                last_total = sum(v for _, v in last_vals)
                delta = last_total - first_total
                if delta > 0:
                    result["ops_per_sec"] = f"{delta / dt:.1f}"
                    break

    # --- p99 latency from summary/histogram quantiles ---
    # Try alternator-specific, then storage_proxy
    p99_patterns = [
        r'scylla_alternator_op_latency_summary',
        r'scylla_alternator_operation_latency_summary',
    ]

    _, last_lines = snapshots[-1]
    for pat in p99_patterns:
        p99_values = []
        for line in last_lines:
            if re.match(pat + r'\{', line) and 'quantile="0.99' in line:
                m_val = re.search(r'\s+([0-9eE.+\-]+)$', line)
                if m_val:
                    try:
                        val_us = float(m_val.group(1))
                        if val_us > 0:
                            p99_values.append(val_us)
                    except ValueError:
                        pass
        if p99_values:
            # Max across shards and ops for a conservative p99
            result["p99_ms"] = f"{max(p99_values) / 1000:.3f}"
            break

    # --- Reactor utilization ---
    reactor_patterns = [
        r'scylla_reactor_utilization',
        r'scylla_scheduler_runtime_ms',  # fallback: compute from busy/total
    ]

    for pat in reactor_patterns:
        vals = extract_metric(last_lines, pat)
        if vals and 'utilization' in pat:
            # max-over-shards; Scylla reports as percentage (0-100)
            max_util = max(v for _, v in vals)
            result["reactor_util_pct"] = f"{max_util:.1f}"
            break

    # --- Cache hit rate ---
    hits = extract_metric(last_lines, r'scylla_cache_row_hits')
    misses = extract_metric(last_lines, r'scylla_cache_row_misses')
    if not hits:
        hits = extract_metric(last_lines, r'scylla_cache_partition_hits')
        misses = extract_metric(last_lines, r'scylla_cache_partition_misses')

    total_hits = sum(v for _, v in hits)
    total_misses = sum(v for _, v in misses)
    if total_hits + total_misses > 0:
        result["cache_hit_rate"] = f"{total_hits / (total_hits + total_misses):.4f}"

    print(json.dumps(result))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: analyze_scylla_metrics.py [--dry-run] <scylla_prometheus.log>")
        sys.exit(1)

    dry_run = '--dry-run' in sys.argv
    path = [a for a in sys.argv[1:] if a != '--dry-run'][0]
    analyze(path, dry_run=dry_run)
